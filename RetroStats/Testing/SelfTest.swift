import Foundation
import CoreText

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
    let ranked = topCPU([1: idle, 2: old], [1: busy, 2: reused], seconds: 3)
    precondition(ranked.count == 1 && ranked[0].name == "idle" && ranked[0].percent == 50)
    precondition(topCPU([1: idle], [1: busy], seconds: 0).isEmpty)
    precondition(topMemory([1: busy, 2: reused]).map(\.name) == ["idle", "new"])
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
    let live = topCPU(processes, processSamples(), seconds: 3)
    precondition(live.allSatisfy { $0.percent >= 0 && $0.percent <= 100 * Double(ProcessInfo.processInfo.activeProcessorCount) })
    print("PASS: bitmap font registration/fixed width, shader bundle, CPU math/wraparound, memory bounds, network parser/rates/reset/64-bit counters, process ranking/pid reuse, sysctl reads, formatting, live sampling")
    print("CPU \(String(format: "%.1f", cpu.total))% · Memory \(bytes(memory.used))/\(bytes(totalMemory)) · \(swapText()) · \(memoryPressureText()) · \(loadAverageText()) · Interfaces \(network.keys.sorted()) · \(batteryText())")
    print("Processes \(processes.count) · top CPU \(live.map { "\($0.name) \(String(format: "%.1f", $0.percent))%" }) · top memory \(topMemory(processes).map { "\($0.name) \(bytes($0.memory))" })")
}
