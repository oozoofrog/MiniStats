import SwiftUI

/// Seeded RNG so each transition produces a distinct but deterministic wave
/// shape (stable across the frames of one transition, different per transition).
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
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
        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(seed)))
        var hs: [(Double, Double, Double)] = []
        for _ in 0..<5 {
            hs.append((
                Double.random(in: 8...34, using: &rng),
                Double.random(in: 0.015...0.07, using: &rng),
                Double.random(in: 0..<(2 * .pi), using: &rng)
            ))
        }
        return hs
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
///
/// A style may instead opt into rotational rendering via `isRotational`: the
/// container then calls `rotationBody(old:new:progress:start:)` with the actual
/// page views so the transition can fold real content (e.g. a pixel flip clock)
/// rather than mask it. The `start` timestamp lets a rotational style drive
/// per-frame progress from a `TimelineView`, since a plain `progress` value is
/// captured once and won't animate on its own. Mask-based styles leave
/// `isRotational` at its default `false`.
protocol PageTransition {
    var seed: Int { get set }
    var color: Color { get }
    var duration: Double { get }
    var isRotational: Bool { get }

    func newPageMask(progress: Double) -> AnyView
    func oldPageMask(progress: Double) -> AnyView
    func overlay(progress: Double, start: Date?) -> AnyView
    func rotationBody(old: AnyView, new: AnyView, progress: Double, start: Date?) -> AnyView
}

extension PageTransition {
    /// Mask-based styles return `false` here. A folding style overrides to
    /// `true` so `TransitionContainer` uses `rotationBody` instead of masks.
    var isRotational: Bool { false }

    /// Default no-op; only rotational styles implement this.
    func rotationBody(old: AnyView, new: AnyView, progress: Double, start: Date?) -> AnyView {
        AnyView(EmptyView())
    }
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

/// Each flip tile contains two square faces. Its old upper face folds down
/// around the horizontal midpoint, then the new lower face unfolds. The new
/// upper and old lower faces remain underneath the flap. Each tile starts at a
/// different seeded time and runs for the same local duration.
struct FlipTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    var isRotational: Bool { true }

