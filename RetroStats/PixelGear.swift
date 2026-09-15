import SwiftUI

/// Pixel-art gear drawn as 1x1 cells on a 16x16 grid, replacing the vector SF Symbol.
struct PixelGear: View {
    var size: CGFloat = 16
    var body: some View {
        Canvas { ctx, sz in
            let N = 16.0
            let scale = sz.width / N
            let cx = (N - 1) / 2, cy = (N - 1) / 2
            let Rout = 7.2, Rring = 4.6, Rhole = 1.9
            let teeth = 8, half = 16.0 * .pi / 180
            var path = Path()
            for j in 0..<Int(N) {
                for i in 0..<Int(N) {
                    let dx = Double(i) - cx, dy = Double(j) - cy
                    let r = (dx * dx + dy * dy).squareRoot()
                    let ang = atan2(dy, dx)
                    var onTooth = false
                    for k in 0..<teeth {
                        let a = Double(k) * 2 * .pi / Double(teeth)
                        let d = abs((ang - a + .pi).truncatingRemainder(dividingBy: 2 * .pi) - .pi)
                        if d < half { onTooth = true; break }
                    }
                    let filled = (r > Rhole && r <= Rout) && (r <= Rring || onTooth)
                    if filled { path.addRect(CGRect(x: Double(i) * scale, y: Double(j) * scale, width: scale, height: scale)) }
                }
            }
            ctx.fill(path, with: .color(.primary))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
