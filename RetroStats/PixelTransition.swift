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

    private let cellSize: CGFloat = 4
    private let waveBand: CGFloat = 55

    var body: some View {
        Canvas { ctx, size in
            let t = max(0, min(1, progress))
            let harmonics = Self.harmonics(seed: seed)
            let cols = Int(size.width / cellSize) + 1
            let rows = Int(size.height / cellSize) + 1

            for j in 0..<rows {
                let y = CGFloat(j) * cellSize
                let waveX = Self.waveFront(y: y, progress: t, width: size.width, harmonics: harmonics)

                for i in 0..<cols {
                    let x = CGFloat(i) * cellSize
                    let dist = x - waveX
                    let absDist = abs(dist)
                    guard absDist < waveBand else { continue }
                    let falloff = 1 - absDist / waveBand
                    let intensity = pow(falloff, 1.8)
                    let alpha = dist < 0 ? intensity * 0.25 : intensity * 0.55
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
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
        return center + CGFloat(offset)
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
        let step: CGFloat = 3
        if inverted {
            path.move(to: CGPoint(x: rect.width, y: 0))
            for y in stride(from: CGFloat(0), through: rect.height, by: step) {
                let x = PixelTransition.waveFront(y: y, progress: t, width: rect.width, harmonics: harmonics)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        } else {
            path.move(to: .zero)
            for y in stride(from: CGFloat(0), through: rect.height, by: step) {
                let x = PixelTransition.waveFront(y: y, progress: t, width: rect.width, harmonics: harmonics)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: 0, y: rect.height))
        }
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
    var seed: Int { get }
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

/// Fade transition: the new page fades in while the old page fades out. No
/// overlay band — just opacity crossfade via masks.
struct FadeTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    static func opacity(forNewPage progress: Double) -> Double {
        max(0, min(1, progress))
    }

    static func opacity(forOldPage progress: Double) -> Double {
        max(0, min(1, 1 - progress))
    }

    func newPageMask(progress: Double) -> AnyView {
        AnyView(Color.white.opacity(Self.opacity(forNewPage: progress)))
    }

    func oldPageMask(progress: Double) -> AnyView {
        AnyView(Color.white.opacity(Self.opacity(forOldPage: progress)))
    }

    func overlay(progress: Double, start: Date?) -> AnyView {
        AnyView(EmptyView())
    }
}

// MARK: - FlipMaskShape

/// Animatable clip shape for the pixel-flip transition. The screen is divided
/// into a grid of `cellSize` cells. Each cell flips on a diagonal wave: a cell
/// reaches its half-flip point when `progress` passes its diagonal delay, and
/// from that point it shows its back face (new page) instead of its front face
/// (old page). When `inverted` is false the shape fills back-face cells
/// (reveals the NEW page); when true it fills front-face cells (clips the OLD
/// page). `seed` is reserved for future per-transition variation; the diagonal
/// wave is stable so mask endpoints are deterministic.
struct FlipMaskShape: Shape {
    var seed: Int
    var animatableData: Double  // progress 0...1
    var inverted: Bool = false
    var cellSize: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(1, animatableData))
        let cols = max(1, Int((rect.width + cellSize - 1) / cellSize))
        let rows = max(1, Int((rect.height + cellSize - 1) / cellSize))
        var path = Path()
        for j in 0..<rows {
            for i in 0..<cols {
                let isBack = Self.isBackFace(progress: t, i: i, j: j, cols: cols, rows: rows)
                guard isBack != inverted else { continue }
                let x = CGFloat(i) * cellSize
                let y = CGFloat(j) * cellSize
                path.addRect(CGRect(x: x, y: y, width: cellSize, height: cellSize))
            }
        }
        return path
    }

    /// Per-cell flip progress (0 at rest, 1 at fully flipped) for cell (i, j).
    /// `band` spreads the wave so the half-flip point sweeps diagonally instead
    /// of all cells flipping at once. Exposed so the overlay can render flip
    /// edges from the same curve the masks use.
    static func cellProgress(_ progress: Double, i: Int, j: Int, cols: Int, rows: Int) -> Double {
        let t = max(0, min(1, progress))
        let denom = max(1, cols + rows - 1)
        let delay = Double(i + j) / Double(denom)
        let band: Double = 1.0
        return max(0, min(1, t * (1 + band) - delay * band))
    }

    /// Whether cell (i, j) shows its back face at a given progress: true once
    /// the cell has passed its half-flip point.
    static func isBackFace(progress: Double, i: Int, j: Int, cols: Int, rows: Int) -> Bool {
        cellProgress(progress, i: i, j: j, cols: cols, rows: rows) >= 0.5
    }

    /// Half-width of the seam band around the half-flip point (cellT==0.5).
    /// Cells whose cellT falls outside [0.5 - half, 0.5 + half] draw no seam, so
    /// the overlay traces only the narrow diagonal flip edge instead of every
    /// flipping cell (which at mid-progress is nearly the whole grid).
    static let seamBandHalf: Double = 0.05

    /// Seam brightness for a cell at `cellT` (0...1). Peaks at the half-flip
    /// (cellT==0.5), falls linearly to 0 at the band edge, and is 0 outside the
    /// band. The overlay skips any cell where this returns 0.
    static func seamAlpha(_ cellT: Double) -> Double {
        let d = abs(cellT - 0.5)
        guard d <= seamBandHalf else { return 0 }
        return (1 - d / seamBandHalf) * 0.45
    }
}

// MARK: - FlipTransition

/// Pixel-flip transition: the screen is tiled into a grid and each cell flips
/// on a diagonal wave, swapping from the old page (front face) to the new page
/// (back face). The overlay draws the flip edge — a thin vertical seam at each
/// cell's rotation axis, brightest at the half-flip — so the swap reads as a
/// 3D flip rather than a flat checkerboard.
struct FlipTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    private static let cellSize: CGFloat = 8

    func newPageMask(progress: Double) -> AnyView {
        AnyView(FlipMaskShape(seed: seed, animatableData: progress, cellSize: Self.cellSize))
    }

    func oldPageMask(progress: Double) -> AnyView {
        AnyView(FlipMaskShape(seed: seed, animatableData: progress, inverted: true, cellSize: Self.cellSize))
    }

    func overlay(progress: Double, start: Date?) -> AnyView {
        AnyView(TimelineView(.animation) { context in
            let p = start.map { min(1, max(0, context.date.timeIntervalSince($0) / duration)) }
                ?? max(0, min(1, progress))
            Canvas { ctx, size in
                let cs = Self.cellSize
                let cols = max(1, Int((size.width + cs - 1) / cs))
                let rows = max(1, Int((size.height + cs - 1) / cs))
                for j in 0..<rows {
                    for i in 0..<cols {
                        let cellT = FlipMaskShape.cellProgress(p, i: i, j: j, cols: cols, rows: rows)
                        let alpha = FlipMaskShape.seamAlpha(cellT)
                        guard alpha > 0 else { continue }
                        let cx = CGFloat(i) * cs + cs / 2
                        let y = CGFloat(j) * cs
                        let seam = CGRect(x: cx - 1, y: y, width: 2, height: cs)
                        ctx.fill(Path(seam), with: .color(color.opacity(alpha)))
                    }
                }
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
        case .fade: return "Fade"
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
