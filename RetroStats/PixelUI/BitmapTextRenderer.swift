import SwiftUI

/// Snaps rendered glyphs to the font's grid and removes antialiasing.
/// RetroBitmapA supplies authored glyphs; unsupported Unicode keeps system fallback.
struct BitmapTextRenderer: TextRenderer {
    /// Font cell rounded to whole device pixels. Rounds down one pixel instead
    /// when the snapped glyph would spill past its advance or above the ascent.
    static func snappedCell(_ fontCell: CGFloat, advance: CGFloat, ascent: CGFloat, cells: CGFloat, displayScale: CGFloat) -> CGFloat {
        var px = max(1, (fontCell * displayScale).rounded())
        if px > 1, px * cells > min(advance, ascent) * displayScale + 0.001 { px -= 1 }
        return px / displayScale
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let displayScale = context.environment.displayScale
        // Keep the 11-cell Hangul glyphs legible even on 1x displays before sampling.
        let sourceScale: CGFloat = displayScale < 1.5 ? 4 : 2
        for line in layout {
            for run in line {
                for glyph in run {
                    let bounds = glyph.typographicBounds
                    // RetroBitmapA: ascent 0.9em + descent 0.2em; cells are 0.1em (ASCII) or 0.07em (authored Hangul).
                    let em = (bounds.ascent + bounds.descent) / 1.1
                    let authoredHangul = abs(bounds.width / em - 0.9) < 0.01
                    let fontCell = em * (authoredHangul ? 0.07 : 0.1)
                    // Snap each font cell to a whole number of device pixels so every stroke
                    // has the same thickness at every size; the glyph grows or shrinks slightly
                    // relative to its advance instead of alternating 2px/3px cells.
                    let pixel = Self.snappedCell(fontCell, advance: bounds.width, ascent: bounds.ascent, cells: authoredHangul ? 11 : 7, displayScale: displayScale)
                    let grow = pixel / fontCell
                    context.drawLayer { layer in
                        layer.addFilter(
                            .layerShader(ShaderLibrary.bitmapText(.float(Float(pixel)),
                                                                  .float2(Float(bounds.origin.x), Float(bounds.origin.y)),
                                                                  .float(Float(displayScale)),
                                                                  .float(Float(fontCell * sourceScale)),
                                                                  .float3(Float(bounds.width * grow), Float(bounds.ascent * grow), Float(bounds.descent * grow))),
                                         maxSampleOffset: CGSize(width: fontCell * sourceScale + (sourceScale - 1) * bounds.width,
                                                                 height: fontCell * sourceScale + (sourceScale - 1) * (bounds.ascent + bounds.descent)))
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
    .frame(width: 520, height: 900)
}
#endif
