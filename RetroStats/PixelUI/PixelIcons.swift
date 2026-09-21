import SwiftUI

private let gridSize: CGFloat = 16

/// Filled cells on a 16x16 grid, scaled to the requested size.
private struct PixelCells: View {
    var cells: [(Int, Int)]
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / gridSize
            var path = Path()
            for (i, j) in cells {
                path.addRect(CGRect(x: CGFloat(i) * s, y: CGFloat(j) * s, width: s, height: s))
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - PixelLED

/// 6x6 rounded-square indicator dot replacing the 5pt fill circle.
struct PixelLED: View {
    var size: CGFloat = 16
    var color: Color = .primary
    var body: some View {
        PixelCells(
            cells: Self.cells,
            color: color,
            size: size
        )
    }
    static let cells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        for j in 5...10 { for i in 5...10 {
            if (i == 5 || i == 10) && (j == 5 || j == 10) { continue }
            c.append((i, j))
        }}
        return c
    }()
}

// MARK: - PixelMax

/// Three rising bars, fully lit: the menu bar's "100%" glyph.
struct PixelMax: View {
    var size: CGFloat = 16
    var color: Color = .primary
    var body: some View {
        PixelCells(cells: Self.cells, color: color, size: size)
    }
    static let cells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        for (bar, height) in [(1, 5), (6, 10), (11, 15)] {
            for i in bar..<(bar + 4) { for j in (15 - height)...15 { c.append((i, j)) } }
        }
        return c
    }()
}

// MARK: - PixelSliders

/// Three horizontal sliders with handles, replacing the gear as the settings glyph.
struct PixelSliders: View {
    var size: CGFloat = 16
    var color: Color = .primary
    var body: some View {
        PixelCells(
            cells: Self.cells,
            color: color,
            size: size
        )
    }
    static let cells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        // tracks
        for i in 3...12 {
            c.append((i, 4)); c.append((i, 8)); c.append((i, 12))
        }
        // handles: right, left, center
        for h in [(10, 3, 5), (5, 7, 9), (8, 11, 13)] {
            for i in h.0...(h.0 + 1) { for j in h.1...h.2 { c.append((i, j)) } }
        }
        return c
    }()
}

// MARK: - PixelRefresh

/// 3/4 arc with an arrowhead, replacing arrow.clockwise. When `animating`, a
/// short run of arc pixels travels clockwise around the ring while the
/// arrowhead stays fixed; otherwise the full icon is shown statically.
struct PixelRefresh: View {
    var size: CGFloat = 16
    var color: Color = .primary
    var animating: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animating && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                PixelCells(cells: Self.frame(for: context.date), color: color, size: size)
            }
        } else {
            PixelCells(cells: Self.cells, color: color, size: size)
        }
    }

    static func frame(for date: Date) -> [(Int, Int)] {
        let arc = Self.arcCells
        let count = arc.count
        let window = max(3, count / 3)
        let step = Int(date.timeIntervalSinceReferenceDate * 12) % count
        var active: [(Int, Int)] = []
        for i in 0..<window {
            active.append(arc[(step + i) % count])
        }
        return active + arrowCells
    }

    /// Arc cells sorted clockwise starting from the top opening (270°).
    static let arcCells: [(Int, Int)] = {
        let cx = 7.5, cy = 7.5, rIn = 4.5, rOut = 6.5
        let a0 = 270.0 * .pi / 180, a1 = 570.0 * .pi / 180
        var keyed: [(Double, Int, Int)] = []
        for j in 0..<Int(gridSize) {
            for i in 0..<Int(gridSize) {
                let dx = Double(i) - cx, dy = Double(j) - cy
                let r = (dx * dx + dy * dy).squareRoot()
                guard r >= rIn, r <= rOut else { continue }
                var ang = atan2(dy, dx); if ang < 0 { ang += 2 * .pi }
                let inArc = a1 <= 2 * .pi ? (ang >= a0 && ang <= a1)
                                          : (ang >= a0 || ang <= (a1 - 2 * .pi))
                guard inArc else { continue }
                let order = ang >= a0 ? (ang - a0) : (ang + 2 * .pi - a0)
                keyed.append((order, i, j))
            }
        }
        return keyed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }()

    static let arrowCells: [(Int, Int)] = [(8, 0), (8, 1), (8, 2), (9, 1), (10, 1)]

    /// All cells (arc + arrowhead) for static rendering.
    static let cells: [(Int, Int)] = arcCells + arrowCells
}

// MARK: - PixelHourglass

