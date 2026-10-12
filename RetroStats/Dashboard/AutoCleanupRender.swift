import AppKit
import SwiftUI

/// Offscreen layout fixtures. No services, process queries, scans or deletions.
@MainActor func renderAutoCleanup(to directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "RetroStats.CleanupRender." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let originalScale = FontScale.current
    defer { defaults.removePersistentDomain(forName: suite); FontScale.current = originalScale }
    var settings = AutoCleanupSettings()
    settings.enabled = true
    settings.lastAttempt = Date()
    settings.exclusions = ["/Users/Example/Library/Caches/com.example.long-app-name/offline-cache"]
    defaults.set(try JSONEncoder().encode(settings), forKey: AutoCleanupController.settingsKey)
    let cleanup = AutoCleanupController(defaults: defaults, support: directory, allowOperations: false, changed: {})
    let model = DashboardModel(tailscale: .preview())
    model.storage = StorageController(changed: {}, openMenu: {}, startServices: false, autoCleanup: cleanup)
    for scale in [FontScale.normal, .large] {
        FontScale.current = scale
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            for width in [CGFloat(312), CGFloat(636)] {
                let palette = RetroPalette(finish: .ivory, scheme: scheme)
                let view = DashboardContentView(model: model, renderOnly: true).autoCleanupSection
                    .frame(width: width).padding(20)
                    .environment(\.retroPalette, palette).environment(\.colorScheme, scheme)
                    .foregroundStyle(palette.ink).background(palette.paper)
                    .font(.bitmap(13)).tracking(1).textRenderer(BitmapTextRenderer())
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let target = directory.appendingPathComponent("auto-cleanup-\(name)-\(scale.rawValue)-\(Int(width)).png")
                try data.write(to: target)
                print("Rendered cleanup fixture: \(target.path)")
            }
        }
    }
}
