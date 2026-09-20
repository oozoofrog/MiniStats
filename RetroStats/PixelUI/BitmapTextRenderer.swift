import SwiftUI

/// Snaps rendered glyphs to the pixel grid and removes antialiasing.
/// RetroBitmapA supplies authored glyphs; unsupported Unicode keeps system fallback.
struct BitmapTextRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let bounds = line.typographicBounds
            let pixel = max(CGFloat(0.5), (bounds.ascent + bounds.descent) / 10)
            context.drawLayer { layer in
                layer.addFilter(
                    .layerShader(ShaderLibrary.bitmapText(.float(Float(pixel))),
                                 maxSampleOffset: CGSize(width: pixel, height: pixel))
                )
                layer.draw(line)
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