/// 1-bit hourglass spinner for the storage refresh state. Top bulb cells drain
/// frame-by-frame into the bottom bulb, then the cycle resets. Replaces the
/// system `ProgressView` spinner so the LCD pixel language stays consistent.
struct PixelHourglass: View {
    var size: CGFloat = 16
    var color: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            PixelCells(cells: Self.outlineCells, color: color, size: size)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 16.0)) { context in
                PixelCells(cells: frame(for: context.date), color: color, size: size)
            }
        }
    }

    private func frame(for date: Date) -> [(Int, Int)] {
        let total = Self.topCells.count
        let pause = 6
        let cycle = total + pause
        let step = Int(date.timeIntervalSinceReferenceDate * 8) % cycle
        let drain = min(step, total)
        var active: [(Int, Int)] = []
        // Upper bulb drains top-down: row 1 (wide, top) empties first.
        for (idx, cell) in Self.topCells.enumerated() where idx >= drain {
            active.append(cell)
        }
        // Lower bulb fills bottom-up: row 14 (wide, bottom) fills first,
        // matching the sand falling from the top in the same step.
        for (idx, cell) in Self.botCells.enumerated() where idx >= Self.botCells.count - drain {
            active.append(cell)
        }
        // Falling stream through the neck gap (rows 6-9 at column 8),
        // visible only while sand is actively draining. A 2-pixel segment
        // enters at the top, traverses downward, and exits at the bottom,
        // then repeats with no gap so the stream never flickers.
        if drain > 0 && drain < total {
            let gapRows = [6, 7, 8, 9]
            let n = gapRows.count
            let streamLen = 2
            let cycleLen = n + streamLen - 1
            let pos = Int(date.timeIntervalSinceReferenceDate * 16) % cycleLen
            for k in 0..<streamLen {
                let idx = pos - streamLen + 1 + k
                if idx >= 0 && idx < n {
                    active.append((8, gapRows[idx]))
                }
            }
        }
        return active
    }

    /// Upper bulb cells, narrowing toward the center (row 1 → 5).
    static let topCells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        for j in 1...5 {
            let w = 6 - j
            let start = 8 - w / 2
            for i in 0..<w { c.append((start + i, j)) }
        }
        return c
    }()

    /// Lower bulb cells, widening away from the center (row 10 → 14).
    static let botCells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        for j in 10...14 {
            let w = j - 9
            let start = 8 - w / 2
            for i in 0..<w { c.append((start + i, j)) }
        }
        return c
    }()

    static let outlineCells: [(Int, Int)] = topCells + botCells
}

#if DEBUG
#Preview("PixelLED") {
    VStack(spacing: 20) {
        PixelLED(size: 10, color: .primary)
        PixelLED(size: 16, color: .primary)
        PixelLED(size: 24, color: .accentColor)
    }
    .padding(40)
    .frame(width: 200, height: 220)
}

#Preview("PixelMax") {
    VStack(spacing: 20) {
        PixelMax(size: 9, color: .primary)
        PixelMax(size: 16, color: .primary)
        PixelMax(size: 32, color: .accentColor)
    }
    .padding(40)
    .frame(width: 200, height: 220)
}

#Preview("PixelSliders") {
    VStack(spacing: 20) {
        PixelSliders(size: 16, color: .primary)
        PixelSliders(size: 24, color: .primary)
        PixelSliders(size: 32, color: .accentColor)
    }
    .padding(40)
    .frame(width: 240, height: 240)
}

#Preview("PixelRefresh — Animated") {
    VStack(spacing: 28) {
        PixelRefresh(size: 16, color: .primary, animating: true)
        Divider().frame(width: 120)
        PixelRefresh(size: 24, color: .primary, animating: true)
        Divider().frame(width: 120)
        PixelRefresh(size: 32, color: .accentColor, animating: true)
    }
    .padding(40)
    .frame(width: 260, height: 280)
}

#Preview("PixelRefresh — Idle") {
    VStack(spacing: 28) {
        PixelRefresh(size: 16, color: .primary, animating: false)
        Divider().frame(width: 120)
        PixelRefresh(size: 24, color: .primary, animating: false)
        Divider().frame(width: 120)
        PixelRefresh(size: 32, color: .accentColor, animating: false)
    }
    .padding(40)
    .frame(width: 260, height: 280)
}

#Preview("PixelHourglass") {
    VStack(spacing: 20) {
        PixelHourglass(size: 14, color: .primary)
        PixelHourglass(size: 20, color: .primary)
        PixelHourglass(size: 32, color: .accentColor)
    }
    .padding(40)
    .frame(width: 240, height: 240)
}
#endif
