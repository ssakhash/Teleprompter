import SwiftUI
import AppKit

@main struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel(isPreview: CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--capture-check")))
    }

    var body: some Scene {
        WindowGroup("Teleprompter", id: "studio") {
            StudioView(model: model)
                .frame(minWidth: 940, minHeight: 650)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model; model.setUpWindows()
                }
        }
        .defaultSize(width: 1120, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Prompter") {
                Button("Show / Hide Prompter") { model.toggleOverlay() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Follow / Pause") { model.toggleFollowing() }
                Button("Previous Sentence") { model.moveSentence(-1) }
                Button("Next Sentence") { model.moveSentence(1) }
                Button("Reset Below Notch") { model.ensureOverlay(); model.overlay?.resetPosition() }
            }
        }
        MenuBarExtra {
            MenuBarControls(model: model)
        } label: {
            Image(systemName: model.phase == .recording ? "record.circle.fill" : "text.viewfinder")
                .accessibilityLabel(model.phase == .recording ? "Teleprompter recording" : "Teleprompter")
        }
    }


}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var diagnosticWindow: NSWindow?
    private var completingTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--capture-check") || CommandLine.arguments.contains("--snapshot") else { return }
        let diagnostic = AppModel(isPreview: true)
        model = diagnostic
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = CommandLine.arguments.contains("--capture-check") ? "Teleprompter — capture check" : "Teleprompter"
        window.contentView = NSHostingView(rootView: StudioView(model: diagnostic).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil)
        diagnosticWindow = window
        NSApp.activate()
        if CommandLine.arguments.contains("--capture-check") {
            Task { await CaptureCheck.run(model: diagnostic) }
        } else {
            SnapshotCheck.run(model: diagnostic, window: window)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if completingTermination { return .terminateNow }
        guard let model else { return .terminateNow }
        Task {
            await model.shutdown()
            completingTermination = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarControls: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.phase == .recording ? "● Recording" : "Teleprompter")
        if model.phase == .recording, let start = model.recordingStart { Text(start, style: .timer) }
        Button("Open Studio") { openWindow(id: "studio"); NSApp.activate() }
        Divider()
        Button(model.overlayVisible ? "Hide Prompter" : "Show Prompter") { model.toggleOverlay() }
        Button(model.following ? "Pause Prompter" : "Start Prompter") { model.toggleFollowing() }
        Button(model.phase == .recording ? "Stop and Save Take" : "Record Take") { model.toggleRecording() }
            .disabled(model.phase == .finishing || model.configuring)
        Button("Previous Sentence") { model.moveSentence(-1) }
        Button("Next Sentence") { model.moveSentence(1) }
        Divider()
        Button("Quit Teleprompter") { NSApp.terminate(nil) }
    }
}
