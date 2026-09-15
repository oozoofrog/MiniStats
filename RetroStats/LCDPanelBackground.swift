import SwiftUI

/// Translucent LCD sub-panel background for cards: a faint tint plus a pixel grid and a hairline border.
struct LCDPanelBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Double
    var grid: Double
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                Color.primary.opacity(tint)
                LCDPixelGrid(opacity: grid, pitch: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    /// Translucent LCD-style panel background for cards and surfaces.
    func lcdPanel(cornerRadius: CGFloat = 14, tint: Double = 0.05, grid: Double = 0.03) -> some View {
        modifier(LCDPanelBackground(cornerRadius: cornerRadius, tint: tint, grid: grid))
    }
}
