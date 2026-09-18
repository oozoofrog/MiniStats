import SwiftUI

/// Translucent LCD panel: a dark substrate that lets the window glass bleed through, with a pixel grid, scanlines and glare framing hero numerals.
struct LCDScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(10)
            .background(
                ZStack {
                    Color.black.opacity(0.55)
                    LCDPixelGrid(opacity: 0.07)
                    LCDScanlines(opacity: 0.05)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}
