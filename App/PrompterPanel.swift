import AppKit
import SwiftUI
import TeleprompterKit

/// Keep stored dimensions in their original units so existing drafts become
/// compact without rescaling their saved settings again on each launch.
enum PrompterSizing {
    static let scale = 0.6
    static let padding = 12.0 * scale
    static let cornerRadius = 24.0 * scale
    static let controlsHeight = 45.0 * scale

    static func readingSettings(_ settings: UserSettings) -> UserSettings {
        var compact = settings
        compact.fontSize *= scale
        compact.panelWidth *= scale
        compact.lineSpacing *= scale
        return compact
    }

    static func readerHeight(_ settings: UserSettings) -> Double {
        (settings.fontSize * 1.25 + settings.lineSpacing) * 3
    }

    static func panelSize(_ settings: UserSettings) -> NSSize {
        let compact = readingSettings(settings)
        return NSSize(width: compact.panelWidth + 2 * padding,
                      height: readerHeight(compact) + 3 * padding + controlsHeight + scale)
    }
}

@MainActor final class PrompterPanelController {
    private let panel: NSPanel
    private weak var model: AppModel?
    private var observer: NSObjectProtocol?
    private var visibilityGeneration = 0

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.title = "Teleprompter reading panel"
        panel.contentView = NSHostingView(rootView: FloatingPrompterView(model: model))
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resetPosition() } }
        resetPosition()
    }

    func show() {
        resize()
        visibilityGeneration += 1
        guard !panel.isVisible else { panel.alphaValue = 1; return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduced ? 1 : 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
    func hide() {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visibilityGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }
    func resize() {
        guard let model else { return }
        let size = PrompterSizing.panelSize(model.settings)
        let top = panel.frame.maxY
        let center = panel.frame.midX
        panel.setFrame(NSRect(x: center - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
    func resetPosition() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        resize()
        let usableTop = screen.frame.maxY - max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: usableTop - 6 - panel.frame.height))
    }
}

struct FloatingPrompterView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || (model.isPreview && CommandLine.arguments.contains("--reduced-motion")) }
    private var reduceTransparency: Bool { systemReduceTransparency || (model.isPreview && CommandLine.arguments.contains("--reduced-transparency")) }
    private var illuminated: Bool {
        model.following || model.speechLoading || model.phase != .idle
    }
    private var readingSettings: UserSettings { PrompterSizing.readingSettings(model.settings) }
    var body: some View {
        VStack(spacing: 0) {
            PrompterReader(script: model.script, index: model.tokenIndex, settings: readingSettings, onSeek: model.seek, suppressMotion: reduceMotion)
                .frame(height: PrompterSizing.readerHeight(readingSettings))
                .padding(.top, PrompterSizing.padding)
                .mask(alignment: .bottom) {
                    LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.78),
                                           .init(color: .white.opacity(0.3), location: 1)], startPoint: .top, endPoint: .bottom)
                }
            Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: PrompterSizing.scale)
            controls
        }
        .frame(width: readingSettings.panelWidth)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: PrompterSizing.cornerRadius, style: .continuous))
        .padding(PrompterSizing.padding)
        .overlay {
            PrompterAura(active: illuminated, visible: model.overlayVisible,
                         level: model.following && model.settings.mode == .speech ? model.microphoneLevel : 0,
                         suppressMotion: reduceMotion, suppressTransparency: reduceTransparency)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.settings.fontSize) { model.overlay?.resize() }
        .onChange(of: model.settings.panelWidth) { model.overlay?.resize() }
        .onChange(of: model.settings.lineSpacing) { model.overlay?.resize() }
    }
    private var surface: some View {
        RoundedRectangle(cornerRadius: PrompterSizing.cornerRadius, style: .continuous)
            .fill(Color(red: 0.025, green: 0.027, blue: 0.045).opacity(reduceTransparency ? 1 : model.settings.opacity))
            .overlay {
                RoundedRectangle(cornerRadius: PrompterSizing.cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.04), Color.clear], startPoint: .top, endPoint: .bottom))
            }
    }
    private var controls: some View {
            HStack(spacing: 12 * PrompterSizing.scale) {
                Button { model.toggleFollowing() } label: { Image(systemName: model.following ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(model.following ? "Pause prompter" : "Start prompter")
                Button { model.moveSentence(-1) } label: { Image(systemName: "backward.end") }.accessibilityLabel("Previous sentence")
                Button { model.moveSentence(1) } label: { Image(systemName: "forward.end") }.accessibilityLabel("Next sentence")
                Text(model.trackingStatus).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                Spacer(minLength: 0)
                if case .countdown(let count) = model.phase {
                    Text("\(count)").font(.headline.monospacedDigit()).foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: count)
                }
                if model.phase == .recording, let start = model.recordingStart {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(start, style: .timer).font(.system(size: 10, design: .monospaced)).monospacedDigit().fixedSize()
                }
                Button { model.toggleRecording() } label: { Image(systemName: model.phase == .recording ? "stop.circle.fill" : "record.circle").foregroundStyle(.red) }
                    .disabled(model.phase == .finishing || model.configuring).accessibilityLabel(model.phase == .recording ? "Stop recording" : "Record take")
                Button { model.toggleOverlay() } label: { Image(systemName: "xmark") }.accessibilityLabel("Hide prompter")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 16 * PrompterSizing.scale).frame(height: PrompterSizing.controlsHeight)
    }

}

