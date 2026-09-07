import AVFoundation
import Foundation
import VideoToolbox
import CaptureDeviceBridge

public struct CaptureConfiguration: Sendable {
    public let cameras: [CaptureDeviceInfo]
    public let microphones: [CaptureDeviceInfo]
    public let cameraID: String
    public let microphoneID: String
    public let profiles: [RecordingProfile]
    public let selected: RecordingProfile
}

public enum CaptureEvent: Sendable {
    case level(Double)
    case devicesChanged
    case failed(String)
    case recordingFailed(String)
    case frames(received: Int, dropped: Int)
    case speechOverrun
}

/// All mutable capture and writer state is confined to queue. The session reference is
/// exposed only for AVCaptureVideoPreviewLayer, whose framework manages preview delivery.
public final class CaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    public let events: AsyncStream<CaptureEvent>
    private let eventSink: AsyncStream<CaptureEvent>.Continuation
    private let queue = DispatchQueue(label: "app.teleprompter.capture", qos: .userInitiated)
    private let diskQueue = DispatchQueue(label: "app.teleprompter.disk-monitor", qos: .utility)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var camera: AVCaptureDevice?
    private var microphone: AVCaptureDevice?
    private var profile: RecordingProfile?
    private var selectedFormat: AVCaptureDevice.Format?
    private var selectedFrameDuration = CMTime.invalid
    private var recorder: MovieRecorder?
    private var audioSink: AsyncStream<CapturedSample>.Continuation?
    private var lastMeter = 0.0
    private var lastDiskCheck = 0.0
    private var recordingFolder: URL?
    private var observers: [NSObjectProtocol] = []
    private var streamReadiness = CaptureStreamReadiness()
    private var watchdog: DispatchSourceTimer?
    private var failing = false
    private var diskCheckInFlight = false

    /// Metadata only; never includes audio, images, device identifiers, or script text.
    public func diagnosticSnapshot() async throws -> String {
        try await perform { [self] in
            let size = camera.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
            return "running=\(session.isRunning) preset=\(session.sessionPreset.rawValue) selected=\(profile?.label ?? "none") active=\(size?.width ?? 0)x\(size?.height ?? 0) delivered=\(streamReadiness.width)x\(streamReadiness.height) recording=\(recorder != nil) failing=\(failing)"
        }
    }

    public override init() {
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        super.init()
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.eventSink.yield(.devicesChanged)
            })
        }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.eventSink.yield(.failed("Camera capture was interrupted. Reconnect your camera and prepare a new take."))
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        watchdog?.cancel(); eventSink.finish(); audioSink?.finish()
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    public func configure(cameraID: String, microphoneID: String, profileID: String) async throws -> CaptureConfiguration {
        try await perform { [self] in
            guard recorder == nil else { throw TeleprompterError.message("Stop the current take before changing devices.") }
            let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
            let microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            guard let camera = cameras.first(where: { $0.uniqueID == cameraID }) ?? cameras.first(where: { !$0.isContinuityCamera }) ?? cameras.first else {
                throw TeleprompterError.message("No camera is available. Connect your camera or enable Continuity Camera on your iPhone.")
            }
            guard let mic = microphones.first(where: { $0.uniqueID == microphoneID }) ?? AVCaptureDevice.default(for: .audio) ?? microphones.first else {
                throw TeleprompterError.message("No microphone is available.")
            }
            if session.isRunning { session.stopRunning() }
            streamReadiness = CaptureStreamReadiness()
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            videoOutput.videoSettings = [:]
            let cameraInput = try AVCaptureDeviceInput(device: camera), microphoneInput = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
                throw TeleprompterError.message("These capture devices cannot be used together.")
            }
            session.addInput(cameraInput); session.addInput(microphoneInput)
            guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
                throw TeleprompterError.message("This camera cannot provide recordable video and audio.")
            }
            session.addOutput(videoOutput); session.addOutput(audioOutput)
            var candidates: [(RecordingProfile, AVCaptureDevice.Format, CMTime)] = []
            var seen: Set<String> = []
            var encodingSupport: [String: Bool] = [:]
            for (formatIndex, format) in camera.formats.enumerated() {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard size.width > 0, size.height > 0, size.width % 2 == 0, size.height % 2 == 0 else { continue }
                let pixelType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                guard pixelType != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                      pixelType != kCVPixelFormatType_420YpCbCr10BiPlanarFullRange else { continue }
                let dimensionsKey = "\(size.width)x\(size.height)"
                if encodingSupport[dimensionsKey] == nil {
                    var encoder: VTCompressionSession?
                    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: size.width, height: size.height,
                        codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
                    encodingSupport[dimensionsKey] = status == noErr
                    if let encoder { VTCompressionSessionInvalidate(encoder) }
                }
                guard encodingSupport[dimensionsKey] == true else { continue }
                let timings = CameraFrameTiming.options(in: format.videoSupportedFrameRateRanges.map(FrameDurationBounds.init))
                for timing in timings {
                    let fps = timing.framesPerSecond
                    let key = "\(size.width)x\(size.height)@\(fps)"
                    guard seen.insert(key).inserted else { continue }
                    let profile = RecordingProfile(id: "\(formatIndex):\(key)", width: Int(size.width), height: Int(size.height), framesPerSecond: fps)
                    candidates.append((profile, format, timing.duration))
                }
            }
            let profiles = RecordingProfile.ranked(candidates.map(\.0))
            guard let selected = profiles.first(where: { $0.id == profileID }) ?? profiles.first,
                  let candidate = candidates.first(where: { $0.0.id == selected.id }) else {
                throw TeleprompterError.message("This camera exposes no compatible SDR recording profiles.")
            }
            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
            }
            self.camera = camera; self.microphone = mic; self.profile = selected; self.failing = false
            selectedFormat = candidate.1; selectedFrameDuration = candidate.2
            return CaptureConfiguration(cameras: cameras.map { .init(id: $0.uniqueID, name: $0.localizedName, isContinuity: $0.isContinuityCamera) },
                microphones: microphones.map { .init(id: $0.uniqueID, name: $0.localizedName) }, cameraID: camera.uniqueID,
                microphoneID: mic.uniqueID, profiles: profiles, selected: selected)
        }
    }

    public func startPreview() async throws {
        try await perform { [self] in
            guard let camera, let selectedFormat, let profile else { throw TeleprompterError.message("Select a camera profile first.") }
            session.startRunning()
            guard session.isRunning else { throw TeleprompterError.message("The camera could not start.") }
            // macOS applies the session preset when starting, overriding an earlier
            // activeFormat assignment. Apply the user's native format after startup,
            // then verify actual data-output samples before declaring the camera ready.
            try TPCameraConfigurator.configureDevice(camera, format: selectedFormat, frameDuration: selectedFrameDuration)
            try TPCameraConfigurator.configureVideoOutput(videoOutput, width: profile.width, height: profile.height)
            // Changing data-output settings can renegotiate the device's duration
            // interval. Pin native timing last, after both source and output agree.
            try TPCameraConfigurator.configureDevice(camera, format: selectedFormat, frameDuration: selectedFrameDuration)
            streamReadiness = CaptureStreamReadiness()
            watchdog?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 3, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkHealth() }
            watchdog = timer; timer.resume()
        }
        // Wait off the media queue: delegates must be able to deliver real samples.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            try Task.checkCancellation()
            do { try await validateStreams(); return }
            catch { if ContinuousClock.now >= deadline { throw error } }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func validateStreams() async throws {
        try await perform { [self] in
            guard session.isRunning, let profile else { throw TeleprompterError.message("Prepare the camera before recording.") }
            try validateActiveFormat()
            try streamReadiness.validate(profile: profile, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    public func preflightRecording(folder: URL) async throws {
        try await perform { [self] in
            guard session.isRunning, let profile else { throw TeleprompterError.message("Prepare the camera before recording.") }
            try validateActiveFormat()
            try streamReadiness.validate(profile: profile, at: ProcessInfo.processInfo.systemUptime)
            try Self.checkDisk(folder, profile: profile)
        }
    }

    /// Called only on the capture queue. Output scaling must never disguise a
    /// source format or timing that differs from the advertised recording profile.
    private func validateActiveFormat() throws {
        guard let camera, let profile else { throw TeleprompterError.message("Prepare the camera before recording.") }
        let native = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        guard native.width == profile.width, native.height == profile.height,
              CMTimeCompare(camera.activeVideoMinFrameDuration, selectedFrameDuration) == 0,
              CMTimeCompare(camera.activeVideoMaxFrameDuration, selectedFrameDuration) == 0 else {
            let minimum = camera.activeVideoMinFrameDuration
            let maximum = camera.activeVideoMaxFrameDuration
            throw TeleprompterError.message("The camera did not retain the selected native format or frame rate (\(native.width) × \(native.height); frame intervals \(minimum.value)/\(minimum.timescale) to \(maximum.value)/\(maximum.timescale), expected \(selectedFrameDuration.value)/\(selectedFrameDuration.timescale)). Prepare it again or select another supported profile.")
        }
    }

    public func stopPreview() async {
        _ = try? await perform { [self] in
            watchdog?.cancel(); watchdog = nil
            session.stopRunning(); audioSink?.finish(); audioSink = nil
        }
    }

    public func speechSamples() async -> AsyncStream<CapturedSample> {
        let (stream, sink) = AsyncStream<CapturedSample>.makeStream(bufferingPolicy: .bufferingNewest(48))
        _ = try? await perform { [self] in audioSink?.finish(); audioSink = sink }
        return stream
    }

    public func stopSpeechSamples() async { _ = try? await perform { [self] in audioSink?.finish(); audioSink = nil } }

    public func startRecording(folder: URL) async throws {
        try await perform { [self] in
            guard recorder == nil, session.isRunning, let profile else { throw TeleprompterError.message("Prepare the camera before recording.") }
            let now = ProcessInfo.processInfo.systemUptime
            try validateActiveFormat()
            try streamReadiness.validate(profile: profile, at: now)
            try Self.checkDisk(folder, profile: profile)
            guard let videoSettings = videoOutput.recommendedVideoSettings(forVideoCodecType: .h264, assetWriterOutputFileType: .mp4),
                  var audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) else {
                throw TeleprompterError.message("The selected profile is not compatible with H.264/AAC MP4. Select a lower profile.")
            }
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = 192_000
            let rotation = camera.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil).videoRotationAngleForHorizonLevelCapture } ?? 0
            recorder = try MovieRecorder(folder: folder, profile: profile, videoSettings: videoSettings, audioSettings: audioSettings, rotation: rotation)
            recordingFolder = folder; lastDiskCheck = now; failing = false
        }
    }

    public func stopRecording(interrupted: Bool = false) async throws -> RecordingResult {
        let current = try await perform { [self] in
            guard let current = recorder else { throw TeleprompterError.message("No take is recording.") }
            recorder = nil; recordingFolder = nil
            return current
        }
        return try await current.finish(interrupted: interrupted)
    }

    public static func checkDisk(_ folder: URL, profile: RecordingProfile) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .isWritableKey])
        guard values.isWritable != false else { throw TeleprompterError.message("The recording folder is not writable.") }
        let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        guard free > 512 * 1_024 * 1_024 + profile.bytesPerMinute / 2 else {
            throw TeleprompterError.message("The recording drive is low on space. Free space or select another folder.")
        }
    }

    private func checkHealth() {
        guard !failing, session.isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if recorder != nil && (now - streamReadiness.lastVideoArrival > 3 || now - streamReadiness.lastAudioArrival > 3) {
            failing = true; eventSink.yield(.failed("The camera or microphone stopped delivering media. The take is being saved."))
        }
        if let folder = recordingFolder, let profile, let current = recorder, !diskCheckInFlight {
            diskCheckInFlight = true
            diskQueue.async { [weak self] in
                let failure: String?
                do { try Self.checkDisk(folder, profile: profile); failure = nil }
                catch { failure = error.localizedDescription }
                guard let self else { return }
                queue.async { [self] in
                    diskCheckInFlight = false
                    if let failure, recorder === current, !failing { failing = true; eventSink.yield(.recordingFailed(failure)) }
                }
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        let now = ProcessInfo.processInfo.systemUptime
        if CMSampleBufferDataIsReady(sampleBuffer) {
            if isVideo, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) {
                streamReadiness.noteVideo(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel), at: now)
            } else if !isVideo { streamReadiness.noteAudio(at: now) }
        }
        if !failing, let recorder {
            do {
                try recorder.append(sampleBuffer, isVideo: isVideo)
                if now - lastDiskCheck > 1 {
                    lastDiskCheck = now
                    let stats = recorder.statistics
                    eventSink.yield(.frames(received: stats.received, dropped: stats.dropped))
                }
            } catch { failing = true; eventSink.yield(.recordingFailed(error.localizedDescription)) }
        }
        if !isVideo {
            if let audioSink, case .dropped = audioSink.yield(CapturedSample(sampleBuffer)) {
                // Keep stale speech out of the UI. The coordinator restarts recognition, not recording.
                self.audioSink?.finish(); self.audioSink = nil
                eventSink.yield(.speechOverrun)
            }
            if now - lastMeter > 0.1 {
                lastMeter = now
                let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -80
                eventSink.yield(.level(min(1, max(0, pow(10, Double(db) / 20)))))
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recorder?.noteDroppedFrame()
    }
}