    static let preferredFaceSize: CGFloat = 25
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
        var bits = UInt64(truncatingIfNeeded: seed)
        bits &+= UInt64(row) &* 0x9E3779B97F4A7C15
        bits &+= UInt64(column) &* 0xD1B54A32D192ED03
        bits ^= bits >> 30
        bits &*= 0xBF58476D1CE4E5B9
        bits ^= bits >> 27
        bits &*= 0x94D049BB133111EB
        bits ^= bits >> 31
        let unit = Double(bits >> 11) / Double(1 << 53)
        return unit * latestStart
    }

    static func cellProgress(_ progress: Double, row: Int, column: Int, seed: Int) -> Double {
        let delay = startDelay(row: row, column: column, seed: seed)
        return max(0, min(1, (progress - delay) / cellDuration))
    }

    static func flapScale(progress: Double) -> Double {
        let p = max(0, min(1, progress))
        return abs(cos(p * .pi))
    }

    static func showsOldFlap(progress: Double) -> Bool {
        progress < 0.5
    }

    /// Mask members are unused because `isRotational` is `true`; `TransitionContainer`
    /// calls `rotationBody` instead. Kept as no-ops to satisfy the protocol.
    func newPageMask(progress: Double) -> AnyView { AnyView(EmptyView()) }
    func oldPageMask(progress: Double) -> AnyView { AnyView(EmptyView()) }
    func overlay(progress: Double, start: Date?) -> AnyView { AnyView(EmptyView()) }

    func rotationBody(old: AnyView, new: AnyView, progress: Double, start: Date?) -> AnyView {
        let duration = self.duration
        let flipSeed = seed
        let gridColor = color
        return AnyView(
            TimelineView(.animation) { context in
                let p = start.map { min(1, max(0, context.date.timeIntervalSince($0) / duration)) }
                    ?? max(0, min(1, progress))
                GeometryReader { geometry in
                    Canvas { ctx, size in
                        guard let oldPage = ctx.resolveSymbol(id: 0),
                              let newPage = ctx.resolveSymbol(id: 1),
                              let grid = Self.grid(in: size) else { return }
                        let face = grid.faceSize
                        let tileHeight = face * 2
                        // Fill only the margins; drawing behind transparent cell
                        // content would make either page appear twice.
                        let gridFrame = CGRect(x: grid.origin.x, y: grid.origin.y,
                                               width: CGFloat(grid.columns) * face,
                                               height: CGFloat(grid.rows) * tileHeight)
                        var margins = Path(CGRect(origin: .zero, size: size))
                        margins.addRect(gridFrame)
                        var oldBackground = ctx
                        oldBackground.clip(to: margins, style: FillStyle(eoFill: true, antialiased: false))
                        oldBackground.opacity = 1 - p
                        oldBackground.draw(oldPage, at: .zero, anchor: .topLeading)
                        var newBackground = ctx
                        newBackground.clip(to: margins, style: FillStyle(eoFill: true, antialiased: false))
                        newBackground.opacity = p
                        newBackground.draw(newPage, at: .zero, anchor: .topLeading)
                        var upper = Path()
                        var lower = Path()
                        for row in 0..<grid.rows {
                            for col in 0..<grid.columns {
                                let x = grid.origin.x + CGFloat(col) * face
                                let y = grid.origin.y + CGFloat(row) * tileHeight
                                upper.addRect(CGRect(x: x, y: y, width: face, height: face))
                                lower.addRect(CGRect(x: x, y: y + face, width: face, height: face))
                            }
                        }
                        var backgroundTop = ctx
                        backgroundTop.clip(to: upper, style: FillStyle(antialiased: false))
                        backgroundTop.draw(newPage, at: .zero, anchor: .topLeading)
                        var backgroundBottom = ctx
                        backgroundBottom.clip(to: lower, style: FillStyle(antialiased: false))
                        backgroundBottom.draw(oldPage, at: .zero, anchor: .topLeading)

                        for row in 0..<grid.rows {
                            for col in 0..<grid.columns {
                                let cellProgress = Self.cellProgress(p, row: row, column: col, seed: flipSeed)
                                let scale = CGFloat(Self.flapScale(progress: cellProgress))
                                guard scale > 0.001 else { continue }
                                let oldFace = Self.showsOldFlap(progress: cellProgress)
                                let x = grid.origin.x + CGFloat(col) * face
                                let y = grid.origin.y + CGFloat(row) * tileHeight
                                let hinge = y + face
                                let target = CGRect(x: x,
                                                    y: oldFace ? hinge - face * scale : hinge,
                                                    width: face, height: face * scale)
                                var flap = ctx
                                flap.clip(to: Path(target), style: FillStyle(antialiased: false))
                                flap.translateBy(x: 0, y: hinge * (1 - scale))
                                flap.scaleBy(x: 1, y: scale)
                                flap.draw(oldFace ? oldPage : newPage, at: .zero, anchor: .topLeading)
                            }
                        }
                        if p > 0 && p < 1 {
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
                    } symbols: {
                        old.frame(width: geometry.size.width, height: geometry.size.height).tag(0)
                        new.frame(width: geometry.size.width, height: geometry.size.height).tag(1)
                    }
                }
            }
        )
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

    /// Builds the concrete transition for this style. `DashboardView` calls
    /// this from the persisted style and speed so the active transition carries
    /// the chosen duration (shared by `TransitionContainer` and the overlay).
    func makeTransition(seed: Int, color: Color, duration: Double) -> any PageTransition {
        switch self {
        case .wave: return WaveTransition(seed: seed, color: color, duration: duration)
        case .fade: return FadeTransition(seed: seed, color: color, duration: duration)
        case .flip: return FlipTransition(seed: seed, color: color, duration: duration)
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
