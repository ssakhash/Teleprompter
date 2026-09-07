import SwiftUI
import AVFoundation
import TeleprompterKit

private let accent = Color(red: 0.45, green: 0.88, blue: 0.77)

struct StudioView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 24) {
                scriptEditor.frame(maxWidth: .infinity, maxHeight: .infinity)
                captureControls.frame(width: 344)
            }
            .padding(24)
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.noticeIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(model.noticeIsError ? .orange : accent)
                    Text(notice).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }
                .padding(14).background(.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.bottom, 16)
            }
            footer
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.078))
        .tint(accent)
        .sheet(isPresented: $model.showSettings) { PrompterSettingsView(model: model) }
        .onChange(of: model.draft) { _, _ in if !model.scriptLocked { model.scheduleScriptUpdate() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Teleprompter").font(.system(size: 21, weight: .semibold))
                Text("YOUR WORDS. YOUR PACE.").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            }
            Spacer()
            Label("On-device · English", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).padding(5) }
                .buttonStyle(.plain).help("Appearance and keyboard shortcuts")
        }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 20)
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your script").font(.title3.weight(.semibold))
                Spacer()
                Label(model.scriptLocked ? "Locked during reading" : "Saved on this Mac", systemImage: model.scriptLocked ? "lock" : "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.draftRecoveryRequired {
                Button("Preserve old draft & enable saving this script") { model.useNewDraftAfterLoadFailure() }
                    .font(.caption)
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.035))
                if model.draft.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "text.quote").font(.system(size: 34)).foregroundStyle(accent.opacity(0.6))
                        Text("Start with something worth saying.").font(.title2.weight(.medium))
                        Text("Paste your script here. Your voice will guide the words beneath the camera—pauses, restarts, and all.")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                    }.padding(28).allowsHitTesting(false)
                }
                TextEditor(text: $model.draft)
                    .font(.system(size: 17)).lineSpacing(7).scrollContentBackground(.hidden)
                    .padding(18).disabled(model.scriptLocked)
                    .accessibilityLabel("Script editor")
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
            HStack {
                Text("\(model.script.tokens.count) words").font(.caption.monospacedDigit())
                Text("·")
                Text("~\(max(1, Int(ceil(Double(model.script.tokens.count) / model.settings.wordsPerMinute)))) min at \(Int(model.settings.wordsPerMinute)) wpm").font(.caption)
                Spacer()
                if !model.draft.isEmpty {
                    Button("Return to beginning") { model.seek(to: 0) }.buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                }
            }.foregroundStyle(.secondary)
            VStack(spacing: 12) {
                HStack {
                    Picker("Reading mode", selection: $model.settings.mode) {
                        ForEach(PrompterMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.following || model.speechLoading)
                    Button { model.toggleOverlay() } label: { Image(systemName: model.overlayVisible ? "rectangle.topthird.inset.filled" : "rectangle.topthird.inset.filled") }
                        .help(model.overlayVisible ? "Hide floating prompter" : "Show floating prompter")
                }
                HStack(spacing: 10) {
                    Button { model.moveSentence(-1) } label: { Image(systemName: "backward.end") }.accessibilityLabel("Previous sentence")
                    Button { model.toggleFollowing() } label: {
                        Label(model.following || model.speechLoading ? "Pause prompter" : "Rehearse script", systemImage: model.following ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.script.tokens.isEmpty || model.configuring)
                    Button { model.moveSentence(1) } label: { Image(systemName: "forward.end") }.accessibilityLabel("Next sentence")
                }
                HStack(spacing: 7) {
                    Circle().fill(model.following ? accent : .secondary).frame(width: 5, height: 5)
                    Text(model.trackingStatus).font(.caption).lineLimit(2)
                    Spacer()
                    if let download = model.downloadProgress { ProgressView(value: download).frame(width: 80) }
                }.foregroundStyle(.secondary)
            }.padding(16).background(.white.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var captureControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Camera & recording").font(.title3.weight(.semibold))
                    Spacer()
                    if model.configuring { ProgressView().controlSize(.small) }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.black)
                    if model.cameraReady { CameraPreview(preview: model.previewLayer).clipShape(RoundedRectangle(cornerRadius: 14)) }
                    else {
                        VStack(spacing: 10) {
                            Image(systemName: "video").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("Frame your next take").font(.callout).foregroundStyle(.secondary)
                            Button(model.configuring ? "Preparing…" : "Prepare camera") { Task { _ = await model.prepareCamera() } }
                                .disabled(model.configuring || model.recordingBusy)
                        }
                    }
                    if case .countdown(let count) = model.phase {
                        Text("\(count)").font(.system(size: 76, weight: .bold, design: .rounded)).shadow(radius: 10)
                    }
                    if model.phase == .recording {
                        VStack { HStack { Label("REC", systemImage: "circle.fill").font(.caption.bold()).foregroundStyle(.red).padding(8).background(.black.opacity(0.6)).clipShape(Capsule()); Spacer() }; Spacer() }.padding(10)
                    }
                }.aspectRatio(16 / 9, contentMode: .fit)
                if let configuration = model.configuration {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Camera", selection: $model.settings.cameraID) {
                            ForEach(configuration.cameras) { Text($0.name).tag($0.id) }
                        }.onChange(of: model.settings.cameraID) { old, new in
                            if old != new && new != model.configuration?.cameraID { model.settings.profileID = ""; model.changeCaptureSettings() }
                        }
                        Picker("Microphone", selection: $model.settings.microphoneID) {
                            ForEach(configuration.microphones) { Text($0.name).tag($0.id) }
                        }.onChange(of: model.settings.microphoneID) { old, new in
                            if old != new && new != model.configuration?.microphoneID { model.changeCaptureSettings() }
                        }
                        Picker("Quality", selection: $model.settings.profileID) {
                            ForEach(configuration.profiles) { Text($0.label).tag($0.id) }
                        }.onChange(of: model.settings.profileID) { old, new in
                            if old != new && !new.isEmpty && new != model.configuration?.selected.id { model.changeCaptureSettings() }
                        }
                        HStack {
                            Text("H.264 · AAC · MP4").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh devices") { Task { _ = await model.prepareCamera() } }.buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                        }
                    }.disabled(model.recordingBusy || model.configuring)
                }
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.07))
                        Capsule().fill(model.microphoneLevel > 0.92 ? Color.orange : accent)
                            .frame(width: max(2, geometry.size.width * model.microphoneLevel))
                    }.frame(height: 5)
                    Text("INPUT").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("Microphone level").accessibilityValue("\(Int(model.microphoneLevel * 100)) percent")
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("SAVE TAKES TO").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                    Button { model.chooseFolder() } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(accent)
                            Text(model.recordingFolder?.lastPathComponent ?? "Choose recording folder").lineLimit(1).truncationMode(.middle)
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(12).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(model.recordingBusy)
                    if let profile = model.selectedProfile {
                        Text("About \(ByteCountFormatter.string(fromByteCount: profile.bytesPerMinute, countStyle: .file)) per minute at this quality.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { model.toggleRecording() } label: {
                    HStack {
                        Image(systemName: model.phase == .recording ? "stop.fill" : "record.circle")
                        Text(recordButtonTitle).fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).tint(model.phase == .recording ? .red : accent)
                    .disabled(model.phase == .finishing || model.configuring || model.script.tokens.isEmpty)
                Text("The script and controls stay out of your video. Pausing the prompter keeps the camera rolling.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let take = model.lastTake {
                    HStack {
                        Button("Play last take") { NSWorkspace.shared.open(take) }
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([take]) } label: { Image(systemName: "folder") }.help("Reveal last take in Finder")
                    }
                }
                if !model.partialTakes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Incomplete takes", systemImage: "arrow.clockwise").font(.callout.weight(.medium))
                        ForEach(model.partialTakes, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                Button("Recover") { model.recover(url) }.disabled(model.recordingBusy)
                            }
                        }
                    }.padding(12).background(.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }.scrollIndicators(.hidden)
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

    private var footer: some View {
        HStack {
            Label("PRIVATE BY DESIGN", systemImage: "lock").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
            Spacer()
            if model.phase == .recording, let start = model.recordingStart {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(start, style: .timer).font(.system(.caption, design: .monospaced)).monospacedDigit()
                Text("· \(model.droppedFrames) dropped frames").font(.caption)
            } else { Text("Ready when you are.").font(.caption) }
        }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 14).background(.black.opacity(0.18))
    }
}

struct CameraPreview: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: preview) }
    func updateNSView(_ view: PreviewView, context: Context) { view.updateMirroring() }
}

final class PreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true; layer = preview
        preview.videoGravity = .resizeAspect
        updateMirroring()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func layout() { super.layout(); preview.frame = bounds; updateMirroring() }
    func updateMirroring() {
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if !connection.isVideoMirrored { connection.isVideoMirrored = true }
        }
    }
}
