import AVFoundation
import Foundation
import TeleprompterKit
import Speech

@main struct MediaProbe {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "frame-rates" {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
            guard !devices.isEmpty else { throw TeleprompterError.message("No camera metadata is available.") }
            for device in devices {
                var checked = 0
                var rejectedOldDurations = 0
                for format in device.formats {
                    let ranges = format.videoSupportedFrameRateRanges.map(FrameDurationBounds.init)
                    for option in CameraFrameTiming.options(in: ranges) {
                        guard ranges.contains(where: { $0.contains(option.duration) }) else {
                            throw TeleprompterError.message("Selected an unsupported duration.")
                        }
                        let old = CMTime(seconds: 1 / option.framesPerSecond, preferredTimescale: 1_000_000_000)
                        if !ranges.contains(where: { $0.contains(old) }) { rejectedOldDurations += 1 }
                        checked += 1
                    }
                }
                print("PASS \(device.localizedName): \(checked) exact frame-rate choices validated; \(rejectedOldDurations) would fail with the previous rounding.")
            }
            return
        }
        if args.count > 1 && args[1] == "capabilities" {
            print("On-device SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
            print("Installed English locales: \(await SpeechTranscriber.installedLocales.filter { $0.language.languageCode?.identifier == "en" }.map(\.identifier))")
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
            for device in devices {
                let profiles = device.formats.compactMap { format -> RecordingProfile? in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() else { return nil }
                    return RecordingProfile(id: "", width: Int(dimensions.width), height: Int(dimensions.height), framesPerSecond: fps)
                }
                print("Camera: \(device.localizedName), Continuity: \(device.isContinuityCamera), highest advertised: \(RecordingProfile.ranked(profiles).first?.label ?? "unknown")")
            }
            return
        }
        if args.count >= 4 && args[1] == "speech" {
            try await checkSpeech(audioURL: URL(fileURLWithPath: args[2]), scriptURL: URL(fileURLWithPath: args[3]))
            return
        }
        guard args.count >= 3 else {
            print("Usage: MediaProbe generate <folder> [seconds] | crash <folder> [seconds] | inspect <mp4> | recover <partial.mp4>")
            return
        }
        let url = URL(fileURLWithPath: args[2])
        if args[1] == "inspect" {
            let info = try await MovieRecorder.inspect(url)
            print("\(info.width)x\(info.height), \(info.fps) fps, \(info.duration)s, start skew \(info.startSkew)s, end skew \(info.endSkew)s, video \(info.videoCodec), audio \(info.audioCodec)")
            return
        }
        if args[1] == "recover" { print(try await MovieRecorder.recover(url).path); return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let seconds = args.count > 3 ? Int(args[3]) ?? 3 : 3
        let recorder = try MovieRecorder(folder: url, profile: .init(id: "synthetic", width: 1280, height: 720, framesPerSecond: 30))
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for frame in 0..<(seconds * 30) {
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixel)
            let image = pixel!
            CVPixelBufferLockBaseAddress(image, [])
            memset(CVPixelBufferGetBaseAddress(image), Int32(frame % 255), CVPixelBufferGetDataSize(image))
            CVPixelBufferUnlockBaseAddress(image, [])
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            try recorder.append(sample!, isVideo: true)
            let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 1600)!
            pcm.frameLength = 1600
            for i in 0..<1600 {
                pcm.floatChannelData![0][i] = Float(sin(Double(frame * 1600 + i) * 2 * .pi * 440 / 48_000) * 0.15)
            }
            var audioSample: CMSampleBuffer?
            var audioTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48_000), decodeTimeStamp: .invalid)
            let create = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: audioFormat.formatDescription,
                sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &audioTiming,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &audioSample)
            guard create == noErr, let audioSample else { throw TeleprompterError.message("Synthetic audio creation failed.") }
            let copied = CMSampleBufferSetDataBufferFromAudioBufferList(audioSample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
            guard copied == noErr else { throw TeleprompterError.message("Synthetic PCM copy failed.") }
            CMSampleBufferSetDataReady(audioSample)
            try recorder.append(audioSample, isVideo: false)
            try await Task.sleep(for: .milliseconds(34))
        }
        if args[1] == "crash" {
            print("INTERRUPTED \(recorder.temporaryURL.path)")
            fflush(stdout)
            _exit(93)
        }
        let result = try await recorder.finish()
        print("PASS \(result.url.path) | \(result.duration)s | \(result.receivedFrames) frames | \(result.droppedFrames) dropped")
        guard result.droppedFrames == 0 else { throw TeleprompterError.message("Synthetic frames were dropped.") }
        let info = try await MovieRecorder.inspect(result.url)
        guard info.startSkew < 0.1, info.endSkew < 0.1 else { throw TeleprompterError.message("A/V synchronization exceeded 100 ms.") }
    }

    static func checkSpeech(audioURL: URL, scriptURL: URL) async throws {
        let script = Script(try String(contentsOf: scriptURL, encoding: .utf8))
        let service = SpeechService()
        let initial = ScriptAligner(script: script)
        let generation = initial.generation
        let samples = try FixtureSamples(url: audioURL)
        let resultTask = Task { () -> (Int, [Double]) in
            var aligner = initial
            var furthest = 0
            var latencies: [Double] = []
            for await event in service.events {
                if Task.isCancelled { break }
                switch event {
                case .result(let result):
                    let update = aligner.consume(result)
                    furthest = max(furthest, update.index)
                    if let started = samples.started {
                        let lag = Date().timeIntervalSince(started) - result.end
                        latencies.append(lag)
                    }
                    print("Speech: position \(update.index + 1)/\(script.tokens.count), \(update.status.rawValue), final=\(result.isFinal)")
                    if CommandLine.arguments.contains("--verbose") { print("Fixture hypothesis: \(result.text)") }
                case .failed(let message): print("Speech error: \(message)")
                case .status(let status): print(status)
                default: break
                }
            }
            return (furthest, latencies)
        }
        try await service.start(sampleProvider: { samples.stream() }, generation: generation)
        try await Task.sleep(for: .seconds(samples.duration + 6))
        await service.stop()
        resultTask.cancel()
        let (furthest, lag) = await resultTask.value
        let sorted = lag.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("Streaming speech fixture: reached \(furthest + 1)/\(script.tokens.count) words, result-end lag p95 \(p95)s")
        guard furthest >= script.tokens.count - 3 else { throw TeleprompterError.message("Speech fixture did not follow to the end.") }
    }
}

