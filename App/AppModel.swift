import AppKit
import AVFoundation
import Observation
import TeleprompterKit

enum RecordingPhase: Equatable {
    case idle, preparing, countdown(Int), recording, finishing
}

@MainActor @Observable final class AppModel {
    var draft: String = "" { didSet { scheduleSave() } }
    var settings = UserSettings() { didSet { scheduleSave() } }
    var script = Script("")
    var tokenIndex = 0
    var trackingStatus = TrackingStatus.paused.rawValue
    var following = false
    var speechLoading = false
    var downloadProgress: Double?
    var phase = RecordingPhase.idle
    var recordingStart: Date?
    var cameraReady = false
    var configuring = false
    var configuration: CaptureConfiguration?
    var microphoneLevel = 0.0
    var receivedFrames = 0
    var droppedFrames = 0
    var recordingFolder: URL?
    var lastTake: URL?
    var partialTakes: [URL] = []
    var notice: String?
    var noticeIsError = false
    var overlayVisible = false
    var showSettings = false
    var isShuttingDown = false
    var draftRecoveryRequired = false
    let capture = CaptureService()
    // Keep the preview connection alive across SwiftUI updates and window changes.
    // Reassigning a preview layer's session can renegotiate camera frame timing.
    let previewLayer: AVCaptureVideoPreviewLayer
    private let speech = SpeechService()
    private let store = LocalStore()
    private var aligner = ScriptAligner(script: Script(""))
    private var saveTask: Task<Void, Never>?
    private var scriptTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var timedTask: Task<Void, Never>?
    private var speechVersion = UUID()
    private var activity: NSObjectProtocol?
    private var lastSpeechTime = Date.distantPast
    private var observingTasks: [Task<Void, Never>] = []
    private var notifications: [NSObjectProtocol] = []
    private var maySave = true
    let isPreview: Bool
    var overlay: PrompterPanelController?
    var hotkeys: HotKeyController?

