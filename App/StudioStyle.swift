import SwiftUI

/// A card keeps the same color family across appearances, with readable tonal headings.
enum StudioCardTone: CaseIterable {
    case script, camera, recording, storage, speech

    func palette(for scheme: ColorScheme) -> StudioCardPalette {
        let colors: (UInt32, UInt32, UInt32, UInt32)
        switch self {
        case .script: colors = (0xD6C3EE, 0x593478, 0x332B3E, 0xD6B9F0)
        case .camera: colors = (0xF2BCD0, 0x80354F, 0x3C2C35, 0xEEACC7)
        case .recording: colors = (0xF3C39D, 0x7F4320, 0x3E3028, 0xF0BB8F)
        case .storage: colors = (0xD4E3B5, 0x3D5928, 0x2D352B, 0xC3DDA0)
        case .speech: colors = (0xF2E09F, 0x776014, 0x393427, 0xE7D185)
        }
        return StudioCardPalette(surface: Color(studioHex: scheme == .dark ? colors.2 : colors.0),
                                 heading: Color(studioHex: scheme == .dark ? colors.3 : colors.1))
    }
}

struct StudioCardPalette {
    let surface: Color
    let heading: Color
}

struct StudioTheme {
    let colorScheme: ColorScheme
    var canvas: Color { Color(studioHex: colorScheme == .dark ? 0x1D1C22 : 0xF7F5EE) }
    var editor: Color { Color(studioHex: colorScheme == .dark ? 0x232128 : 0xFCFAF5) }
    var text: Color { Color(studioHex: colorScheme == .dark ? 0xEEE9E3 : 0x292622) }
    var secondaryText: Color { Color(studioHex: colorScheme == .dark ? 0xBFB6AD : 0x5C5554) }
    var controlSurface: Color { colorScheme == .dark ? .white.opacity(0.07) : .white.opacity(0.45) }
    var recordButton: Color { Color(studioHex: colorScheme == .dark ? 0xE8B38C : 0x754327) }
    var recordLabel: Color { Color(studioHex: colorScheme == .dark ? 0x352418 : 0xFFF8EF) }
}

private extension Color {
    init(studioHex value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct StudioCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tone: StudioCardTone
    var status: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let palette = tone.palette(for: colorScheme)
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heading(palette)
                    Spacer(minLength: 0)
                    statusLabel
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading(palette)
                    statusLabel
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if reduceTransparency || (CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--reduced-transparency")) {
                shape.fill(palette.surface)
            } else {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(palette.surface.opacity(0.94)) }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.heading.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 1)
        }
        .tint(palette.heading)
        .accessibilityElement(children: .contain)
    }

    private func heading(_ palette: StudioCardPalette) -> some View {
        Label {
            Text(title).font(.custom("Georgia-Bold", size: 20, relativeTo: .title3))
        } icon: {
            Image(systemName: systemImage).font(.system(size: 21, weight: .regular))
        }
        .foregroundStyle(palette.heading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var statusLabel: some View {
        if let status {
            Text(status).font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Wrap the selected value rather than clipping long device or format names.
struct StudioSelectionMenu: View {
    struct Option: Identifiable {
        let id: String
        let name: String
    }

    let title: String
    @Binding var selection: String
    let options: [Option]
    @Environment(\.colorScheme) private var colorScheme

    private var selectedName: String { options.first { $0.id == selection }?.name ?? "Select \(title.lowercased())" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(StudioTheme(colorScheme: colorScheme).secondaryText).frame(width: 72, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // macOS renders a Menu label as a single-line native title, even with a wrapping Text.
                // Keep the selected value outside that title so long device names remain visible.
                Text(selectedName).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Picker(title, selection: $selection) {
                        ForEach(options) { option in Text(option.name).tag(option.id) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Choose " + title.lowercased()).accessibilityValue(selectedName)
                .help("Choose " + title.lowercased())
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
            .background(StudioTheme(colorScheme: colorScheme).controlSurface, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
