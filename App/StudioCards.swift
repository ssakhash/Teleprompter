import SwiftUI
import AppKit
import TeleprompterKit

struct ScriptEditorCard: View {
    @Bindable var model: AppModel
    let editorHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editorFocused: Bool

    private var theme: StudioTheme { StudioTheme(colorScheme: colorScheme) }
    private var readingSettings: UserSettings { PrompterSizing.readingSettings(model.settings) }
    private var saveStatus: String {
        if model.draftRecoveryRequired { return "Draft recovery required" }
        return model.scriptLocked ? "Locked during reading" : "Saved on this Mac"
    }

    var body: some View {
        StudioCard(title: "Your script", systemImage: "doc.text", tone: .script, status: saveStatus) {
            if model.draftRecoveryRequired {
                Button { model.useNewDraftAfterLoadFailure() } label: {
                    Text("Preserve old draft & enable saving this script").fixedSize(horizontal: false, vertical: true)
                }.font(.caption)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(.system(size: 17)).lineSpacing(7).scrollContentBackground(.hidden)
                    .padding(14).disabled(model.scriptLocked)
                    .focused($editorFocused)
                    .accessibilityLabel("Script editor")
                    .accessibilityIdentifier("studio.editor")
                if model.draft.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "text.quote").font(.system(size: 30))
                            .foregroundStyle(StudioCardTone.script.palette(for: colorScheme).heading)
                        Text("Start with something worth saying.").font(.title3.weight(.medium))
                        Text("Paste your script here. Your voice will guide the words beneath the camera—pauses, restarts, and all.")
                            .font(.body).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(24).allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(theme.editor, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)) }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statistics; Spacer(minLength: 0); returnButton }
                VStack(alignment: .leading, spacing: 8) { statistics; returnButton }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { dimensions; Spacer(minLength: 0); overlayButton }
                VStack(alignment: .leading, spacing: 8) { dimensions; overlayButton }
            }
        }
        .onChange(of: model.scriptLocked) { _, locked in
            // macOS can leave a disabled TextEditor as first responder. End editing when a take locks the draft.
            if locked { editorFocused = false }
        }
    }

    private var statistics: some View {
        Text("\(model.script.tokens.count) words · ~\(max(1, Int(ceil(Double(model.script.tokens.count) / model.settings.wordsPerMinute)))) min at \(Int(model.settings.wordsPerMinute)) wpm")
            .font(.caption).monospacedDigit().foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var returnButton: some View {
        if !model.draft.isEmpty {
            Button("Return to beginning", systemImage: "arrow.counterclockwise") { model.seek(to: 0) }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    private var dimensions: some View {
        Text("Reading width \(readingSettings.panelWidth.formatted(.number.precision(.fractionLength(0...1)))) pt · Text \(readingSettings.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
            .font(.caption).monospacedDigit().foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var overlayButton: some View {
        Button(model.overlayVisible ? "Hide prompter" : "Show prompter", systemImage: "rectangle.topthird.inset.filled") {
            model.toggleOverlay()
        }.controlSize(.small)
    }
}

struct CameraPreviewCard: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        StudioCard(title: "Camera engine", systemImage: "video", tone: .camera,
                   status: model.configuring ? "Preparing…" : model.cameraReady ? "Ready" : nil) {
            preview
            if let configuration = model.configuration {
                VStack(spacing: 8) {
                    StudioSelectionMenu(title: "Camera", selection: $model.settings.cameraID,
                                        options: configuration.cameras.map { .init(id: $0.id, name: $0.name) })
                        .onChange(of: model.settings.cameraID) { old, new in
                            if old != new && new != model.configuration?.cameraID {
                                model.settings.profileID = ""; model.changeCaptureSettings()
                            }
                        }
                    StudioSelectionMenu(title: "Microphone", selection: $model.settings.microphoneID,
                                        options: configuration.microphones.map { .init(id: $0.id, name: $0.name) })
                        .onChange(of: model.settings.microphoneID) { old, new in
                            if old != new && new != model.configuration?.microphoneID { model.changeCaptureSettings() }
                        }
                    StudioSelectionMenu(title: "Quality", selection: $model.settings.profileID,
                                        options: configuration.profiles.map { .init(id: $0.id, name: $0.label) })
                        .onChange(of: model.settings.profileID) { old, new in
                            if old != new && !new.isEmpty && new != model.configuration?.selected.id { model.changeCaptureSettings() }
                        }
                    if configuration.cameras.contains(where: \.isContinuity) {
                        Text("Continuity Camera available in the Camera menu.")
                            .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text("H.264 · AAC · MP4").foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                        Spacer(minLength: 8)
                        Button("Refresh devices") { Task { _ = await model.prepareCamera() } }.buttonStyle(.borderless)
                    }.font(.caption)
                }.disabled(model.recordingBusy || model.configuring)
            }
            microphoneMeter
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.cameraReady {
                CameraPreview(preview: model.previewLayer)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video").font(.system(size: 28))
                    Text("Frame your next take").font(.callout)
                    Button(model.configuring ? "Preparing…" : "Prepare camera") {
                        Task { _ = await model.prepareCamera() }
                    }.disabled(model.configuring || model.recordingBusy)
                }
                .foregroundStyle(.white.opacity(0.8))
                .tint(StudioCardTone.camera.palette(for: .dark).heading)
                .padding(12)
                .environment(\.colorScheme, .dark)
            }
            if case .countdown(let count) = model.phase {
                Text("\(count)").font(.system(size: 76, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).shadow(radius: 10)
            }
            if model.phase == .recording {
                VStack {
                    HStack {
                        Label("REC", systemImage: "circle.fill").font(.caption.bold()).foregroundStyle(.red)
                            .padding(8).background(.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }.padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Camera preview")
    }

    private var microphoneMeter: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill").foregroundStyle(StudioCardTone.camera.palette(for: colorScheme).heading)
            GeometryReader { geometry in
                let level = min(1, max(0, model.microphoneLevel))
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(level > 0.92 ? Color.orange : StudioCardTone.storage.palette(for: colorScheme).heading)
                    .frame(width: max(2, geometry.size.width * level))
            }.frame(height: 5)
            Text("INPUT").font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(model.microphoneLevel * 100)) percent")
    }
}

struct RecordingControlsCard: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = StudioTheme(colorScheme: colorScheme)
        StudioCard(title: "Recording controls", systemImage: "play.circle", tone: .recording) {
            Picker("Reading mode", selection: $model.settings.mode) {
                ForEach(PrompterMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Reading mode")
            .disabled(model.following || model.speechLoading)

            HStack(spacing: 8) {
                Button { model.moveSentence(-1) } label: { Image(systemName: "backward.end") }
                    .accessibilityLabel("Previous sentence").help("Previous sentence")
                Button { model.toggleFollowing() } label: {
                    Label(model.following || model.speechLoading ? "Pause prompter" : "Rehearse script",
                          systemImage: model.following ? "pause.fill" : "play.fill")
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }.disabled(model.script.tokens.isEmpty || model.configuring)
                Button { model.moveSentence(1) } label: { Image(systemName: "forward.end") }
                    .accessibilityLabel("Next sentence").help("Next sentence")
            }.controlSize(.large)

            if model.settings.mode == .timed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reading speed")
                        Spacer()
                        Text("\(Int(model.settings.wordsPerMinute)) wpm").monospacedDigit()
                    }.font(.caption)
                    Slider(value: $model.settings.wordsPerMinute, in: 30...300)
                        .accessibilityLabel("Reading speed")
                        .accessibilityValue("\(Int(model.settings.wordsPerMinute)) words per minute")
                }
            }
            HStack {
                Text("Countdown").foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                Spacer()
                Text(countdownLabel).monospacedDigit()
            }.font(.caption)

            Label(model.trackingStatus, systemImage: model.following ? "waveform" : "pause.circle")
                .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)

            Button { model.toggleRecording() } label: {
                Label(recordButtonTitle, systemImage: model.phase == .recording ? "stop.fill" : "record.circle")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(model.phase == .recording ? Color.white : theme.recordLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(model.phase == .recording ? .red : theme.recordButton)
            .disabled(model.phase == .finishing || model.configuring || model.script.tokens.isEmpty)
            .accessibilityIdentifier("studio.record")

            Text("The script and controls stay out of your video. Pausing the prompter keeps the camera rolling.")
                .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)
            if let take = model.lastTake {
                Divider()
                HStack {
                    Button("Play last take", systemImage: "play.circle") { NSWorkspace.shared.open(take) }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([take]) } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Reveal last take in Finder").help("Reveal last take in Finder")
                }.font(.caption)
            }
        }
    }

    private var countdownLabel: String {
        if case .countdown(let remaining) = model.phase { return "\(remaining)…" }
        return "3 seconds"
    }

    private var recordButtonTitle: String {
        switch model.phase {
        case .idle: "Record take"
        case .preparing: "Cancel preparation"
        case .countdown: "Cancel countdown"
        case .recording: "Stop & save take"
        case .finishing: "Saving take…"
        }
    }
}

