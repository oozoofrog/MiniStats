import SwiftUI

/// Snaps rendered glyphs to the font's grid and removes antialiasing.
/// RetroBitmapA supplies authored glyphs; unsupported Unicode keeps system fallback.
struct BitmapTextRenderer: TextRenderer {
    /// Font cell rounded to a whole number of device pixels, never below one.
    static func snappedCell(_ fontCell: CGFloat, displayScale: CGFloat) -> CGFloat {
        max(1, (fontCell * displayScale).rounded()) / displayScale
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let displayScale = context.environment.displayScale
        // Keep the 11-cell Hangul glyphs legible even on 1x displays before sampling.
        let sourceScale: CGFloat = displayScale < 1.5 ? 4 : 2
        for line in layout {
            for run in line {
                for glyph in run {
                    let bounds = glyph.typographicBounds
                    // RetroBitmapA: ascent 1.0em, descent 0.2em (ratio 5, unlike any system font),
                    // ASCII cells 0.1em in a 0.6em advance, authored Hangul cells 0.07em in a 1.0em advance.
                    let authored = abs(bounds.ascent / bounds.descent - 5) < 0.01
                    let em = (bounds.ascent + bounds.descent) / 1.2
                    let authoredHangul = authored && abs(bounds.width / em - 1) < 0.01
                    let fontCell = em * (authoredHangul ? 0.07 : 0.1)
                    // Snap each cell to whole device pixels so every stroke has the same thickness.
                    // Authored glyphs are rescaled to the snapped grid; fallback glyphs keep their
                    // size and are only pixelated on it.
                    let pixel = Self.snappedCell(fontCell, displayScale: displayScale)
                    let grow = authored ? pixel / fontCell : 1
                    context.drawLayer { layer in
                        layer.addFilter(
                            .layerShader(ShaderLibrary.bitmapText(.float(Float(pixel)),
                                                                  .float2(Float(bounds.origin.x), Float(bounds.origin.y)),
                                                                  .float(Float(displayScale)),
                                                                  .float(Float(pixel / grow * sourceScale)),
                                                                  .float3(Float(bounds.width * grow), Float(bounds.ascent * grow), Float(bounds.descent * grow))),
                                         maxSampleOffset: CGSize(width: (bounds.width + pixel) * sourceScale,
                                                                 height: (bounds.ascent + bounds.descent + pixel) * sourceScale))
                        )
                        layer.translateBy(x: bounds.origin.x, y: bounds.origin.y)
                        layer.scaleBy(x: sourceScale, y: sourceScale)
                        layer.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                        layer.draw(glyph)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Bitmap Unicode") {
    VStack(alignment: .leading, spacing: 9) {
        Text("CPU 35% · Memory 24 GB").font(.bitmap(10))
        Text("RetroStats 0123456789").font(.bitmap(13))
        Text("한글 日本語 中文 😀").font(.bitmap(16))
        Text("/Users/개발자/My App/📁").font(.bitmap(11))
    }
    .textRenderer(BitmapTextRenderer())
    .tracking(1)
    .padding(12)
}

/// Every font size the dashboard uses, on both LCD and panel backgrounds.
#Preview("Bitmap Sizes") {
    let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 26, 30, 32, 40]
    ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sizes, id: \.self) { size in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(Int(size))pt").font(.bitmap(10)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    Text("RetroStats 0123456789 한글 iIl1 oO0 %").font(.bitmap(size))
                }
            }
            LCDScreen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sizes, id: \.self) { size in
                        Text("\(Int(size)) CPU 35% · 24 GB 한글").font(.bitmap(size)).foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(16)
    }
    .textRenderer(BitmapTextRenderer())
    .tracking(1)
    .frame(width: 520, height: 900)
}
#endif
