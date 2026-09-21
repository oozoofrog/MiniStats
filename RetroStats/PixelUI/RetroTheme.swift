import AppKit
import SwiftUI

enum RetroFinish: String, CaseIterable {
    case ivory, platinum, phosphor

    var label: String {
        switch self {
        case .ivory: return "Ivory"
        case .platinum: return "Platinum"
        case .phosphor: return "Phosphor"
        }
    }
}

enum RetroLayout {
    static let dashboardSize = CGSize(width: 840, height: 760)
    static let compactSize = CGSize(width: 400, height: 660)
    static let dashboardMinimum = CGSize(width: 360, height: 500)
    static let sidebarBreakpoint: CGFloat = 680
}

/// Opaque, appearance-aware surfaces shared by the window and the menu panel.
/// Text still goes through RetroBitmapA and BitmapTextRenderer.
struct RetroPalette {
    let paper: Color
    let base: Color
    let ink: Color
    let muted: Color
    let line: Color
    let soft: Color
    let display: Color
    let phosphor: Color

    init(finish: RetroFinish = .ivory, scheme: ColorScheme = .light) {
        let colors: [UInt32]
        switch (finish, scheme == .dark) {
        case (.ivory, false): colors = [0xF5F0E3, 0xE5DFCF, 0x292B24, 0x626254, 0x858474, 0xDBD5C5, 0xE6E4D2, 0x414633]
        case (.ivory, true): colors = [0x292923, 0x20211D, 0xE9E4D6, 0xB9B6A7, 0x858779, 0x424439, 0x20251D, 0xD4D8B1]
        case (.platinum, false): colors = [0xF5F5F2, 0xDEDEDB, 0x252525, 0x62625F, 0x81817D, 0xD5D5CF, 0xE9E9E3, 0x30332F]
        case (.platinum, true): colors = [0x282828, 0x202020, 0xECECE9, 0xB4B4AE, 0x81817D, 0x40403D, 0x1E211E, 0xD7DDD2]
        case (.phosphor, false): colors = [0xE5EADF, 0xD1DACB, 0x263E2C, 0x51624E, 0x73816A, 0xC6D3BD, 0xDCE5D2, 0x2E512D]
        case (.phosphor, true): colors = [0x18221C, 0x121A15, 0xC3D7B0, 0x97AF86, 0x56684D, 0x2A3929, 0x111B14, 0xBCDB91]
        }
        func color(_ index: Int) -> Color {
            let hex = colors[index]
            return Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                         green: Double((hex >> 8) & 255) / 255,
                         blue: Double(hex & 255) / 255, opacity: 1)
        }
        paper = color(0); base = color(1); ink = color(2); muted = color(3)
        line = color(4); soft = color(5); display = color(6); phosphor = color(7)
    }
}

private struct RetroPaletteKey: EnvironmentKey {
    static let defaultValue = RetroPalette()
}

private struct RetroCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var retroCompact: Bool {
        get { self[RetroCompactKey.self] }
        set { self[RetroCompactKey.self] = newValue }
    }
    var retroPalette: RetroPalette {
        get { self[RetroPaletteKey.self] }
        set { self[RetroPaletteKey.self] = newValue }
    }
}

struct RetroRule: View {
    @Environment(\.retroPalette) private var palette
    var body: some View { Rectangle().fill(palette.line).frame(height: 1).accessibilityHidden(true) }
}

struct RetroTitleBar: View {
    var title = "RetroStats"
    var reservesWindowControls = false
    @Environment(\.retroPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            if reservesWindowControls { Color.clear.frame(width: 62) }
            stripes
            Text(title).font(.bitmap(13, scaled: false)).fixedSize()
            stripes
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(palette.paper)
        .overlay(alignment: .bottom) { RetroRule() }
    }

    private var stripes: some View {
        VStack(spacing: 2) {
            ForEach(0..<5) { _ in Rectangle().fill(palette.ink.opacity(0.6)).frame(height: 1) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct RetroPageHeading: View {
    let title: String
    @Environment(\.retroCompact) private var compact

    var body: some View {
        Text(title)
            .font(.bitmap(compact ? 20 : 26))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
    }
}

struct RetroSectionHeading: View {
    let title: String
    var detail = ""
    @Environment(\.retroPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail) }
        }
        .font(.bitmap(11))
        .foregroundStyle(palette.muted)
    }
}

/// One hundred square cells preserve the pixel geometry at any panel width.
struct RetroDiskMap: View {
    let percent: Double
    @Environment(\.retroPalette) private var palette

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 20), spacing: 3) {
            ForEach(0..<100) { index in
                Rectangle().fill(Double(index) < percent ? palette.phosphor : palette.soft)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage used")
        .accessibilityValue(String(format: "%.1f percent", percent))
    }
}
