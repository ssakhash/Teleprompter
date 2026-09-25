import AppKit
import SwiftUI
import TeleprompterKit

/// A fixture may be larger than the physical display; rendering reads its own view, not the screen.
@MainActor final class StudioSnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Exercises the real Studio view with fixture state, without starting capture or touching saved drafts.
@MainActor enum StudioSnapshotCheck {
    static func run(model: AppModel, window: NSWindow, output: String) {
        Task {
            do {
                try await check(model: model, window: window, output: output)
                print("PASS: Studio appearance, resizing, editor/preview identity, and fixture renders")
                exit(0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(6)
            }
        }
    }

    private static func check(model: AppModel, window: NSWindow, output: String) async throws {
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = model.draft
        model.settings.mode = .timed
        model.microphoneLevel = 0.4
        let sizes = [NSSize(width: 940, height: 650), NSSize(width: 1120, height: 790),
                     NSSize(width: 1440, height: 1000)]

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for size in sizes {
                resize(window, to: size)
                await settle(window)
                try render(window, to: directory.appendingPathComponent("\(name)-\(Int(size.width))x\(Int(size.height)).png"))
                if let scroll = dashboardScroll(in: window.contentView) {
                    let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await settle(window)
                    try render(window, to: directory.appendingPathComponent("\(name)-\(Int(size.width))-bottom.png"))
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        // Keep the same root view and preview session through both appearances and all widths.
        model.cameraReady = true
        resize(window, to: sizes[1])
        await settle(window)
        guard let editor = descendant(NSTextView.self, in: window.contentView),
              let preview = descendant(PreviewView.self, in: window.contentView) else {
            throw failure("Could not find the editor and preview for the resize check.")
        }
        let session = model.previewLayer.session
        let selection = NSRange(location: 6, length: 5)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(selection)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in sizes {
                resize(window, to: size)
                await settle(window)
                guard descendant(NSTextView.self, in: window.contentView) === editor,
                      descendant(PreviewView.self, in: window.contentView) === preview,
                      window.firstResponder === editor,
                      editor.selectedRange() == selection,
                      model.previewLayer.session === session,
                      model.draft == sample else {
                    throw failure("Resizing or appearance switching replaced the editor/preview or disturbed editing.")
                }
            }
        }
        print("PASS: editor focus, selection, draft, preview view and session survive appearance/size changes")

        sendLetter(to: window)
        await settle(window)
        guard model.draft != sample else { throw failure("The editable fixture did not receive the keyboard event.") }
        model.draft = sample
        await settle(window)
        resize(window, to: sizes[0])
        for (name, phase) in [("preparing", RecordingPhase.preparing), ("countdown", .countdown(2)),
                              ("recording", .recording), ("finishing", .finishing)] {
            model.phase = phase
            model.recordingStart = phase == .recording ? Date().addingTimeInterval(-75) : nil
            await settle(window)
            try render(window, to: directory.appendingPathComponent("phase-\(name).png"))
            sendLetter(to: window)
            await settle(window)
            guard model.draft == sample else { throw failure("Typing changed the locked script during \(name).") }
        }
        model.phase = .idle
        model.recordingStart = nil
        for loading in [false, true] {
            await settle(window)
            window.makeFirstResponder(editor)
            await settle(window)
            model.following = !loading
            model.speechLoading = loading
            await settle(window)
            sendLetter(to: window)
            await settle(window)
            guard model.draft == sample else { throw failure("Typing changed the script; speech loading: " + String(loading)) }
            model.following = false
            model.speechLoading = false
        }
        model.cameraReady = false

        for scheme in [ColorScheme.light, .dark] {
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let prefix = scheme == .dark ? "dark" : "light"
            model.draft = ""
            model.rebuildScript()
            await settle(window)
            try render(window, to: directory.appendingPathComponent("\(prefix)-empty.png"))

            model.draft = Array(repeating: sample, count: 20).joined(separator: "\n\n")
            model.rebuildScript()
            model.recordingFolder = URL(fileURLWithPath: "/Users/Fixture/Movies/A long recording destination for the weekly studio presentation")
            model.partialTakes = [model.recordingFolder!.appendingPathComponent("A-long-incomplete-take-from-the-weekly-studio-presentation.partial.mp4")]
            model.draftRecoveryRequired = true
            model.noticeIsError = true
            model.notice = "Fixture error: The selected recording destination is unavailable. Choose a folder and try again."
            model.speechLoading = true
            model.downloadProgress = 0.42
            model.trackingStatus = "Downloading the English speech model…"
            await settle(window)
            try render(window, to: directory.appendingPathComponent("\(prefix)-recovery-download-top.png"))
            if let scroll = dashboardScroll(in: window.contentView) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle(window)
                try render(window, to: directory.appendingPathComponent("\(prefix)-recovery-download-bottom.png"))
                scroll.contentView.scroll(to: .zero)
            }
            model.speechLoading = false
            model.downloadProgress = nil
            model.draftRecoveryRequired = false
            model.notice = nil
            model.partialTakes = []
            model.recordingFolder = nil

            // Use the production menu component with long fixture names; no device discovery is needed.
            let controls = NSHostingView(rootView:
                StudioCard(title: "Camera engine", systemImage: "video", tone: .camera) {
                    StudioSelectionMenu(title: "Camera", selection: .constant("camera"),
                        options: [.init(id: "camera", name: "A very long Continuity Camera device name — Studio camera")])
                    StudioSelectionMenu(title: "Microphone", selection: .constant("mic"),
                        options: [.init(id: "mic", name: "External USB microphone with a long descriptive device name")])
                    StudioSelectionMenu(title: "Quality", selection: .constant("quality"),
                        options: [.init(id: "quality", name: "3840 × 2160 · 59.94 fps")])
                }
                .padding(24).frame(width: 392)
                .environment(\.colorScheme, scheme)
            )
            let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 360),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            menuWindow.contentView = controls
            menuWindow.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            menuWindow.setContentSize(controls.fittingSize)
            menuWindow.orderFront(nil)
            await settle(menuWindow)
            try render(menuWindow, to: directory.appendingPathComponent("\(prefix)-long-device-menus.png"))
            menuWindow.orderOut(nil)
        }
        model.draft = sample
        model.rebuildScript()
        print("PASS: recording locks; light/dark empty, long-script, recovery, download and long-device fixtures")
    }

    private static func resize(_ window: NSWindow, to size: NSSize) {
        // setContentSize may constrain a window to the current display. Set the fixture's frame explicitly.
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true, animate: false)
    }

    private static func settle(_ window: NSWindow) async {
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func sendLetter(to window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) {
            window.sendEvent(event)
        }
    }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private static func dashboardScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) { return scroll }
        for child in view.subviews {
            if let scroll = dashboardScroll(in: child) { return scroll }
        }
        return nil
    }

    private static func failure(_ message: String) -> TeleprompterError { .message(message) }

    private static func render(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw failure("Cannot create a Studio fixture bitmap.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("Cannot encode the Studio fixture.")
        }
        try png.write(to: url)
    }
}
