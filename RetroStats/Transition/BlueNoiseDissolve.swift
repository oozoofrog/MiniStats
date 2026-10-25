import SwiftUI

enum BlueNoiseDissolve {
    static let side = 64
    static let cellSize: CGFloat = 3

    /// Translation and reflection preserve the tile's spatial spectrum.
    static func threshold(x: Int, y: Int, seed: Int) -> Double {
        let bits = UInt(bitPattern: seed) &* 0x9E3779B97F4A7C15
        var u = (x + Int(bits & 63)) & 63
        var v = (y + Int((bits >> 6) & 63)) & 63
        if bits & (1 << 12) != 0 { swap(&u, &v) }
        if bits & (1 << 13) != 0 { u = 63 - u }
        return (Double(ranks[v * side + u]) + 0.5) / Double(side * side)
    }

    static func opacity(progress: Double, threshold: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        let t = max(0, min(1, (progress * 1.18 - threshold) / 0.18))
        return t * t * (3 - 2 * t)
    }

    /// One tiny alpha texture per animation frame, reused across the whole page.
    static func image(progress: Double, seed: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let alpha = opacity(progress: progress, threshold: threshold(x: x, y: y, seed: seed))
                let byte = UInt8((alpha * 255).rounded())
                let index = (y * side + x) * 4
                // Premultiplied white: every channel equals alpha.
                for channel in 0..<4 { pixels[index + channel] = byte }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct BlueNoiseFadeMask: View, Animatable {
    var animatableData: Double
    let seed: Int

    var body: some View {
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0,
                  let cgImage = BlueNoiseDissolve.image(progress: animatableData, seed: seed) else { return }
            let image = Image(decorative: cgImage, scale: 1).interpolation(.none)
            let tile = CGFloat(BlueNoiseDissolve.side) * BlueNoiseDissolve.cellSize
            for y in stride(from: CGFloat.zero, to: size.height, by: tile) {
                for x in stride(from: CGFloat.zero, to: size.width, by: tile) {
                    context.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
                }
            }
        }
    }
}
