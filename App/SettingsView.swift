import SwiftUI
import TeleprompterKit

struct PrompterSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let keys: [(String, UInt32)] = [("R", 15), ("P", 35), ("S", 1), ("F", 3), ("Space", 49), ("←", 123), ("→", 124), ("↑", 126), ("↓", 125)]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Make it your own").font(.title2.weight(.semibold)); Spacer(); Button("Done") { model.registerHotkeys(); dismiss() }.keyboardShortcut(.defaultAction) }
            Form {
                Section("Reading panel") {
                    slider("Text size", value: $model.settings.fontSize, range: 20...48, suffix: "pt")
                    slider("Panel width", value: $model.settings.panelWidth, range: 380...900, suffix: "pt")
                    slider("Line spacing", value: $model.settings.lineSpacing, range: 2...20, suffix: "pt")
                    slider("Background opacity", value: $model.settings.opacity, range: 0.45...1, suffix: "", scale: 100)
                    Button("Reset panel beneath the notch") { model.ensureOverlay(); model.overlay?.resetPosition() }
                }
                Section("Fixed-speed reading") {
                    slider("Reading speed", value: $model.settings.wordsPerMinute, range: 30...300, suffix: "wpm")
                }
                Section("Global keyboard shortcuts · Control + Option + Command") {
                    shortcut("Record / stop", action: "record")
                    shortcut("Follow / pause", action: "pause")
                    shortcut("Previous sentence", action: "previous")
                    shortcut("Next sentence", action: "next")
                    Text("Shortcuts work while another app is active. Choose a different key for each action.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 560, height: 640).preferredColorScheme(.dark)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, scale: Double = 1) -> some View {
        HStack {
            Text(title).frame(width: 135, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * scale)) \(suffix)").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }
    private func shortcut(_ title: String, action: String) -> some View {
        Picker(title, selection: Binding(get: { model.settings.shortcutKeyCodes[action] ?? 15 }, set: { model.settings.shortcutKeyCodes[action] = $0 })) {
            ForEach(keys, id: \.1) { key in Text(key.0).tag(key.1) }
        }
    }
}
