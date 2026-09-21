import SwiftUI

/// Deterministic unit value in [0, 1) for a seed and index; shared by the wave
/// harmonics and the flip tile timing so one transition is stable across frames.
func seededUnit(seed: Int, _ a: Int, _ b: Int = 0) -> Double {
    var bits = UInt64(truncatingIfNeeded: seed)
    bits &+= UInt64(truncatingIfNeeded: a) &* 0x9E3779B97F4A7C15
    bits &+= UInt64(truncatingIfNeeded: b) &* 0xD1B54A32D192ED03
    bits ^= bits >> 30
    bits &*= 0xBF58476D1CE4E5B9
    bits ^= bits >> 27
    bits &*= 0x94D049BB133111EB
    bits ^= bits >> 31
    return Double(bits >> 11) / Double(1 << 53)
}

/// LCD pixel wave transition. A randomized multi-harmonic wave sweeps left to
/// right. The wave front is a wipe boundary: pixels to its left reveal the new
/// page, pixels to its right keep the old page, and a shimmering pixel band
/// straddles the boundary.
struct PixelTransition: View {
    var progress: Double  // 0 → 1
    var color: Color = .primary
    var seed: Int = 0

    static let cellSize: CGFloat = 4
    private let waveBand: CGFloat = 55

    var body: some View {
        Canvas { ctx, size in
            let t = max(0, min(1, progress))
            let harmonics = Self.harmonics(seed: seed)
            let cols = Int(size.width / Self.cellSize) + 1
            let rows = Int(size.height / Self.cellSize) + 1

            for j in 0..<rows {
                let y = CGFloat(j) * Self.cellSize
                let waveX = Self.waveFront(y: y, progress: t, width: size.width, harmonics: harmonics)

                for i in 0..<cols {
                    let x = CGFloat(i) * Self.cellSize
                    let dist = x - waveX
                    let absDist = abs(dist)
                    guard absDist < waveBand else { continue }
                    let falloff = 1 - absDist / waveBand
                    let intensity = pow(falloff, 1.8)
                    let alpha = dist < 0 ? intensity * 0.25 : intensity * 0.55
                    let rect = CGRect(x: x, y: y, width: Self.cellSize, height: Self.cellSize)
                    ctx.fill(Path(rect), with: .color(color.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Randomized harmonic sum (amplitude × frequency × phase) for one
    /// transition. Stable for a given seed, varied across seeds.
    static func harmonics(seed: Int) -> [(amp: Double, freq: Double, phase: Double)] {
        (0..<5).map { i in
            (8 + 26 * seededUnit(seed: seed, i, 1),
             0.015 + 0.055 * seededUnit(seed: seed, i, 2),
             2 * .pi * seededUnit(seed: seed, i, 3))
        }
    }

    /// Wave-front x at a given y for a given progress, width, and harmonics.
    static func waveFront(y: CGFloat, progress: Double, width: CGFloat,
                          harmonics: [(amp: Double, freq: Double, phase: Double)]) -> CGFloat {
        let band: CGFloat = 55
        let t = max(0, min(1, progress))
        let center = -band + t * (width + band * 2)
        var offset: Double = 0
        for (amp, freq, phase) in harmonics { offset += amp * sin(Double(y) * freq + phase + t * .pi) }
        // The front must be completely outside the screen at both endpoints.
        return center + CGFloat(offset * sin(t * .pi))
    }
}

/// Animatable clip shape for the wave wipe transition. When `inverted` is
/// false, fills the region to the LEFT of the wave front (already-swept) —
/// used to reveal the NEW page. When `inverted` is true, fills the region to
/// the RIGHT (not-yet-swept) — used to clip the OLD page so it disappears as
/// the wave passes. `animatableData` is driven by `withAnimation`.
struct PixelWaveMaskShape: Shape {
    var seed: Int
    var animatableData: Double  // progress 0...1
    var inverted: Bool = false

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(1, animatableData))
        let harmonics = PixelTransition.harmonics(seed: seed)
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let step = PixelTransition.cellSize
        if inverted {
            path.move(to: CGPoint(x: rect.width, y: 0))
        } else {
            path.move(to: .zero)
        }
        var y: CGFloat = 0
        while y < rect.height {
            let nextY = min(y + step, rect.height)
            let front = PixelTransition.waveFront(y: y, progress: t, width: rect.width, harmonics: harmonics)
            let x = floor(front / step) * step
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: nextY))
            y = nextY
        }
        path.addLine(to: CGPoint(x: inverted ? rect.width : 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - PageTransition protocol

/// A page transition provides masks and an overlay that `TransitionContainer`
/// applies to the old and new page panels during a transition. Each conforming
/// type encodes one visual style (wave, fade, flip, etc.). Masks and overlay are
/// returned as `AnyView` so the active style can be chosen at runtime from
/// user settings without a separate generic `TransitionContainer` per style.
protocol PageTransition {
    var seed: Int { get set }
    var color: Color { get }
    var duration: Double { get }

    func newPageMask(progress: Double) -> AnyView
    func oldPageMask(progress: Double) -> AnyView
    func overlay(progress: Double, start: Date?) -> AnyView
}

// MARK: - WaveTransition

/// Wave wipe transition: a randomized multi-harmonic wave sweeps left to right.
/// The new page is revealed to the left of the front, the old page is clipped
/// to the right, and a shimmering pixel band straddles the boundary.
struct WaveTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    func newPageMask(progress: Double) -> AnyView {
        AnyView(PixelWaveMaskShape(seed: seed, animatableData: progress))
    }

    func oldPageMask(progress: Double) -> AnyView {
        AnyView(PixelWaveMaskShape(seed: seed, animatableData: progress, inverted: true))
    }

    func overlay(progress: Double, start: Date?) -> AnyView {
        AnyView(TimelineView(.animation) { context in
            if let start {
                let elapsed = context.date.timeIntervalSince(start)
                let p = min(1, elapsed / duration)
                PixelTransition(progress: p, color: color, seed: seed)
                    .opacity(p < 1 ? 1 : 0)
            } else {
                EmptyView()
            }
        })
    }
}

// MARK: - FadeTransition

/// An 8-point Bayer dither replaces the old page one pixel block at a time.
/// The two masks are complementary at every progress value.
struct PixelFadeMask: Shape {
    var animatableData: Double
    var inverted = false

    static let cellSize: CGFloat = 8
    private static let order = [
         0,  8,  2, 10,
        12,  4, 14,  6,
         3, 11,  1,  9,
        15,  7, 13,  5
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let threshold = max(0, min(1, animatableData)) * 16
        let cols = Int(ceil(rect.width / Self.cellSize))
        let rows = Int(ceil(rect.height / Self.cellSize))
        for row in 0..<rows {
            for col in 0..<cols {
                let revealed = Double(Self.order[(row % 4) * 4 + col % 4]) < threshold
                guard revealed != inverted else { continue }
                path.addRect(CGRect(x: CGFloat(col) * Self.cellSize,
                                    y: CGFloat(row) * Self.cellSize,
                                    width: Self.cellSize, height: Self.cellSize))
            }
        }
        return path
    }
}

struct FadeTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    func newPageMask(progress: Double) -> AnyView {
        AnyView(PixelFadeMask(animatableData: progress))
    }

    func oldPageMask(progress: Double) -> AnyView {
        AnyView(PixelFadeMask(animatableData: progress, inverted: true))
    }

    func overlay(progress: Double, start: Date?) -> AnyView {
        AnyView(EmptyView())
    }
}

// MARK: - FlipTransition

/// Complementary old/new masks for the square faces of each flip tile. Only
/// geometry is evaluated here; the page views never enter a Canvas symbol.
struct FlipPixelMaskShape: Shape {
    var seed: Int
    var animatableData: Double
    var inverted = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let grid = FlipTransition.grid(in: rect.size) else { return path }
        let face = grid.faceSize
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let x = rect.minX + grid.origin.x + CGFloat(column) * face
                let y = rect.minY + grid.origin.y + CGFloat(row) * face * 2
                let hinge = y + face
                let local = FlipTransition.cellProgress(animatableData, row: row, column: column, seed: seed)
                let scale = CGFloat(FlipTransition.flapScale(progress: local))
                if inverted {
                    if local < 0.5 {
                        path.addRect(CGRect(x: x, y: hinge, width: face, height: face))
                        if scale > 0 {
                            path.addRect(CGRect(x: x, y: hinge - face * scale,
                                                width: face, height: face * scale))
                        }
                    } else if scale < 1 {
                        path.addRect(CGRect(x: x, y: hinge + face * scale,
                                            width: face, height: face * (1 - scale)))
                    }
                } else if local < 0.5 {
                    if scale < 1 {
                        path.addRect(CGRect(x: x, y: y, width: face, height: face * (1 - scale)))
                    }
                } else {
                    path.addRect(CGRect(x: x, y: y, width: face, height: face))
                    if scale > 0 {
                        path.addRect(CGRect(x: x, y: hinge, width: face, height: face * scale))
                    }
                }
            }
        }
        return path
    }
}

/// The narrow remainder at an arbitrary view size crossfades independently of
/// the complete flip tiles, so no partial face is clipped at an edge.
struct FlipMarginMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let grid = FlipTransition.grid(in: rect.size) else { return path }
        let frame = CGRect(x: rect.minX + grid.origin.x, y: rect.minY + grid.origin.y,
                           width: CGFloat(grid.columns) * grid.faceSize,
                           height: CGFloat(grid.rows) * grid.faceSize * 2)
        if frame.minX > rect.minX {
            path.addRect(CGRect(x: rect.minX, y: rect.minY,
                                width: frame.minX - rect.minX, height: rect.height))
        }
        if frame.maxX < rect.maxX {
            path.addRect(CGRect(x: frame.maxX, y: rect.minY,
                                width: rect.maxX - frame.maxX, height: rect.height))
        }
        if frame.minY > rect.minY {
            path.addRect(CGRect(x: frame.minX, y: rect.minY,
                                width: frame.width, height: frame.minY - rect.minY))
        }
        if frame.maxY < rect.maxY {
            path.addRect(CGRect(x: frame.minX, y: frame.maxY,
                                width: frame.width, height: rect.maxY - frame.maxY))
        }
        return path
    }
}

