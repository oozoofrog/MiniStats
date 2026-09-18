import SwiftUI

/// Fine pixel grid that mimics the subpixel matrix of an LCD panel.
struct LCDPixelGrid: View {
    var opacity: Double = 0.06
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
