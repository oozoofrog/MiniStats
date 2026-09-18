import AppKit
import SwiftUI

/// Content rendering for layout inspection; does not test window-server glass compositing or mouse interaction.
/// Reads live metrics and the cached storage report without login registration, notifications, scans or deletion.
@MainActor func renderDashboard(to directory: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = DashboardModel()
    model.storage = StorageController(changed: {}, openMenu: {}, startServices: false)
    let previousCPU = cpuTicks()
    let previousProcesses = processSamples()
    let previousNetwork = networkCounters()
    let before = ProcessInfo.processInfo.systemUptime
    Thread.sleep(forTimeInterval: 3)
    let currentCPU = cpuTicks()
    let now = ProcessInfo.processInfo.systemUptime
    model.update(cpu: previousCPU.flatMap { old in currentCPU.flatMap { cpuLoad(old, $0) } }, memory: memoryUsage(),
                 rates: previousNetwork.flatMap { old in networkCounters().flatMap { networkRate(old, $0, seconds: now - before) } })
    model.processes = rankedProcesses(before: previousProcesses, after: processSamples(), seconds: now - before)
    model.sampled = true
    model.refreshContext()
    for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        for (page, order, suffix) in [(DashboardPage.overview, ProcessOrder.cpu, "overview"), (.processes, .cpu, "cpu"), (.processes, .memory, "memory"), (.storage, .cpu, "storage"), (.settings, .cpu, "settings")] {
            model.page = page
            model.order = order
            let content = DashboardView(model: model, renderOnly: true).environment(\.colorScheme, scheme)
                .background(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(red: 0.11, green: 0.12, blue: 0.14), Color(red: 0.09, green: 0.10, blue: 0.12)]
                            : [Color(red: 0.96, green: 0.97, blue: 0.98), Color(red: 0.93, green: 0.94, blue: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let target = directory.appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: target)
            print("Rendered content: \(target.path)")
        }
    }
}
