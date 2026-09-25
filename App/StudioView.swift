import SwiftUI
import AVFoundation

struct StudioView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var theme: StudioTheme { StudioTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let contentWidth = max(0, geometry.size.width - 48)
                let captureWidth = min(440, max(344, (contentWidth - 16) * 0.36))
                let workspaceWidth = max(0, contentWidth - captureWidth - 16)
                let utilities = utilityLayout(width: workspaceWidth)

                ScrollView {
                    // Keep the editor and preview mounted while resizing or scrolling.
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow(alignment: .top) {
                            VStack(spacing: 16) {
                                ScriptEditorCard(model: model, editorHeight: max(320, geometry.size.height - 440))
                                utilities {
                                    StoragePrivacyCard(model: model)
                                    SpeechAssetsCard(model: model)
                                }
                            }
                            .frame(width: workspaceWidth)

                            VStack(spacing: 16) {
                                CameraPreviewCard(model: model)
                                RecordingControlsCard(model: model)
                            }
                            .frame(width: captureWidth)
                        }
                    }
                    .padding(24)
                }
                .accessibilityIdentifier("studio.dashboard")
            }
            if let notice = model.notice { noticeView(notice) }
            footer
        }
        .background(theme.canvas)
        .foregroundStyle(theme.text)
        .tint(StudioCardTone.script.palette(for: colorScheme).heading)
        .sheet(isPresented: $model.showSettings) { PrompterSettingsView(model: model) }
        .onChange(of: model.draft) { _, _ in
            if !model.scriptLocked { model.scheduleScriptUpdate() }
        }
    }

    private func utilityLayout(width: CGFloat) -> AnyLayout {
        width >= 576
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder").font(.system(size: 26, weight: .medium))
                .foregroundStyle(StudioCardTone.script.palette(for: colorScheme).heading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Teleprompter").font(.custom("Georgia-Bold", size: 25, relativeTo: .title))
                Text("YOUR WORDS. YOUR PACE.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Label("On-device · English", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(theme.secondaryText)
            Button { model.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).padding(5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Appearance and keyboard shortcuts")
            .help("Appearance and keyboard shortcuts")
        }
        .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 20)
    }

    private func noticeView(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.noticeIsError ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(model.noticeIsError ? Color.orange : StudioCardTone.storage.palette(for: colorScheme).heading)
            Text(notice).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .padding(14).background(theme.controlSurface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            Label("PRIVATE BY DESIGN", systemImage: "lock")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
            Spacer()
            if model.phase == .recording, let start = model.recordingStart {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(start, style: .timer).font(.system(.caption, design: .monospaced)).monospacedDigit()
                Text("· \(model.droppedFrames) dropped frames").font(.caption)
            } else {
                Text("Ready when you are.").font(.caption)
            }
        }
        .foregroundStyle(theme.secondaryText).padding(.horizontal, 24).padding(.vertical, 14)
        .background(theme.canvas)
        .overlay(alignment: .top) { Divider() }
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
