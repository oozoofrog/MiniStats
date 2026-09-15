import SwiftUI

/// Common 16x16 pixel grid helpers for bitmap icons.

private struct PixelGrid {
    static let n: CGFloat = 16
}

/// Filled cells on a 16x16 grid, scaled to the requested size.
private struct PixelCells: View {
    var cells: [(Int, Int)]
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / PixelGrid.n
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

/// 3/4 arc with an arrowhead, replacing arrow.clockwise. Rotates clockwise.
struct PixelRefresh: View {
    var size: CGFloat = 16
    var color: Color = .primary
    @State private var rotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PixelCells(
            cells: Self.cells,
            color: color,
            size: size
        )
        .rotationEffect(.degrees(rotation))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    /// Arc cells (open at top) plus a right-side arrowhead.
    static let cells: [(Int, Int)] = {
        var c: [(Int, Int)] = []
        let cx = 7.5, cy = 7.5, rIn = 4.5, rOut = 6.5
        let a0 = 270.0 * .pi / 180, a1 = 570.0 * .pi / 180
        for j in 0..<Int(PixelGrid.n) {
            for i in 0..<Int(PixelGrid.n) {
                let dx = Double(i) - cx, dy = Double(j) - cy
                let r = (dx * dx + dy * dy).squareRoot()
                guard r >= rIn, r <= rOut else { continue }
                var ang = atan2(dy, dx); if ang < 0 { ang += 2 * .pi }
                let inArc = a1 <= 2 * .pi ? (ang >= a0 && ang <= a1)
                                          : (ang >= a0 || ang <= (a1 - 2 * .pi))
                if inArc { c.append((i, j)) }
            }
        }
        for p in [(8, 0), (8, 1), (8, 2), (9, 1), (10, 1)] { c.append(p) }
        return c
    }()
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
            TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { context in
                PixelCells(cells: frame(for: context.date), color: color, size: size)
            }
        }
    }

    private func frame(for date: Date) -> [(Int, Int)] {
        let cycle = Self.topCells.count + Self.botCells.count + 4
        let step = Int(date.timeIntervalSinceReferenceDate * 8) % cycle
        let drain = min(step, Self.topCells.count)
        let fill = max(0, min(step - Self.topCells.count, Self.botCells.count))
        var active: [(Int, Int)] = []
        for (idx, cell) in Self.topCells.enumerated() where idx < Self.topCells.count - drain {
            active.append(cell)
        }
        for (idx, cell) in Self.botCells.enumerated() where idx < fill {
            active.append(cell)
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
