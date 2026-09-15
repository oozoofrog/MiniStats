import SwiftUI

/// Column histogram rendered as 1-bit pixel bars; replaces the stroked line.
struct HistoryLine: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let h = max(2, min(100, value) / 100 * geometry.size.height)
                    Rectangle().fill(color).frame(height: h)
                }
            }
        }.frame(height: 34).accessibilityHidden(true)
    }
}
