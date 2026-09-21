import AppKit
import SwiftUI

/// Translucent LCD panel: a dark substrate that lets the window glass bleed through, with a pixel grid, scanlines and glare framing hero numerals.
struct LCDScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(10)
            .background(
                ZStack {
                    Color.black.opacity(0.55)
                    LCDPixelGrid(opacity: 0.07)
                    LCDScanlines(opacity: 0.05)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

/// Translucent LCD sub-panel background for cards: a faint tint plus a pixel grid and a hairline border.
struct LCDPanelBackground: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                Color.primary.opacity(0.05)
                LCDPixelGrid(opacity: 0.03, pitch: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    /// Translucent LCD-style panel background for cards and surfaces.
    func lcdPanel(cornerRadius: CGFloat) -> some View {
        modifier(LCDPanelBackground(cornerRadius: cornerRadius))
    }
}

/// Fine pixel grid that mimics the subpixel matrix of an LCD panel.
struct LCDPixelGrid: View {
    var opacity: Double
    var pitch: CGFloat = 3
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.white.opacity(opacity)
            var x = pitch
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(ink))
                x += pitch
            }
            var y = pitch
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(ink))
                y += pitch
            }
        }
    }
}

/// Horizontal scanlines that mimic the row gaps of an LCD panel.
struct LCDScanlines: View {
    var opacity: Double
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.white.opacity(opacity)
            var y = 0.0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(ink))
                y += 3
            }
        }
    }
}

/// 2x2 checkerboard cell so a "filled" warning segment stays black-and-white.
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

/// Segmented 1-bit usage meter; filled cells use the ink color, and warning cells use a dither pattern instead of an accent color.
struct UsageBar: View {
    let percent: Double
    let color: Color
    var warning = false
    private let cells = 24
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<cells, id: \.self) { i in
                let on = Double(i) < percent / 100 * Double(cells)
                if on && warning { DitherCell() }
                else { RoundedRectangle(cornerRadius: 1, style: .continuous).fill(on ? color : color.opacity(0.08)) }
            }
        }.frame(height: 10).accessibilityLabel("Usage").accessibilityValue(String(format: "%.0f%%", percent))
    }
}

/// Column histogram rendered as 1-bit pixel bars; replaces the stroked line.
struct HistoryLine: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let h = max(2, min(100, value) / 100 * geometry.size.height)
                    Rectangle().fill(color).frame(height: h)
                }
            }
        }.frame(height: 34).accessibilityHidden(true)
    }
}

final class SolidDashboardSurface: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: 20,
            yRadius: 20
        ).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Seven-segment digits on a cell grid, with unlit segments left as a faint LCD ghost.
/// `nil` shows a dash. Digits are 7 cells wide and 13 tall, strokes 2 cells thick.
struct SegmentDigits: View {
    let value: Int?
    var cell: CGFloat = 3
    var color: Color = .white

    private static let lit: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
        "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g",
    ]
    private static let rects: [(Character, CGRect)] = [
        ("a", CGRect(x: 1, y: 0, width: 5, height: 2)), ("b", CGRect(x: 5, y: 1, width: 2, height: 5)),
        ("c", CGRect(x: 5, y: 7, width: 2, height: 5)), ("d", CGRect(x: 1, y: 11, width: 5, height: 2)),
        ("e", CGRect(x: 0, y: 7, width: 2, height: 5)), ("f", CGRect(x: 0, y: 1, width: 2, height: 5)),
        ("g", CGRect(x: 1, y: 6, width: 5, height: 1)),
    ]

    private var text: String { value.map { String(min(max($0, 0), 999)) } ?? "-" }

    var body: some View {
        Canvas { ctx, _ in
            for (index, character) in text.enumerated() {
                let on = Self.lit[character] ?? ""
                let x = CGFloat(index) * 8 * cell
                for (segment, rect) in Self.rects {
                    let r = CGRect(x: x + rect.minX * cell, y: rect.minY * cell, width: rect.width * cell, height: rect.height * cell)
                    ctx.fill(Path(r), with: .color(color.opacity(on.contains(segment) ? 1 : 0.08)))
                }
            }
        }
        .frame(width: (CGFloat(text.count) * 8 - 1) * cell, height: 13 * cell)
        .accessibilityLabel(value.map { "\($0) percent" } ?? "Measuring")
    }
}

/// Twelve-cell bar. `fraction` 0…1 lights cells from the left; `attention` fills them with 50% dither.
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