    var recordingBusy: Bool { phase != .idle }
    var scriptLocked: Bool { recordingBusy || following || speechLoading }
    var selectedProfile: RecordingProfile? { configuration?.selected }
    var wordCount: Int { Script(draft).tokens.count }
    var progress: Double { script.tokens.isEmpty ? 0 : Double(tokenIndex + 1) / Double(script.tokens.count) }

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        previewLayer = AVCaptureVideoPreviewLayer(session: capture.session)
        if isPreview {
            maySave = false
            draft = "Great ideas deserve to be heard.\n\nToday, I want to share a different way to think about the work we do. A way that starts with curiosity, makes room for mistakes, and turns small moments of progress into something meaningful.\n\nThe most important thing is to begin. Take one clear step, learn from what happens, and keep moving forward.\n\nYou do not need to have every answer. You just need a story worth telling—and the courage to tell it."
        } else {
            do { let saved = try store.load(); draft = saved.text; settings = saved.settings.sanitized() }
            catch { maySave = false; draftRecoveryRequired = true; showError("Could not restore the draft. \(error.localizedDescription)") }
            do { recordingFolder = try store.restoreFolder() } catch { showError(error.localizedDescription) }
        }
        rebuildScript()
        observingTasks.append(Task { [weak self, capture] in
            for await event in capture.events { guard let self else { return }; await self.handleCapture(event) }
        })
        observingTasks.append(Task { [weak self, speech] in
            for await event in speech.events { guard let self else { return }; self.handleSpeech(event) }
        })
        observingTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if following && settings.mode == .speech && !speechLoading && Date().timeIntervalSince(lastSpeechTime) > 2 {
                    trackingStatus = TrackingStatus.waiting.rawValue
                }
            }
        })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleSleep() }
            })
        refreshPartials()
    }

    func setUpWindows() {
        guard overlay == nil else { return }
        overlay = PrompterPanelController(model: self)
        if !isPreview { hotkeys = HotKeyController(model: self); registerHotkeys() }
    }

    func registerHotkeys() {
        do { try hotkeys?.register(settings.shortcutKeyCodes) }
        catch { showError(error.localizedDescription) }
    }

    func rebuildScript() {
        script = Script(draft)
        aligner = ScriptAligner(script: script)
        tokenIndex = 0
    }

    func scheduleScriptUpdate() {
        scriptTask?.cancel()
        let text = draft
        scriptTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let parsed = await Task.detached(priority: .userInitiated) { Script(text) }.value
            guard let self, !Task.isCancelled, !scriptLocked, draft == text, script.text != text else { return }
            script = parsed; aligner = ScriptAligner(script: parsed); tokenIndex = 0
        }
    }

    func scheduleSave() {
        guard maySave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard maySave else { return }
        do { try store.save(SavedDraft(text: draft, settings: settings)) }
        catch { showError("Your draft could not be saved. \(error.localizedDescription)") }
    }

    func useNewDraftAfterLoadFailure() {
        do {
            try store.preserveUnreadableDraft()
            maySave = true; draftRecoveryRequired = false; scheduleSave()
        } catch { showError("Could not preserve the unreadable draft: \(error.localizedDescription)") }
    }

    func chooseFolder() {
        guard !recordingBusy else { return }
        do { if let folder = try store.chooseFolder() { recordingFolder = folder; refreshPartials() } }
        catch { showError(error.localizedDescription) }
    }

    func prepareCamera() async -> Bool {
        guard !configuring, phase == .idle || phase == .preparing else { return cameraReady }
        configuring = true
        defer { configuring = false }
        do {
            for type in [AVMediaType.video, .audio] {
                let status = AVCaptureDevice.authorizationStatus(for: type)
                var granted = status == .authorized
                if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: type) }
                guard granted else {
                    throw TeleprompterError.message("Allow Camera and Microphone access in System Settings → Privacy & Security, then prepare the camera again.")
                }
            }
            await pauseFollowing()
            configuration = try await capture.configure(cameraID: settings.cameraID, microphoneID: settings.microphoneID, profileID: settings.profileID)
            if let configuration {
                settings.cameraID = configuration.cameraID; settings.microphoneID = configuration.microphoneID
                settings.profileID = configuration.selected.id
            }
            try await capture.startPreview()
            cameraReady = true
            return true
        } catch {
            await capture.stopPreview()
            cameraReady = false; showError(error.localizedDescription); return false
        }
    }

    func changeCaptureSettings() {
        guard !recordingBusy else { return }
        cameraReady = false
        Task { _ = await prepareCamera() }
    }

    func toggleOverlay() {
        setUpWindows()
        overlayVisible.toggle()
        if overlayVisible { if script.text != draft && !scriptLocked { rebuildScript() }; overlay?.show() } else { overlay?.hide() }
    }

    func ensureOverlay() {
        setUpWindows()
        overlayVisible = true; overlay?.show()
    }

    func toggleFollowing() {
        Task {
            if following || speechLoading { await pauseFollowing() }
            else { await beginFollowing() }
        }
    }

    func beginFollowing(rebuild: Bool = true) async {
        guard !following, !speechLoading else { return }
        if rebuild && !recordingBusy && script.text != draft { rebuildScript() }
        guard !script.tokens.isEmpty else { showError("Paste a script before starting the prompter."); return }
        if settings.mode == .speech && !cameraReady { guard await prepareCamera() else { return } }
        ensureOverlay()
        following = true
        if settings.mode == .speech {
            startSpeech()
        } else if settings.mode == .timed {
            trackingStatus = "Fixed-speed scrolling"
            timedTask?.cancel()
            timedTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    do { try await Task.sleep(for: .seconds(60 / max(30, settings.wordsPerMinute))) } catch { return }
                    guard following else { return }
                    if tokenIndex < script.tokens.count - 1 { tokenIndex += 1 }
                    else { following = false; trackingStatus = TrackingStatus.finished.rawValue; return }
                }
            }
        } else { trackingStatus = "Manual navigation" }
    }

    private func startSpeech() {
        speechTask?.cancel()
        let version = UUID(); speechVersion = version
        let generation = aligner.reposition(to: tokenIndex)
        speechLoading = true
        speechTask = Task { [weak self, speech, capture] in
            do {
                await capture.stopSpeechSamples()
                try Task.checkCancellation()
                try await speech.start(sampleProvider: { await capture.speechSamples() }, generation: generation)
                guard let self, speechVersion == version else { return }
                speechLoading = false; downloadProgress = nil
            } catch {
                guard let self, speechVersion == version, !Task.isCancelled else { return }
                speechLoading = false; following = false; downloadProgress = nil
                trackingStatus = "Voice following unavailable"
                showError(error.localizedDescription)
            }
        }
    }

    func pauseFollowing() async {
        following = false; speechLoading = false; downloadProgress = nil
        speechVersion = UUID()
        _ = aligner.reposition(to: tokenIndex)
        speechTask?.cancel(); speechTask = nil
        timedTask?.cancel(); timedTask = nil
        await capture.stopSpeechSamples()
        await speech.stop()
        trackingStatus = TrackingStatus.paused.rawValue
    }

    func seek(to index: Int) {
        if script.tokens.isEmpty { rebuildScript() }
        tokenIndex = min(max(0, index), max(0, script.tokens.count - 1))
        _ = aligner.reposition(to: tokenIndex)
        if following && settings.mode == .speech { startSpeech() }
    }

    func moveSentence(_ offset: Int) { seek(to: script.sentenceStart(relativeTo: tokenIndex, offset: offset)) }

    func toggleRecording() {
        switch phase {
        case .recording: Task { await stopRecording() }
        case .preparing, .countdown:
            recordingTask?.cancel()
            Task { await pauseFollowing() }
        case .finishing: break
        case .idle:
            guard recordingTask == nil || recordingTask?.isCancelled == true else { return }
            recordingTask = Task { [weak self] in await self?.beginRecording(); self?.recordingTask = nil }
        }
    }

    private func beginRecording() async {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { showError("Paste your script before recording."); return }
        if recordingFolder == nil { chooseFolder() }
        guard let folder = recordingFolder else { return }
        phase = .preparing
        defer { if phase == .preparing { phase = .idle } }
        if !cameraReady { guard await prepareCamera() else { return } }
        guard !Task.isCancelled else { return }
        if tokenIndex == script.tokens.count - 1 { seek(to: 0) }
        if !following { await beginFollowing() }
        // Model setup can take a while; let the user cancel preparation through the prompter control.
        if speechLoading { await speechTask?.value }
        guard !Task.isCancelled else { return }
        let resumeFollowing = following
        await pauseFollowing()
        trackingStatus = "Ready to record"
        ensureOverlay()
        do {
            try await capture.preflightRecording(folder: folder)
            for number in (1...3).reversed() {
                phase = .countdown(number)
                try await Task.sleep(for: .seconds(1))
            }
            try Task.checkCancellation()
            try await capture.startRecording(folder: folder)
            if Task.isCancelled {
                _ = try? await capture.stopRecording(interrupted: true)
                phase = .idle
                return
            }
            phase = .recording; recordingStart = Date()
            receivedFrames = 0; droppedFrames = 0
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a teleprompter take")
            notice = nil
            if resumeFollowing { await beginFollowing(rebuild: false) }
        } catch is CancellationError { phase = .idle }
        catch { phase = .idle; showError(error.localizedDescription) }
    }

    func stopRecording(interrupted: Bool = false, cause: String? = nil) async {
        guard phase == .recording else { return }
        phase = .finishing
        await pauseFollowing()
        defer {
            phase = .idle; recordingStart = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            refreshPartials()
        }
        do {
            let result = try await capture.stopRecording(interrupted: interrupted)
            lastTake = result.url
            receivedFrames = result.receivedFrames; droppedFrames = result.droppedFrames
            if !interrupted {
                noticeIsError = false
                notice = "Take saved. \(Int(result.duration)) seconds · \(result.droppedFrames) dropped frames."
            }
            if let warning = result.warning {
                noticeIsError = true
                notice = (interrupted ? "Interrupted take saved. " : "Take saved. ") + warning
            }
            if let cause { showError("\(cause) The playable portion was saved.\(result.warning.map { " " + $0 } ?? "")") }
        } catch { showError(cause.map { $0 == error.localizedDescription ? $0 : "\($0) \(error.localizedDescription)" } ?? error.localizedDescription) }
    }

    private func handleCapture(_ event: CaptureEvent) async {
        switch event {
        case .level(let level): microphoneLevel = level
        case .frames(let received, let dropped): receivedFrames = received; droppedFrames = dropped
        case .devicesChanged:
            if !recordingBusy && cameraReady && !configuring && !following {
                noticeIsError = false; notice = "Available devices changed. Refresh devices to update the camera and microphone list."
            }
        case .failed(let message):
            showError(message)
            if phase == .recording { await stopRecording(interrupted: true, cause: message) }
            else if case .countdown = phase { recordingTask?.cancel(); phase = .idle }
            cameraReady = false
            await pauseFollowing()
            await capture.stopPreview()
        case .recordingFailed(let message):
            if phase == .recording { await stopRecording(interrupted: true, cause: message) }
            else { showError(message) }
        case .speechOverrun:
            await pauseFollowing()
            showError("Voice following fell behind and was paused. Resume it to synchronize again. Your video recording continues.")
        }
    }

    private func handleSpeech(_ event: SpeechServiceEvent) {
        guard following || speechLoading else { return }
        switch event {
        case .status(let text): trackingStatus = text
        case .download(let progress): downloadProgress = progress
        case .ready: speechLoading = false; downloadProgress = nil; trackingStatus = TrackingStatus.listening.rawValue
        case .result(let result):
            guard following, result.generation == aligner.generation else { return }
            let update = aligner.consume(result)
            tokenIndex = update.index; trackingStatus = update.status.rawValue; lastSpeechTime = Date()
            if update.status == .finished { Task { await pauseFollowing(); trackingStatus = TrackingStatus.finished.rawValue } }
        case .failed(let message):
            Task { await pauseFollowing(); showError("Voice following paused: \(message). Video recording is unaffected.") }
        }
    }

    func refreshPartials() {
        guard let folder = recordingFolder else { partialTakes = []; return }
        do { partialTakes = try store.partialTakes(in: folder) }
        catch { showError("Could not inspect incomplete takes: \(error.localizedDescription)") }
    }

    func recover(_ url: URL) {
        Task {
            do {
                lastTake = try await MovieRecorder.recover(url)
                noticeIsError = false; notice = "Recovered the playable portion of the take. The original partial file has been preserved."
            } catch { showError("This take could not be recovered: \(error.localizedDescription). The original file has been preserved.") }
        }
    }

    func showError(_ text: String) { noticeIsError = true; notice = text }

    private func handleSleep() async {
        recordingTask?.cancel()
        if phase == .recording { await stopRecording(interrupted: true) }
        await pauseFollowing(); await capture.stopPreview(); cameraReady = false
        if case .countdown = phase { phase = .idle }
    }

    func shutdown() async {
        isShuttingDown = true
        recordingTask?.cancel(); saveTask?.cancel(); scriptTask?.cancel(); saveNow()
        await recordingTask?.value
        if phase == .recording { await stopRecording() }
        while phase == .finishing { try? await Task.sleep(for: .milliseconds(100)) }
        await pauseFollowing(); await capture.stopPreview()
        observingTasks.forEach { $0.cancel() }
        notifications.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
