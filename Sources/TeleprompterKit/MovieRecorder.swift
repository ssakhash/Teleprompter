import AVFoundation
import Foundation

/// CMSampleBuffer is immutable for the lifetime of this retained handoff. No mutable audio
/// buffers cross queues; the speech worker makes its own PCM copy before conversion.
public struct CapturedSample: @unchecked Sendable {
    public let buffer: CMSampleBuffer
    public init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

public struct RecordingResult: Sendable {
    public let url: URL
    public let duration: Double
    public let receivedFrames: Int
    public let droppedFrames: Int
    public let recovered: Bool
    public let warning: String?
}

public struct MediaInspection: Sendable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let fps: Float
    public let videoCodec: FourCharCode
    public let audioCodec: FourCharCode
    public let startSkew: Double
    public let endSkew: Double
}

/// Queue confined to CaptureService's serial media queue (or a single test caller).
public final class MovieRecorder: @unchecked Sendable {
    public let temporaryURL: URL
    public let finalURL: URL
    public let profile: RecordingProfile
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private var started = false
    private var sessionStart = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime = CMTime.invalid
    private var receivedFrames = 0
    private var droppedFrames = 0
    private var pendingAudio: [CMSampleBuffer] = []
    private var firstFailure: Error?

    public init(folder: URL, profile: RecordingProfile, videoSettings: [String: Any]? = nil,
                audioSettings: [String: Any]? = nil, rotation: CGFloat = 0) throws {
        self.profile = profile
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = "Take-\(stamp)-\(UUID().uuidString.prefix(6))"
        finalURL = folder.appendingPathComponent(name).appendingPathExtension("mp4")
        temporaryURL = folder.appendingPathComponent(".\(name).partial.mp4")
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        var settings = videoSettings ?? [:]
        settings[AVVideoCodecKey] = AVVideoCodecType.h264
        settings[AVVideoWidthKey] = profile.width
        settings[AVVideoHeightKey] = profile.height
        settings[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: profile.bitrate,
            AVVideoExpectedSourceFrameRateKey: profile.framesPerSecond,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
        ]
        settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let sound = audioSettings ?? [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000]
        guard writer.canApply(outputSettings: settings, forMediaType: .video),
              writer.canApply(outputSettings: sound, forMediaType: .audio) else {
            throw TeleprompterError.message("The encoder cannot record this profile. Choose a lower supported profile.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: sound)
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        video.transform = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw TeleprompterError.message("The selected audio/video combination cannot be written to MP4.")
        }
        writer.add(video); writer.add(audio)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        guard writer.startWriting() else { throw writer.error ?? TeleprompterError.message("Could not start the MP4 writer.") }
    }

    public func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        do { try appendSample(sample, isVideo: isVideo) }
        catch {
            if firstFailure == nil { firstFailure = error }
            throw error
        }
    }

    private func appendSample(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        guard CMSampleBufferDataIsReady(sample) else { return }
        guard writer.status == .writing else { throw writer.error ?? TeleprompterError.message("Recording stopped unexpectedly.") }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric else { return }
        if isVideo {
            guard let image = CMSampleBufferGetImageBuffer(sample) else {
                throw TeleprompterError.message("The camera delivered a video sample without an image buffer.")
            }
            guard CVPixelBufferGetWidth(image) == profile.width, CVPixelBufferGetHeight(image) == profile.height else {
                throw TeleprompterError.message("The camera delivered \(CVPixelBufferGetWidth(image)) × \(CVPixelBufferGetHeight(image)) frames, but this take requires \(profile.width) × \(profile.height). Prepare the camera again to verify its output format.")
            }
            receivedFrames += 1
            if !started {
                sessionStart = time
                writer.startSession(atSourceTime: time)
                started = true
            }
            if lastVideoTime.isValid, time <= lastVideoTime { droppedFrames += 1; return }
            guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
            guard video.append(sample) else { throw writer.error ?? TeleprompterError.message("The video encoder failed.") }
            lastVideoTime = time
            if !pendingAudio.isEmpty {
                let buffered = pendingAudio; pendingAudio.removeAll()
                for item in buffered { try append(item, isVideo: false) }
            }
        } else {
            guard started else {
                if pendingAudio.count < 16 { pendingAudio.append(sample) }
                return
            }
            guard time >= sessionStart, !lastAudioTime.isValid || time > lastAudioTime else { return }
            guard audio.isReadyForMoreMediaData else {
                throw TeleprompterError.message("Audio encoding could not keep up. The take was stopped to preserve synchronization.")
            }
            guard audio.append(sample) else { throw writer.error ?? TeleprompterError.message("The audio encoder failed.") }
            lastAudioTime = time
        }
    }

