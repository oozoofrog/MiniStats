import AppKit
import SwiftUI

/// Runs the production cleanup UI/controller against a unique synthetic home on eyedisk.
/// No production delegate, notifications, login item, live processes or user caches.
@MainActor func showCleanupUIFixture(directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let base = AutoCleanupEngine.canonicalPath(directory.path), base.hasPrefix("/Volumes/eyedisk/") else { throw CocoaError(.fileWriteNoPermission) }
    let home = base + "/fixture-home-" + UUID().uuidString
    let root = CleanupRoot(path: home + "/Library/Caches/pip", category: .developerCaches, owners: ["FixturePython"])
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    try Data(repeating: 41, count: 16384).write(to: URL(fileURLWithPath: root.path + "/download-cache.bin"))
    let suite = "RetroStats.CleanupUI." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let model = DashboardModel(defaults: defaults, tailscale: .preview())
    model.page = .storage
    let cleanup = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/evidence"), allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { Date().addingTimeInterval(90 * 86400) },
        changed: { [weak model] in model?.objectWillChange.send() })
    model.storage = StorageController(changed: { [weak model] in model?.objectWillChange.send() }, openMenu: {}, startServices: false, autoCleanup: cleanup)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "RetroStats · Cleanup Fixture (synthetic files only)"
    window.minSize = NSSize(width: 380, height: 520)
    window.isReleasedWhenClosed = false
    let delegate = CleanupFixtureWindowDelegate()
    window.delegate = delegate
    window.contentView = NSHostingView(rootView: DashboardView(model: model, renderOnly: false))
    window.center(); window.makeKeyAndOrderFront(nil)
    // Foreground activation is explicit in the native verification tool, after screen coordination.
    print("Cleanup fixture home: " + home)
    fflush(stdout)
    withExtendedLifetime((window, delegate, model)) { app.run() }
    cleanup.stop()
    defaults.removePersistentDomain(forName: suite)
}

@MainActor private final class CleanupFixtureWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}
