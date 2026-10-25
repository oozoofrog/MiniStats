import AppKit
import SwiftUI

/// Read-only content evidence; fixture states are named explicitly in filenames.
@MainActor func renderMenuSummary(to directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = DashboardModel(tailscale: .preview())
    let originalScale = FontScale.current
    defer { FontScale.current = originalScale }
    let previous = cpuTicks()
    Thread.sleep(forTimeInterval: 0.2)
    for state in ["unavailable", "live"] {
        if state == "live" {
            model.storage = StorageController(changed: {}, openMenu: {}, startServices: false, volumeSnapshot: StorageVolumeCatalog.read())
            model.update(cpu: previous.flatMap { old in cpuTicks().flatMap { cpuLoad(old, $0) } }, memory: memoryUsage(), rates: nil)
        }
        for scale in [FontScale.normal, .large] {
            FontScale.current = scale
            for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                for (page, suffix) in [(nil as DashboardPage?, "summary"), (.cpu, "cpu"), (.memory, "memory"), (.network, "network"), (.storage, "storage"), (.settings, "settings")] {
                let renderer = ImageRenderer(content: MenuSummaryView(model: model, openDetail: { _ in }, renderOnly: true, selectedPage: page, showsVolumes: page == .storage)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                guard let cg = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let target = directory.appendingPathComponent("\(state)-\(name)-\(scale.rawValue)-\(suffix).png")
                try png.write(to: target)
                print("Rendered summary: \(target.path)")
                }
            }
        }
    }
}
