import SwiftUI

/// An opaque instrument display, with the same square frame as the classic UI.
struct LCDScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.retroPalette) private var palette

    var body: some View {
        content()
            .foregroundStyle(palette.phosphor)
            .padding(16)
            .background(palette.display)
            .overlay(Rectangle().strokeBorder(palette.ink, lineWidth: 1))
    }
}

private struct RetroPanelBackground: ViewModifier {
    @Environment(\.retroPalette) private var palette

    func body(content: Content) -> some View {
        content.background(palette.base)
            .overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))
    }
}

extension View {
    func retroPanel() -> some View { modifier(RetroPanelBackground()) }
}

/// 2x2 checkerboard cell so warning segments also work without color.
struct DitherCell: View {
    var color: Color = .primary
    var body: some View {
        Canvas { ctx, size in
            let w = size.width / 2, h = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(color))
            ctx.fill(Path(CGRect(x: w, y: h, width: w, height: h)), with: .color(color))
        }
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color
    var warning = false
    private let cells = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { i in
                let on = Double(i) < percent / 100 * Double(cells)
                if on && warning { DitherCell(color: color) }
                else { Rectangle().fill(on ? color : color.opacity(0.12)) }
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Usage")
        .accessibilityValue(String(format: "%.0f%%", percent))
    }
}

/// Each bar is one actual sample. No fabricated history is added on startup.
struct HistoryLine: View {
    let values: [Double]
    let color: Color
    var height: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack {
                    ForEach(0..<3) { _ in
                        Rectangle().fill(color.opacity(0.12)).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<40, id: \.self) { index in
                        let sample = index - (40 - values.count)
                        let value = sample >= 0 && sample < values.count ? values[sample] : nil
                        Rectangle().fill(color.opacity(value == nil ? 0 : 0.75))
                            .frame(height: max(1, min(100, max(0, value ?? 0)) / 100 * geometry.size.height))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct PixelBar: View {
    let fraction: Double
    var attention = false
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<12, id: \.self) { i in
                let on = Double(i) < fraction * 12 - 0.001
                if on && attention { DitherCell(color: color) }
                else { Rectangle().fill(color.opacity(on ? 1 : 0.1)) }
            }
        }
        .frame(width: 44, height: 8)
        .accessibilityHidden(true)
    }
}