struct StoragePrivacyCard: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        StudioCard(title: "Storage & privacy", systemImage: "folder", tone: .storage) {
            Button { model.chooseFolder() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                    Text(model.recordingFolder?.lastPathComponent ?? "Choose recording folder")
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption)
                }.padding(10)
                .background(StudioTheme(colorScheme: colorScheme).controlSurface, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(model.recordingBusy)
            if let folder = model.recordingFolder {
                Text(folder.path).font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let profile = model.selectedProfile {
                Text("About \(ByteCountFormatter.string(fromByteCount: profile.bytesPerMinute, countStyle: .file)) per minute at this quality.")
                    .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if !model.partialTakes.isEmpty {
                Divider()
                Text("Incomplete takes").font(.callout.weight(.medium))
                ForEach(model.partialTakes, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.lastPathComponent).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button("Recover") { model.recover(url) }.disabled(model.recordingBusy)
                            .accessibilityLabel("Recover \(url.lastPathComponent)")
                    }
                }
            }
            Label("Files stay on this Mac.", systemImage: "lock")
                .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SpeechAssetsCard: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        StudioCard(title: "Speech & assets", systemImage: "waveform", tone: .speech) {
            Text("English · On-device").font(.callout)
            if let download = model.downloadProgress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installing speech assets…").font(.callout)
                    ProgressView(value: min(1, max(0, download)))
                        .accessibilityLabel("English speech asset download")
                    Text(download.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).monospacedDigit().foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                }
            } else if model.speechLoading {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.trackingStatus).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else if model.following && model.settings.mode == .speech {
                Label(model.trackingStatus, systemImage: "waveform")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Starts with voice following").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("macOS installs speech assets when needed. Download progress appears here.")
                .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)
            Text("Manual and fixed-speed reading work without speech assets.")
                .font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
