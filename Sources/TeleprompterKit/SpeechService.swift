import AVFoundation
import Speech

public enum SpeechServiceEvent: Sendable {
    case status(String)
    case download(Double)
    case ready
    case result(SpeechEvent)
    case failed(String)
}

/// AVAudioConverter invokes its input block synchronously during convert(). This box is
/// exclusively owned by that one conversion and never reused or shared with another task.
private final class ConverterInput: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    var delivered = false
    init(_ pcm: AVAudioPCMBuffer) { self.pcm = pcm }
}

public actor SpeechService {
    public nonisolated let events: AsyncStream<SpeechServiceEvent>
    private let sink: AsyncStream<SpeechServiceEvent>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var inputTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var generation = UUID()

    public init() { (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64)) }

    public func start(sampleProvider: @Sendable () async -> AsyncStream<CapturedSample>, generation: UUID) async throws {
        inputTask?.cancel(); inputTask = nil
        resultTask?.cancel(); resultTask = nil
        let previous = analyzer; analyzer = nil
        self.generation = generation
        await previous?.cancelAndFinishNow()
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        guard SpeechTranscriber.isAvailable else { throw TeleprompterError.message("On-device speech recognition is unavailable on this Mac. Use manual or fixed-speed mode.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
            throw TeleprompterError.message("English speech recognition is unavailable. Use manual or fixed-speed mode.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        sink.yield(.status("Preparing on-device English recognition…"))
        _ = try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            sink.yield(.status("Downloading the English speech model…"))
            let progressTask = Task { [sink] in
                while !Task.isCancelled {
                    sink.yield(.download(request.progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TeleprompterError.message("Could not negotiate a speech audio format.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard self.generation == generation else { await analyzer.cancelAndFinishNow(); throw CancellationError() }
        self.analyzer = analyzer
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        resultTask = Task { [sink] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    sink.yield(.result(.init(start: result.range.start.seconds, end: result.range.end.seconds,
                        text: String(result.text.characters), isFinal: result.isFinal, generation: generation)))
                }
            } catch { if !Task.isCancelled { sink.yield(.failed(error.localizedDescription)) } }
        }
        try await analyzer.start(inputSequence: input)
        let samples = await sampleProvider()
        inputTask = Task { [sink] in
            let diagnostic = ProcessInfo.processInfo.environment["TELEPROMPTER_SPEECH_DIAGNOSTICS"] == "1"
            var blockCount = 0
            var converter: AVAudioConverter?
            var sourceFormat: AVAudioFormat?
            var outputFrames: Int64 = 0
            var previousSourceEnd: CMTime?
            do {
                for await sample in samples {
                    try Task.checkCancellation()
                    let pcm = try Self.copyPCM(sample.buffer)
                    blockCount += 1
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample.buffer)
                    if let previousSourceEnd, abs(CMTimeSubtract(pts, previousSourceEnd).seconds) > 0.25 {
                        throw TeleprompterError.message("The microphone audio stream changed timing. Resume voice following to synchronize again.")
                    }
                    previousSourceEnd = CMTimeAdd(pts, CMTime(value: Int64(pcm.frameLength), timescale: Int32(pcm.format.sampleRate)))
                    if sourceFormat != pcm.format {
                        sourceFormat = pcm.format
                        converter = AVAudioConverter(from: pcm.format, to: format)
                    }
                    guard let converter else { throw TeleprompterError.message("Cannot convert microphone audio for speech recognition.") }
                    let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * format.sampleRate / pcm.format.sampleRate)) + 256
                    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
                    let source = ConverterInput(pcm)
                    var error: NSError?
                    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                        if source.delivered { inputStatus.pointee = .noDataNow; return nil }
                        source.delivered = true; inputStatus.pointee = .haveData; return source.pcm
                    }
                    if diagnostic && blockCount % 20 == 1 {
                        let peak = pcm.floatChannelData.map { pointer in (0..<Int(pcm.frameLength)).map { abs(pointer[0][$0]) }.max() ?? 0 } ?? -1
                        print("Speech PCM: block=\(blockCount), input=\(pcm.frameLength)@\(pcm.format.sampleRate), peak=\(peak), output=\(converted.frameLength)@\(format.sampleRate), delivered=\(source.delivered), status=\(status.rawValue)")
                    }
                    if let error { throw error }
                    guard status != .error, converted.frameLength > 0 else { continue }
                    // Resampling can round a block up or down by one frame. A contiguous
                    // clock in the destination format avoids overlapping analyzer inputs.
                    // The original capture timestamps remain untouched in the MP4 branch.
                    let start = CMTime(value: outputFrames, timescale: Int32(format.sampleRate))
                    outputFrames += Int64(converted.frameLength)
                    if case .dropped = continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start)) {
                        throw TeleprompterError.message("Speech processing fell behind. Resume voice following to synchronize again; recording is unaffected.")
                    }
                }
                continuation.finish()
                if !Task.isCancelled { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            } catch {
                continuation.finish()
                if !Task.isCancelled { sink.yield(.failed(error.localizedDescription)) }
            }
        }
        sink.yield(.ready)
    }

    public func stop() async {
        generation = UUID()
        inputTask?.cancel(); inputTask = nil
        resultTask?.cancel(); resultTask = nil
        let previous = analyzer; analyzer = nil
        await previous?.cancelAndFinishNow()
    }

    private static func copyPCM(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw TeleprompterError.message("The microphone supplied an unsupported audio format.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            throw TeleprompterError.message("The microphone supplied an unsupported audio format.")
        }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw TeleprompterError.message("Could not read microphone audio (\(status)).") }
        return pcm
    }
}
