import AppKit
import TeleprompterKit

/// Renders only this app's own fixture views; never captures the user's screen.
@MainActor enum SnapshotCheck {
    static func run(model: AppModel, window: NSWindow) {
        guard let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 else { exit(2) }
        let output = CommandLine.arguments[flag + 1]
        setbuf(stdout, nil)
        model.following = true
        model.trackingStatus = TrackingStatus.listening.rawValue
        model.tokenIndex = 3
        model.microphoneLevel = 0.4
        model.ensureOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                try render(window, to: output)
                // SwiftUI can also create an idle panel for its studio scene.
                guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.title == "Teleprompter reading panel" }) else { exit(3) }
                try render(panel, to: output + ".prompter.png", opaqueBackground: true)
                let first = aura(in: panel.contentView)?.presentationAngle
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    do {
                        try render(panel, to: output + ".prompter-later.png", opaqueBackground: true)
                        let second = aura(in: panel.contentView)?.presentationAngle
                        if CommandLine.arguments.contains("--reduced-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            guard first == nil && second == nil else { print("FAIL: motion remained enabled"); exit(5) }
                            print("PASS: reduced-motion perimeter is stationary")
                        } else {
                            guard let first, let second, abs(second - first) > 0.1 else { print("FAIL: perimeter animation did not progress"); exit(5) }
                            print("PASS: compositor orbit progressed from \(first) to \(second) radians")
                        }
                        exit(0)
                    }
                    catch { exit(4) }
                }
            } catch { exit(4) }
        }
    }
    private static func aura(in view: NSView?) -> AuraView? {
        guard let view else { return nil }
        if let aura = view as? AuraView { return aura }
        for child in view.subviews { if let found = aura(in: child) { return found } }
        return nil
    }
    private static func render(_ window: NSWindow, to path: String, opaqueBackground: Bool = false) throws {
        guard let view = window.contentView else { throw TeleprompterError.message("Missing preview view") }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TeleprompterError.message("Cannot render preview view") }
        view.cacheDisplay(in: view.bounds, to: image)
        var rendered = image
        if opaqueBackground {
            guard let composite = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.pixelsWide,
                pixelsHigh: image.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: composite) else {
                throw TeleprompterError.message("Cannot create screenshot background")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let bounds = NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
            NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).setFill()
            bounds.fill()
            let foreground = NSImage(size: image.size)
            foreground.addRepresentation(image)
            foreground.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            rendered = composite
        }
        guard let png = rendered.representation(using: .png, properties: [:]) else { throw TeleprompterError.message("Cannot encode preview image") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
