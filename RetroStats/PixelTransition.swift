import SwiftUI

/// LCD pixel particle transition overlay. Particles start on a grid, scatter
/// outward while fading out (the old page dissolves), then gather back to the
/// grid while fading in (the new page assembles). Used between dashboard pages.
struct PixelTransition: View {
    var progress: Double  // 0 → 1
    var color: Color = .primary

    private static let particles: [Particle] = {
        let cols = 10, rows = 15
        let stepX: CGFloat = 400 / CGFloat(cols - 1)
        let stepY: CGFloat = 600 / CGFloat(rows - 1)
        var particles: [Particle] = []
        for j in 0..<rows {
            for i in 0..<cols {
                let home = CGPoint(x: CGFloat(i) * stepX, y: CGFloat(j) * stepY)
                let angle = Double.random(in: 0..<(2 * .pi))
                let dist = CGFloat.random(in: 80...160)
                let scatter = CGPoint(
                    x: home.x + CGFloat(cos(angle)) * dist,
                    y: home.y + CGFloat(sin(angle)) * dist
                )
                particles.append(Particle(
                    home: home,
                    scatter: scatter,
                    size: [2, 3].randomElement()!,
                    delay: Double.random(in: 0...0.12)
                ))
            }
        }
        return particles
    }()

    var body: some View {
        Canvas { ctx, _ in
            let t = max(0, min(1, progress))
            for p in Self.particles {
                let localT = max(0, min(1, (t - p.delay) / (1 - p.delay)))
                let pos = position(p, t: localT)
                let opacity = localT < 0.5 ? (1 - localT / 0.5) : ((localT - 0.5) / 0.5)
                let rect = CGRect(x: pos.x - p.size / 2, y: pos.y - p.size / 2,
                                  width: p.size, height: p.size)
                ctx.fill(Path(rect), with: .color(color.opacity(opacity * 0.55)))
            }
        }
        .frame(width: 400, height: 600)
        .allowsHitTesting(false)
    }

    private func position(_ p: Particle, t: Double) -> CGPoint {
        if t < 0.5 {
            return lerp(p.home, p.scatter, easeOut(t / 0.5))
        } else {
            return lerp(p.scatter, p.home, easeIn((t - 0.5) / 0.5))
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t))
    }
    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private func easeIn(_ t: Double) -> Double { t * t * t }

    private struct Particle {
        let home: CGPoint
        let scatter: CGPoint
        let size: CGFloat
        let delay: Double
    }
}