/// Each flip tile contains two square faces. Its old upper face folds down
/// around the horizontal midpoint, then the new lower face unfolds. The new
/// upper and old lower faces remain underneath the flap. Each tile starts at a
/// different seeded time and runs for the same local duration.
struct FlipTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    static let preferredFaceSize: CGFloat = 12.5
    private static let cellDuration = 0.45
    private static let latestStart = 1 - cellDuration

    struct Grid {
        let columns: Int
        let rows: Int
        let faceSize: CGFloat
        let origin: CGPoint
    }

    /// Fit complete tiles of two square faces inside any view. Calculate using
    /// half the height because every tile is one face wide and two faces tall.
    static func grid(in size: CGSize) -> Grid? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let halfHeight = size.height / 2
        let shortSide = min(size.width, halfHeight)
        let shortCount = max(1, Int((shortSide / preferredFaceSize).rounded()))
        let face = shortSide / CGFloat(shortCount)
        let columns = size.width <= halfHeight ? shortCount : max(1, Int(floor(size.width / face)))
        let rows = halfHeight <= size.width ? shortCount : max(1, Int(floor(halfHeight / face)))
        return Grid(columns: columns, rows: rows, faceSize: face,
                    origin: CGPoint(x: (size.width - CGFloat(columns) * face) / 2,
                                    y: (size.height - CGFloat(rows) * face * 2) / 2))
    }

    /// Stable across frames of one transition; a new transition seed gives a
    /// different order without storing mutable random state in the renderer.
    static func startDelay(row: Int, column: Int, seed: Int) -> Double {
        seededUnit(seed: seed, row, column) * latestStart
    }

    static func cellProgress(_ progress: Double, row: Int, column: Int, seed: Int) -> Double {
        let delay = startDelay(row: row, column: column, seed: seed)
        return max(0, min(1, (progress - delay) / cellDuration))
    }

    static func flapScale(progress: Double) -> Double {
        let p = max(0, min(1, progress))
        return abs(cos(p * .pi))
    }

    func newPageMask(progress: Double) -> AnyView {
        let p = max(0, min(1, progress))
        return AnyView(ZStack {
            FlipPixelMaskShape(seed: seed, animatableData: p)
                .fill(style: FillStyle(antialiased: false))
            FlipMarginMaskShape()
                .fill(style: FillStyle(antialiased: false))
                .opacity(p)
        })
    }

    func oldPageMask(progress: Double) -> AnyView {
        let p = max(0, min(1, progress))
        return AnyView(ZStack {
            FlipPixelMaskShape(seed: seed, animatableData: p, inverted: true)
                .fill(style: FillStyle(antialiased: false))
            FlipMarginMaskShape()
                .fill(style: FillStyle(antialiased: false))
                .opacity(1 - p)
        })
    }

    func overlay(progress: Double, start: Date?) -> AnyView {
        let duration = self.duration
        let gridColor = color
        return AnyView(TimelineView(.animation) { context in
            let p = start.map { min(1, max(0, context.date.timeIntervalSince($0) / duration)) }
                ?? max(0, min(1, progress))
            Canvas { ctx, size in
                guard p > 0, p < 1, let grid = Self.grid(in: size) else { return }
                let face = grid.faceSize
                let gridFrame = CGRect(x: grid.origin.x, y: grid.origin.y,
                                       width: CGFloat(grid.columns) * face,
                                       height: CGFloat(grid.rows) * face * 2)
                var lines = Path()
                for column in 0...grid.columns {
                    let x = grid.origin.x + CGFloat(column) * face
                    lines.move(to: CGPoint(x: x, y: gridFrame.minY))
                    lines.addLine(to: CGPoint(x: x, y: gridFrame.maxY))
                }
                for faceRow in 0...(grid.rows * 2) {
                    let y = grid.origin.y + CGFloat(faceRow) * face
                    lines.move(to: CGPoint(x: gridFrame.minX, y: y))
                    lines.addLine(to: CGPoint(x: gridFrame.maxX, y: y))
                }
                ctx.stroke(lines, with: .color(gridColor.opacity(0.14 * sin(p * .pi))), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        })
    }
}

// MARK: - TransitionStyle

/// User-selectable page transition styles. Persisted by raw value in
/// UserDefaults and resolved to a concrete `PageTransition` via
/// `makeTransition`.
enum TransitionStyle: String, CaseIterable {
    case wave, fade, flip

    /// Display label for the settings picker.
    var label: String {
        switch self {
        case .wave: return "Wave"
        case .fade: return "Dissolve"
        case .flip: return "Flip"
        }
    }

    /// `TransitionContainer` assigns a fresh seed when a transition starts.
    func makeTransition(color: Color, duration: Double) -> any PageTransition {
        switch self {
        case .wave: return WaveTransition(seed: 0, color: color, duration: duration)
        case .fade: return FadeTransition(seed: 0, color: color, duration: duration)
        case .flip: return FlipTransition(seed: 0, color: color, duration: duration)
        }
    }
}

// MARK: - TransitionSpeed

/// User-selectable transition animation speed. Persisted by raw value in
/// UserDefaults and mapped to a duration in seconds that drives both
/// `TransitionContainer`'s `withAnimation`/cleanup timer and each transition's
/// time-based overlay, so the mask animation and overlay stay in sync.
enum TransitionSpeed: String, CaseIterable {
    case slow, normal, fast

    /// Animation duration in seconds. Slower speed = longer duration.
    var duration: Double {
        switch self {
        case .slow: return 1.0
        case .normal: return 0.5
        case .fast: return 0.25
        }
    }

    /// Display label for the settings picker.
    var label: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }
}
