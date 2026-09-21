import Foundation
import CoreText
import AppKit
import SwiftUI

private struct BitmapMask: Equatable {
    let width: Int
    let height: Int
    let pixels: [Bool]
}

private func bitmapMask(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> BitmapMask {
    var dark: [(Int, Int)] = []
    for row in y {
        for column in x {
            if let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
               color.redComponent < 0.9 {
                dark.append((column, row))
            }
        }
    }
    guard let minX = dark.map(\.0).min(), let maxX = dark.map(\.0).max(),
          let minY = dark.map(\.1).min(), let maxY = dark.map(\.1).max() else {
        return BitmapMask(width: 0, height: 0, pixels: [])
    }
    let width = maxX - minX + 1
    let height = maxY - minY + 1
    var pixels = [Bool](repeating: false, count: width * height)
    for (column, row) in dark {
        pixels[(row - minY) * width + column - minX] = true
    }
    return BitmapMask(width: width, height: height, pixels: pixels)
}

/// `precondition` messages are stripped from release builds, so bitmap failures
/// print their mask diff to stderr before trapping.
private func rows(_ m: BitmapMask) -> [String] {
    (0..<m.height).map { r in (0..<m.width).map { m.pixels[r * m.width + $0] ? "#" : "." }.joined() }
}

private func requireEqual(_ a: BitmapMask, _ b: BitmapMask, _ message: String) {
    guard a != b else { return }
    var text = "\(message)\n\(a.width)x\(a.height) vs \(b.width)x\(b.height)\n"
    for (x, y) in zip(rows(a), rows(b)) { text += "\(x)  \(y)\n" }
    FileHandle.standardError.write(Data(text.utf8))
    preconditionFailure(message)
}

@MainActor func bitmapTextSelfTest() {
    _ = NSApplication.shared
    let samples: [(String, CGFloat)] = [("i", 0.6), ("W", 0.6), ("8", 0.6), ("|", 0.6), ("한", 1.0), ("글", 1.0)]
    let styles: [(String, HierarchicalShapeStyle)] = [("primary", .primary), ("secondary", .secondary)]
    for (styleName, style) in styles {
        for scale in [1.0, 2.0] {
            for size in [11.0, 13.0, 16.0, 18.0] {
                for (character, advanceRatio) in samples {
                    func render(_ offset: CGFloat) -> NSBitmapImageRep {
                        let content = Text(String(repeating: character, count: 20))
                            .font(.bitmap(size))
                            .foregroundStyle(style)
                            .textRenderer(BitmapTextRenderer())
                            .fixedSize()
                            .offset(x: offset, y: offset)
                            .frame(width: 400, height: 50, alignment: .topLeading)
                            .background(Color.white)
                            .environment(\.colorScheme, .light)
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = scale
                        guard let image = renderer.cgImage else { preconditionFailure("Bitmap text did not render") }
                        return NSBitmapImageRep(cgImage: image)
                    }
                    let bitmap = render(0)
                    let advance = size * advanceRatio * scale
                    let hangul = advanceRatio > 0.7
                    let cellPx = BitmapTextRenderer.snappedCell(size * (hangul ? 0.07 : 0.1), displayScale: scale) * scale
                    // Snapped cells can overflow a 1x advance (16pt ASCII, small Hangul); neighbours then share columns.
                    let overflows = (hangul ? 11 : 5) * cellPx > advance + 0.001
                    var reference: BitmapMask?
                    for index in 0..<20 {
                        let start = Int((CGFloat(index) * advance).rounded())
                        let end = Int((CGFloat(index + 1) * advance).rounded())
                        let mask = bitmapMask(bitmap, x: start..<end, y: 0..<Int(50 * scale))
                        precondition(mask.width > 0 && mask.height > 0, "Missing bitmap glyph: \(character)")
                        if let reference, !overflows {
                            requireEqual(reference, mask, "Bitmap glyph changes with position: \(character), \(size)pt at \(scale)x (\(styleName)), glyph \(index)")
                        } else {
                            reference = mask
                        }
                    }
                    if character == "|", let reference {
                        // "|" is a single 7-cell column: its mask is exactly one snapped cell wide.
                        precondition(CGFloat(reference.width) == cellPx && CGFloat(reference.height) == 7 * cellPx,
                                     "Stroke thickness \(reference.width)x\(reference.height) is not \(cellPx)px at \(size)pt \(scale)x")
                    }
                    if size == 13 && (character == "i" || character == "한") {
                        let fullWidth = Int(400 * scale)
                        let fullHeight = Int(50 * scale)
                        let baseline = bitmapMask(bitmap, x: 0..<fullWidth, y: 0..<fullHeight)
                        for offset in [0.25, 0.5, 0.75] {
                            requireEqual(baseline, bitmapMask(render(offset), x: 0..<fullWidth, y: 0..<fullHeight),
                                         "Bitmap text changes when moved: \(character), \(scale)x (\(styleName)), offset \(offset)")
                        }
                    }
                }
            }
        }
    }
    print("PASS: bitmap glyph shape, uniform stroke thickness, and text translation at 1x/2x, primary/secondary")
}

func selfTest() {
    precondition(RetroBitmapFont.registered, "RetroBitmapA registration failed")
    let font = CTFontCreateWithName(RetroBitmapFont.postScriptName as CFString, 12, nil)
    precondition(CTFontCopyPostScriptName(font) as String == RetroBitmapFont.postScriptName,
                 "RetroBitmapA did not resolve")
    var characters = Array("iW0%".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    precondition(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
                 "RetroBitmapA is missing basic glyphs")
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    precondition(advances.allSatisfy { abs($0.width - advances[0].width) < 0.01 },
                 "RetroBitmapA glyphs have unequal advances")
    var hangul = Array("한글".utf16)
    var hangulGlyphs = [CGGlyph](repeating: 0, count: hangul.count)
    precondition(CTFontGetGlyphsForCharacters(font, &hangul, &hangulGlyphs, hangul.count),
                 "RetroBitmapA is missing authored Hangul samples")
    var hangulAdvances = [CGSize](repeating: .zero, count: hangulGlyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, hangulGlyphs, &hangulAdvances, hangulGlyphs.count)
    precondition(abs(hangulAdvances[0].width - hangulAdvances[1].width) < 0.01,
                 "RetroBitmapA Hangul samples have unequal advances")
    precondition(Bundle.main.url(forResource: "default", withExtension: "metallib") != nil,
                 "Bitmap text shader is missing from the app bundle")
    precondition(cpuLoad([0, 0, 0, 0], [20, 10, 70, 0])?.total == 30)
    precondition(cpuLoad([0, 0, 0, 0], [20, 10, 70, 0])?.system == 10)
    precondition(cpuLoad([1, 1, 1, 1], [1, 1, 1, 1]) == nil)
    precondition(cpuLoad([UInt32.max, 0, 0, 0], [0, 0, 1, 0])?.user == 50)
    precondition(cpuLoad([], []) == nil)
    let idle = ProcessSample(name: "idle", start: 1, cpuTime: 0, memory: 10)
    let busy = ProcessSample(name: "idle", start: 1, cpuTime: 1_500_000_000, memory: 10)
    let old = ProcessSample(name: "old", start: 2, cpuTime: 100, memory: 20)
    let reused = ProcessSample(name: "new", start: 3, cpuTime: 5_000_000_000, memory: 5)
    let ranked = ProcessOrder.cpu.sorted(rankedProcesses(before: [1: idle, 2: old], after: [1: busy, 2: reused], seconds: 3))
    precondition(ranked.count == 1 && ranked[0].name == "idle" && ranked[0].cpu == 50)
    precondition(ProcessOrder.cpu.sorted(rankedProcesses(before: [1: idle], after: [1: busy], seconds: 0)).isEmpty)
    precondition(ProcessOrder.memory.sorted(rankedProcesses(before: [:], after: [1: busy, 2: reused], seconds: 0)).map(\.name) == ["idle", "new"])
    let processes = processSamples()
    precondition((processes[getpid()]?.memory ?? 0) > 0)
    precondition(sysctlValue("vm.swapusage", xsw_usage()) != nil)
    precondition([1, 2, 4].contains(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) ?? 0))
    let before = ["en0": Traffic(received: 100, sent: 200)]
    let after = ["en0": Traffic(received: 1124, sent: 2248), "en1": Traffic(received: 99999, sent: 99999)]
    let rate = networkRate(before, after, seconds: 2)!
    precondition(rate.0 == 512 && rate.1 == 1024)
    precondition(networkRate(before, after, seconds: 0) == nil)
    let reset = networkRate(before, ["en0": Traffic(received: 0, sent: 0)], seconds: 1)!
    precondition(reset.0 == 0 && reset.1 == 0)
    let large = networkRate(["en0": Traffic(received: 0, sent: 0)], ["en0": Traffic(received: 5_000_000_000, sent: 0)], seconds: 1)!
    precondition(large.0 == 5_000_000_000)
    precondition(parseNetwork(Data([0, 0, 0, 0])) == nil)
    precondition(parseNetwork(Data([8, 0, 0, 0])) == nil)
    precondition(parseNetwork(Data([4, 0, 0, UInt8(RTM_IFINFO2)])) == nil)
    precondition(parseNetwork(Data([4, 0, 0, 0]))?.isEmpty == true)
    precondition(speed(1_048_576) == "1.0 MiB/s")
    precondition(cpuTicks()?.count == 4)
    guard let memory = memoryUsage(), memory.used > 0, memory.used <= totalMemory,
          let network = networkCounters() else { fatalError("Live metric read failed") }
    let ticks = cpuTicks()!
    Thread.sleep(forTimeInterval: 3)
    guard let cpu = cpuLoad(ticks, cpuTicks()!), (0...100).contains(cpu.total) else { fatalError("Live CPU delta failed") }
    let live = ProcessOrder.cpu.sorted(rankedProcesses(before: processes, after: processSamples(), seconds: 3)).prefix(5)
    precondition(live.allSatisfy { ($0.cpu ?? 0) >= 0 && ($0.cpu ?? 0) <= 100 * Double(ProcessInfo.processInfo.activeProcessorCount) })
    print("PASS: bitmap font registration/fixed width, shader bundle, CPU math/wraparound, memory bounds, network parser/rates/reset/64-bit counters, process ranking/pid reuse, sysctl reads, formatting, live sampling")
    print("CPU \(String(format: "%.1f", cpu.total))% · Memory \(bytes(memory.used))/\(bytes(totalMemory)) · \(swapText()) · \(memoryPressureText()) · \(loadAverageText()) · Interfaces \(network.keys.sorted()) · \(batteryText())")
    print("Processes \(processes.count) · top CPU \(live.map { "\($0.name) \(String(format: "%.1f", $0.cpu ?? 0))%" })")
}
