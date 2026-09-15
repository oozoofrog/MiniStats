import SwiftUI

/// Horizontal scanlines that mimic the row gaps of an LCD panel.
struct LCDScanlines: View {
    var opacity: Double = 0.05
    var spacing: CGFloat = 3
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.white.opacity(opacity)
            var y = 0.0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(ink))
                y += spacing
            }
        }
    }
}
