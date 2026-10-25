import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Reproducible artwork, independent of the app build. Coordinates use a
// 1024-point, top-left canvas; the transparent margin belongs to the artwork.
// Palette follows RetroTheme's Ivory finish and phosphor display.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("assets/AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: 1024, height: 1024,
                        bitsPerComponent: 8, bytesPerRow: 4096, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255,
                                          CGFloat((hex >> 8) & 255) / 255,
                                          CGFloat(hex & 255) / 255, alpha])!
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func fill(_ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
    context.addPath(path)
    context.setFillColor(color(hex, alpha: alpha))
    context.fillPath()
}

func gradient(_ path: CGPath, _ top: UInt32, _ bottom: UInt32, from: CGFloat, to: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let shades = [color(top), color(bottom)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: shades, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: from),
                               end: CGPoint(x: 512, y: to), options: [])
    context.restoreGState()
}

// A warm, shallow enclosure: curved silhouette outside, square pixels inside.
let enclosure = rounded(80, 80, 864, 864, 180)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 16,
                  color: color(0x292B24, alpha: 0.18))
fill(enclosure, 0xC6BEAA)
context.restoreGState()
gradient(enclosure, 0xF5F0E3, 0xDAD2BE, from: 80, to: 944)
context.addPath(rounded(84, 84, 856, 856, 176))
context.setStrokeColor(color(0xFFFDF3, alpha: 0.8))
context.setLineWidth(4)
context.strokePath()

// Recessed screen, with a restrained bevel instead of a luminous glow.
gradient(rounded(184, 200, 656, 512, 52), 0xAAA591, 0xFFF9EA, from: 200, to: 712)
fill(rounded(200, 216, 624, 480, 40), 0x292B24)
gradient(rounded(212, 228, 600, 456, 30), 0x20251D, 0x35402C, from: 228, to: 684)

// Four block meters, with ample gaps so their silhouette survives 16/32px.
let columns: [(CGFloat, Int)] = [(288, 5), (400, 9), (512, 7), (624, 12)]
for (x, count) in columns {
    for row in 0..<count {
        let y = CGFloat(620 - row * 24)
        fill(CGPath(rect: CGRect(x: x, y: y, width: 80, height: 18), transform: nil), 0xD4D8B1)
    }
}

// A classic front-panel slot and status light, kept subordinate to the meters.
fill(rounded(528, 786, 252, 22, 6), 0x777666)
fill(rounded(528, 786, 252, 10, 4), 0x414633)
fill(CGPath(ellipseIn: CGRect(x: 244, y: 780, width: 28, height: 28), transform: nil), 0x414633)
fill(CGPath(ellipseIn: CGRect(x: 250, y: 784, width: 12, height: 12), transform: nil), 0x9DAD7A)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
          UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create app icon output")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write app icon") }
print("Generated: \(output.path)")
