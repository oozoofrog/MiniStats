import SwiftUI

/// 2x2 checkerboard cell so a "filled" warning segment stays black-and-white.
struct DitherCell: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width / 2, h = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.primary))
            ctx.fill(Path(CGRect(x: w, y: h, width: w, height: h)), with: .color(.primary))
        }
    }
}
