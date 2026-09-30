import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor func statusReadoutSelfTest() throws {
    _ = NSApplication.shared
    precondition(StorageBitFill.percent(nil) == 0 && StorageBitFill.percent(.nan) == 0)
    precondition(StorageBitFill.percent(.infinity) == 0 && StorageBitFill.percent(-1) == 0)
    precondition(StorageBitFill.percent(101) == 100)
    precondition(StatusMetric(nil) == .unavailable && StatusMetric(.nan) == .unavailable)
    precondition(StatusMetric(99.4) == .percent(99) && StatusMetric(99.6) == .maximum)
    precondition(StatusMetric(100) == .maximum)

    for size in [CGSize(width: 38, height: 22), CGSize(width: 38, height: 24), CGSize(width: 39, height: 23)] {
        var previous: Set<CGRectKey> = []
        for percent in 0...100 {
            let cells = StorageBitFill.cells(size: size, percent: Double(percent))
            let keys = Set(cells.map(CGRectKey.init))
            precondition(previous.isSubset(of: keys), "Storage bits recede as usage rises")
            precondition(cells.allSatisfy { CGRect(origin: .zero, size: size).contains($0) }, "Storage bits overflow the status item")
            previous = keys
        }
        let full = StorageBitFill.cells(size: size, percent: 100)
        precondition(full.reduce(0) { $0 + $1.width * $1.height } == size.width * size.height)
        precondition(StorageBitFill.cells(size: size, percent: nil).isEmpty)
    }

    let size = CGSize(width: 38, height: 24)
    let waveFrames = [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2].map {
        Set(StorageBitFill.cells(size: size, percent: 62, phase: $0).map(CGRectKey.init))
    }
    precondition(Set(waveFrames.map(\.count)).count == 1, "Wave must preserve storage fill quantity")
    precondition(waveFrames[0] != waveFrames[1], "Storage surface must move with phase")
    precondition(waveFrames[0] == Set(StorageBitFill.cells(size: size, percent: 62, phase: 2 * .pi).map(CGRectKey.init)),
                 "Wave must loop without a discontinuity")
    for phase in [0.0, Double.pi / 2, Double.pi] {
        precondition(StorageBitFill.cells(size: size, percent: 0, phase: phase).isEmpty)
        precondition(StorageBitFill.cells(size: size, percent: 100, phase: phase).count == 228)
        let cells = Set(StorageBitFill.cells(size: size, percent: 62, phase: phase).map(CGRectKey.init))
        for cell in cells where cell.y > 0 {
            precondition(cells.contains(CGRectKey(CGRect(x: cell.x, y: cell.y - 2, width: cell.width, height: cell.height))),
                         "Water fill must be contiguous below its surface")
        }
    }
    precondition(StatusReadout.shouldAnimate(storagePercent: 62, attached: true, reduceMotion: false))
    precondition(!StatusReadout.shouldAnimate(storagePercent: 62, attached: true, reduceMotion: true))
    precondition(!StatusReadout.shouldAnimate(storagePercent: 62, attached: false, reduceMotion: false))
    precondition(!StatusReadout.shouldAnimate(storagePercent: 0, attached: true, reduceMotion: false))
    precondition(!StatusReadout.shouldAnimate(storagePercent: 100, attached: true, reduceMotion: false))
    let samples: [(Double?, Double?)] = [(24, 68), (7, 43), (99, 99), (100, 100), (nil, nil)]
    for scale in [CGFloat(1), CGFloat(2)] {
        for (cpu, memory) in samples {
            guard let emptyImage = statusReadoutImage(size: size, scale: scale, cpu: cpu, memory: memory, storagePercent: 0) else {
                preconditionFailure("Status text failed to render")
            }
            let empty = NSBitmapImageRep(cgImage: emptyImage)
            let width = empty.pixelsWide, height = empty.pixelsHigh
            let textAlpha = (0..<height).flatMap { y in (0..<width).map { x in empty.colorAt(x: x, y: y)!.alphaComponent } }
            precondition(textAlpha.contains { $0 > 0.9 }, "Status text is missing")
            for value in [0.0, 25, 50, 62, 99, 100] {
              for phase in (value == 62 ? [nil, 0.0, Double.pi / 2] : [nil]) as [Double?] {
                guard let image = statusReadoutImage(size: size, scale: scale, cpu: cpu, memory: memory, storagePercent: value, phase: phase) else {
                    preconditionFailure("Status readout failed to render")
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                let cells = StorageBitFill.cells(size: size, percent: value, phase: phase)
                for y in 0..<height {
                    for x in 0..<width {
                        // Bitmap rows are top-down; fill geometry uses AppKit's bottom-up coordinates.
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: size.height - (CGFloat(y) + 0.5) / scale)
                        let filled = cells.contains { $0.contains(point) }
                        let glyph = textAlpha[y * width + x]
                        let expected = filled ? 1 - glyph : glyph
                        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        precondition(abs(color.alphaComponent - expected) <= 1.0 / 255,
                                     "Storage must punch transparent glyphs into the fill at \(value)% / \(scale)x")
                        if color.alphaComponent > 0.99 {
                            precondition(color.redComponent > 0.99 && color.greenComponent > 0.99 && color.blueComponent > 0.99,
                                         "Opaque status pixels must remain white")
                        }
                    }
                }
                if value == 62 {
                    precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Storage fill must leave the top empty")
                    precondition(bitmap.colorAt(x: 0, y: height - 1)!.alphaComponent == 1, "Storage fill must start at the bottom")
                }
              }
            }
        }
    }

    let view = StatusReadout(frame: CGRect(origin: .zero, size: size))
    precondition(view.hitTest(CGPoint(x: 10, y: 10)) == nil, "Readout must let the status button receive clicks")
    precondition(!view.isOpaque, "Menu bar background must show through the glyphs")

    if let path = ProcessInfo.processInfo.environment["RETROSTATS_STATUS_READOUT_OUTPUT"] {
        try renderStatusReadoutSamples(to: URL(fileURLWithPath: path))
    }
    print("PASS: storage bits rise monotonically, stay in bounds, cover 0–100%, punch transparent CPU/Memory/PixelMax glyphs at 1x/2x, and preserve menu button hit testing")
    print("PASS: traveling storage wave preserves fill quantity and contiguous columns, loops smoothly, keeps transparent glyphs, and stops for Reduce Motion, detached views, empty/full storage")
}

