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
