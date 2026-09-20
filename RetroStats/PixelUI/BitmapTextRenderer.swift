import SwiftUI

/// Snaps rendered glyphs to the font's grid and removes antialiasing.
/// RetroBitmapA supplies authored glyphs; unsupported Unicode keeps system fallback.
struct BitmapTextRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let displayScale = context.environment.displayScale
        // Keep the 11-cell Hangul glyphs legible even on 1x displays before sampling.
        let sourceScale: CGFloat = displayScale < 1.5 ? 4 : 2
        for line in layout {
            for run in line {
                for glyph in run {
                    let bounds = glyph.typographicBounds
                    let em = bounds.ascent + bounds.descent
                    let authoredHangul = abs(bounds.width / em - 0.8) < 0.01
                    let pixel = max(CGFloat(0.5), em * (authoredHangul ? 0.07 : 0.1))
                    context.drawLayer { layer in
                        layer.addFilter(
                            .layerShader(ShaderLibrary.bitmapText(.float(Float(pixel)),
                                                                  .float2(Float(bounds.origin.x), Float(bounds.origin.y)),
                                                                  .float(Float(displayScale)),
                                                                  .float(Float(sourceScale)),
                                                                  .float3(Float(bounds.width), Float(bounds.ascent), Float(bounds.descent))),
                                         maxSampleOffset: CGSize(width: pixel * sourceScale + (sourceScale - 1) * bounds.width,
                                                                 height: pixel * sourceScale + (sourceScale - 1) * em))
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
#endif
