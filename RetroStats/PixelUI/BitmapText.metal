#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 bitmapText(float2 position, SwiftUI::Layer layer, float pixelSize) {
    float2 samplePoint = (floor(position / pixelSize) + 0.5) * pixelSize;
    half4 source;
    half threshold;
    if (pixelSize < 1.15) {
        // Tiny cells can straddle device pixels; sample coverage without blending the output.
        float offset = pixelSize * 0.25;
        source = (layer.sample(samplePoint + float2(-offset, -offset))
                + layer.sample(samplePoint + float2( offset, -offset))
                + layer.sample(samplePoint + float2(-offset,  offset))
                + layer.sample(samplePoint + float2( offset,  offset))) * 0.25h;
        half3 ink = source.a > 0.0h ? source.rgb / source.a : half3(0.0h);
        threshold = dot(ink, half3(0.2126h, 0.7152h, 0.0722h)) > 0.5h ? 0.35h : 0.25h;
    } else {
        source = layer.sample(samplePoint);
        threshold = 0.5h;
    }
    half alpha = source.a >= threshold ? 1.0h : 0.0h;
    half3 color = source.a > 0.0h ? source.rgb / source.a : half3(0.0h);
    return half4(color * alpha, alpha);
}