struct PrompterReader: NSViewRepresentable {
    let script: Script
    let index: Int
    let settings: UserSettings
    let onSeek: (Int) -> Void
    var suppressMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.contentView.wantsLayer = true
        let text = ReadingTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18 * PrompterSizing.scale, height: 0)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.setAccessibilityLabel("Teleprompter script. Use Previous and Next Sentence controls to navigate.")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ReadingTextView, let storage = text.textStorage,
              let manager = text.layoutManager, let container = text.textContainer else { return }
        text.onSeek = onSeek; text.script = script
        let width = settings.panelWidth
        let styleKey = "\(settings.fontSize):\(settings.lineSpacing):\(width)"
        if text.sourceText != script.text || text.styleKey != styleKey {
            text.styleKey = styleKey
            text.sourceText = script.text
            let display = PromptText(script: script)
            text.tokenRanges = display.tokenRanges
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = settings.lineSpacing
            paragraph.minimumLineHeight = settings.fontSize * 1.25
            paragraph.maximumLineHeight = settings.fontSize * 1.25
            storage.setAttributedString(NSAttributedString(string: script.text.isEmpty ? "Your script appears here." : display.text, attributes: [
                .font: NSFont.systemFont(ofSize: settings.fontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.78), .paragraphStyle: paragraph]))
            text.setFrameSize(NSSize(width: width, height: 1))
            container.containerSize = NSSize(width: width - 36 * PrompterSizing.scale, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height + (settings.fontSize * 1.25 + settings.lineSpacing) * 3
            text.setFrameSize(NSSize(width: width, height: height))
            text.lastIndex = -1
        }
        guard !script.tokens.isEmpty, index < script.tokens.count, text.lastIndex != index else { return }
        text.lastIndex = index
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.78), range: fullRange)
        let range = text.tokenRanges[index]
        if range.location > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.4), range: NSRange(location: 0, length: range.location))
        }
        storage.addAttributes([.foregroundColor: NSColor(red: 0.48, green: 0.96, blue: 0.81, alpha: 1),
                               .backgroundColor: NSColor.white.withAlphaComponent(0.06)], range: range)
        storage.endEditing()
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = NSPoint(x: 0, y: max(0, line.minY))
        if abs(scroll.contentView.bounds.minY - origin.y) > 0.5 {
            if reduceMotion || suppressMotion { scroll.contentView.setBoundsOrigin(origin) }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22; context.allowsImplicitAnimation = true
                    scroll.contentView.animator().setBoundsOrigin(origin)
                }
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

final class ReadingTextView: NSTextView {
    var script = Script("")
    var onSeek: ((Int) -> Void)?
    var styleKey = ""
    var sourceText = ""
    var tokenRanges: [NSRange] = []
    var lastIndex = -1
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard let layoutManager, let textContainer else { return }
        var location = convert(event.locationInWindow, from: nil)
        location.x -= textContainerOrigin.x; location.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        if let index = tokenRanges.firstIndex(where: { NSLocationInRange(character, $0) }) { onSeek?(index) }
    }
}
