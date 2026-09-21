#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// pixelSize: output cell in points, already a whole number of device pixels.
// sourcePixel: one font cell in the (pre-scaled) source layer, in points.
// glyphBounds: (width, ascent, descent) of the output glyph on the snapped grid.
[[ stitchable ]] half4 bitmapText(float2 position, SwiftUI::Layer layer, float pixelSize,
                                 float2 glyphOrigin, float displayScale, float sourcePixel,
                                 float3 glyphBounds) {
    if (position.x < glyphOrigin.x || position.x >= glyphOrigin.x + glyphBounds.x ||
        position.y < glyphOrigin.y - glyphBounds.y || position.y >= glyphOrigin.y + glyphBounds.z) {
        return half4(0.0h);
    }
    // Round every glyph's origin once so fractional advances cannot change its cell widths.
    float2 devicePixel = floor(position * displayScale);
    float2 deviceOrigin = round(glyphOrigin * displayScale);
    float2 cell = floor((devicePixel - deviceOrigin + 0.5) / (pixelSize * displayScale));
    float2 samplePoint = glyphOrigin + (cell + 0.5) * sourcePixel;
    half4 source = layer.sample(samplePoint);
    half alpha = source.a >= 0.3h ? source.a : 0.0h;
    half3 color = source.a > 0.0h ? source.rgb / source.a : half3(0.0h);
    return half4(color * alpha, alpha);
}
