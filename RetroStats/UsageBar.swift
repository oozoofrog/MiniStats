import SwiftUI

/// Segmented 1-bit usage meter; filled cells use the ink color, and warning cells use a dither pattern instead of an accent color.
struct UsageBar: View {
    let percent: Double
    let color: Color
    var warning = false
    private let cells = 24
    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 1) {
                ForEach(0..<cells, id: \.self) { i in
                    let on = Double(i) < percent / 100 * Double(cells)
                    if on && warning { DitherCell() }
                    else { RoundedRectangle(cornerRadius: 1, style: .continuous).fill(on ? color : color.opacity(0.08)) }
                }
            }
        }.frame(height: 10).accessibilityLabel("사용률").accessibilityValue(String(format: "%.0f%%", percent))
    }
}