    public func noteDroppedFrame() { receivedFrames += 1; droppedFrames += 1 }
    public var statistics: (received: Int, dropped: Int) { (receivedFrames, droppedFrames) }

    /// Call only after sample delivery to this writer has ceased.
    public func finish(interrupted: Bool = false) async throws -> RecordingResult {
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw firstFailure ?? TeleprompterError.message("No camera frames were received. Check the selected camera and try again.")
        }
        if writer.status == .writing {
            video.markAsFinished(); audio.markAsFinished()
            await writer.finishWriting()
        }
        guard writer.status == .completed else {
            throw TeleprompterError.message("This take is incomplete. Its temporary file was retained for recovery. \(writer.error?.localizedDescription ?? "")")
        }
        let inspection = try await Self.inspect(temporaryURL)
        guard inspection.duration > 0, inspection.width == profile.width, inspection.height == profile.height,
              inspection.videoCodec == kCMVideoCodecType_H264, inspection.audioCodec == kAudioFormatMPEG4AAC else {
            throw TeleprompterError.message("The saved take did not pass media validation. Its temporary file has been retained.")
        }
        let resultURL = interrupted ? finalURL.deletingPathExtension().appendingPathExtension("recovered.mp4") : finalURL
        try FileManager.default.moveItem(at: temporaryURL, to: resultURL)
        var warnings: [String] = []
        if inspection.startSkew > 0.1 || inspection.endSkew > 0.1 {
            warnings.append("Audio/video endpoint timing differs by more than 100 ms. Review the take before using it.")
        }
        if receivedFrames > 0 && Double(droppedFrames) / Double(receivedFrames) >= 0.01 {
            warnings.append("At least 1% of video frames were dropped. Consider selecting a lower profile for the next take.")
        }
        if inspection.duration > 5 && Double(inspection.fps) < profile.framesPerSecond * 0.98 {
            warnings.append("The achieved frame rate was below the selected profile. Check lighting and camera load before the next take.")
        }
        return RecordingResult(url: resultURL, duration: inspection.duration,
                               receivedFrames: receivedFrames, droppedFrames: droppedFrames, recovered: interrupted,
                               warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    public static func inspect(_ url: URL) async throws -> MediaInspection {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videoTracks.first, let audio = audioTracks.first else {
            throw TeleprompterError.message("The file does not contain both a video and an audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await video.load(.naturalSize)
        let fps = try await video.load(.nominalFrameRate)
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        guard duration.isFinite, duration > 0, videoRange.duration.seconds > 0, audioRange.duration.seconds > 0,
              videoRange.start.seconds.isFinite, audioRange.start.seconds.isFinite else {
            throw TeleprompterError.message("The file does not contain a nonempty, correctly timed audio and video take.")
        }
        let videoDescriptions = try await video.load(.formatDescriptions)
        let audioDescriptions = try await audio.load(.formatDescriptions)
        return MediaInspection(duration: duration, width: Int(size.width), height: Int(size.height), fps: fps,
            videoCodec: videoDescriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0,
            audioCodec: audioDescriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0,
            startSkew: abs(videoRange.start.seconds - audioRange.start.seconds),
            endSkew: abs(videoRange.end.seconds - audioRange.end.seconds))
    }

    public static func recover(_ url: URL) async throws -> URL {
        _ = try await inspect(url)
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TeleprompterError.message("This partial file cannot be recovered.")
        }
        let recovered = url.deletingLastPathComponent().appendingPathComponent("Recovered-\(UUID().uuidString.prefix(8)).mp4")
        do {
            try await export.export(to: recovered, as: .mp4)
            _ = try await inspect(recovered)
            return recovered
        } catch {
            try? FileManager.default.removeItem(at: recovered)
            throw error
        }
    }
}