private struct CGRectKey: Hashable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
}

/// Optional offscreen evidence from the same native renderer used by the menu
/// bar. This path does not start AppDelegate, storage services or login setup.
@MainActor private func renderStatusReadoutSamples(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let size = CGSize(width: 38, height: 24)
    guard let sheet = CGContext(data: nil, width: 960, height: 390, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        preconditionFailure("Could not create native readout evidence")
    }
    sheet.setFillColor(NSColor(calibratedWhite: 0.15, alpha: 1).cgColor)
    sheet.fill(CGRect(x: 0, y: 0, width: 960, height: 390))
    for (index, value) in [0.0, 25, 62, 100].enumerated() {
        guard let image = statusReadoutImage(size: size, scale: 2, cpu: 24, memory: 68, storagePercent: value),
              let maximum = statusReadoutImage(size: size, scale: 2, cpu: 100, memory: 100, storagePercent: value) else {
            preconditionFailure("Could not render native readout evidence")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("storage-\(Int(value))-2x.png"))
        let x = CGFloat(index) * 240 + 6
        sheet.setFillColor(NSColor(calibratedRed: 0.30, green: 0.37, blue: 0.48, alpha: 1).cgColor)
        sheet.fill(CGRect(x: x, y: 205, width: 228, height: 144))
        sheet.setFillColor(NSColor(calibratedRed: 0.57, green: 0.52, blue: 0.62, alpha: 1).cgColor)
        sheet.fill(CGRect(x: x, y: 25, width: 228, height: 144))
        sheet.interpolationQuality = .none
        sheet.draw(image, in: CGRect(x: x, y: 205, width: 228, height: 144))
        sheet.draw(maximum, in: CGRect(x: x, y: 25, width: 228, height: 144))
    }
    let bitmap = NSBitmapImageRep(cgImage: sheet.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("status-readout-native.png"))
    let waveURL = directory.appendingPathComponent("status-readout-wave.gif")
    guard let gif = CGImageDestinationCreateWithURL(waveURL as CFURL, UTType.gif.identifier as CFString, 48, nil) else {
        preconditionFailure("Could not create native wave evidence")
    }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<48 {
        let phase = 2 * Double.pi * Double(frame) / 48
        let image = statusReadoutImage(size: size, scale: 2, cpu: 24, memory: 68, storagePercent: 62, phase: phase)!
        let context = CGContext(data: nil, width: 228, height: 144, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedRed: 0.30, green: 0.37, blue: 0.48, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 228, height: 144))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 228, height: 144))
        CGImageDestinationAddImage(gif, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 12]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(gif), "Native wave GIF did not finalize")
    print("Native menu bar render samples: \(directory.path)")
}