/// The file is read once by its detached producer; started is guarded for the metrics reader.
final class FixtureSamples: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var startDate: Date?
    var started: Date? { lock.withLock { startDate } }
    let duration: Double
    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }
    func stream() -> AsyncStream<CapturedSample> {
        let (stream, sink) = AsyncStream<CapturedSample>.makeStream(bufferingPolicy: .bufferingNewest(48))
        let producer = Task.detached { [self] in
            lock.withLock { startDate = Date() }
            let format = file.processingFormat
            let started = ContinuousClock.now
            var offset: Int64 = 0
            do {
                while file.framePosition < file.length && !Task.isCancelled {
                    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
                    try file.read(into: pcm)
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
                        presentationTimeStamp: CMTime(value: offset, timescale: Int32(format.sampleRate)), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                        sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
                    guard let sample else { throw TeleprompterError.message("Could not create speech test PCM sample.") }
                    CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
                    CMSampleBufferSetDataReady(sample)
                    sink.yield(CapturedSample(sample))
                    offset += Int64(pcm.frameLength)
                    try await ContinuousClock().sleep(until: started.advanced(by: .seconds(Double(offset) / format.sampleRate)))
                }
            } catch { print("Fixture input: \(error.localizedDescription)") }
            sink.finish()
        }
        sink.onTermination = { _ in producer.cancel() }
        return stream
    }
}
