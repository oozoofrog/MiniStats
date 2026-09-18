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
///
/// A style may instead opt into rotational rendering via `isRotational`: the
/// container then calls `rotationBody(old:new:progress:start:)` with the actual
/// page views so the transition can rotate real content (e.g. a 3D card flip)
/// rather than mask it. The `start` timestamp lets a rotational style drive
/// per-frame progress from a `TimelineView`, since a plain `progress` value is
/// captured once and won't animate on its own. Mask-based styles leave
/// `isRotational` at its default `false`.
protocol PageTransition {
    var seed: Int { get }
    var color: Color { get }
    var duration: Double { get }
    var isRotational: Bool { get }

    func newPageMask(progress: Double) -> AnyView
    func oldPageMask(progress: Double) -> AnyView
    func overlay(progress: Double, start: Date?) -> AnyView
    func rotationBody(old: AnyView, new: AnyView, progress: Double, start: Date?) -> AnyView
}

extension PageTransition {
    /// Mask-based styles return `false` here. A rotational style overrides to
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

// MARK: - FlipTransition

/// Pixel-flip transition built on real 3D rotation. At the 1×1 stage the whole
/// screen is a single cell: the old page (front face) and new page (back face)
/// are stacked and the stack rotates on the Y axis from 0° to 180°. Below 90°
/// the front face shows; at 90° the faces swap so the back face (new page)
/// becomes visible, reading as one panel flipping over. Later stages split the
/// screen into a grid of such cells (2×2, 4×4, …) each carrying the full page
/// view offset+clipped to its tile.
struct FlipTransition: PageTransition {
    var seed: Int
    var color: Color
    var duration: Double

    var isRotational: Bool { true }

    /// Grid divisions per axis. 1×1: the whole screen is a single card.
    static let gridSize: Int = 1

    /// Maps transition progress (0…1) to a half-fold angle in degrees
    /// (0°…90°). Each half of the card folds through this range: the old front
    /// folds from 0° to 90° (away), the new back unfolds from 90° to 0°. Clamped
    /// so out-of-range progress can't overshoot.
    static func flipAngle(progress: Double) -> Double {
        max(0, min(1, progress)) * 90
    }

    /// Whether the front face (old page) is the visible side at `angle`. The
    /// swap to the back face (new page) happens at 90° (fully folded).
    static func isFrontFace(angle: Double) -> Bool {
        angle < 90
    }

    /// Rotation anchor for a half of the card. The top half folds around its
    /// bottom edge (the screen midline); the bottom half around its top edge
    /// (also the midline). The two anchors meet at the midline.
    static func halfAnchor(isTop: Bool) -> UnitPoint {
        isTop ? .bottom : .top
    }

    /// Old front-face angle for a half at `progress`: folds from 0° (flat) to
    /// 90° (folded away). Drives the old page rotating out of view.
    static func oldHalfAngle(progress: Double) -> Double {
        flipAngle(progress: progress)
    }

    /// New back-face angle for a half at `progress`: starts folded at 90° and
    /// unfolds to 0°. Drives the new page rotating into view. Complementary to
    /// `oldHalfAngle` (sum to 90° at every progress).
    static func newHalfAngle(progress: Double) -> Double {
        90 - flipAngle(progress: progress)
    }

    /// Mask members are unused because `isRotational` is `true`; `TransitionContainer`
    /// calls `rotationBody` instead. Kept as no-ops to satisfy the protocol.
    func newPageMask(progress: Double) -> AnyView { AnyView(EmptyView()) }
    func oldPageMask(progress: Double) -> AnyView { AnyView(EmptyView()) }
    func overlay(progress: Double, start: Date?) -> AnyView { AnyView(EmptyView()) }

    func rotationBody(old: AnyView, new: AnyView, progress: Double, start: Date?) -> AnyView {
        let duration = self.duration
        return AnyView(
            TimelineView(.animation) { context in
                let p = start.map { min(1, max(0, context.date.timeIntervalSince($0) / duration)) }
                    ?? max(0, min(1, progress))
                GeometryReader { geo in
                    let size = geo.size
                    let halfH = size.height / 2
                    let oldAngle = Self.oldHalfAngle(progress: p)
                    let newAngle = Self.newHalfAngle(progress: p)
                    let front = Self.isFrontFace(angle: oldAngle)
                    ZStack(alignment: .topLeading) {
                        // Top half: folds down around its bottom edge (midline).
                        flipHalf(content: old, size: size, halfOriginY: 0, halfH: halfH,
                                 angle: oldAngle, anchor: Self.halfAnchor(isTop: true), visible: front)
                        flipHalf(content: new, size: size, halfOriginY: 0, halfH: halfH,
                                 angle: newAngle, anchor: Self.halfAnchor(isTop: true), visible: !front)
                        // Bottom half: folds up around its top edge (midline).
                        flipHalf(content: old, size: size, halfOriginY: halfH, halfH: halfH,
                                 angle: oldAngle, anchor: Self.halfAnchor(isTop: false), visible: front)
                        flipHalf(content: new, size: size, halfOriginY: halfH, halfH: halfH,
                                 angle: newAngle, anchor: Self.halfAnchor(isTop: false), visible: !front)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                }
            }
        )
    }

    /// One half of the card. `content` is the full page view; `halfOriginY` is
    /// the half's top edge in screen coordinates (0 or halfH). The page is
    /// framed to the full screen, offset so the half's region sits at the
    /// origin, then clipped to `width × halfH` and rotated on X around `anchor`.
    /// Uses `rotationEffect` (2D) — no z-depth perspective — per the flip-clock
    /// stage under inspection.
    private func flipHalf(content: AnyView, size: CGSize, halfOriginY: CGFloat, halfH: CGFloat,
                          angle: Double, anchor: UnitPoint, visible: Bool) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .offset(x: 0, y: -halfOriginY)
            .frame(width: size.width, height: halfH, alignment: .topLeading)
            .clipped()
            .rotationEffect(.degrees(angle), anchor: anchor)
            .opacity(visible ? 1 : 0)
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
        case .slow: return 4.0
        case .normal: return 2.0
        case .fast: return 1.0
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
