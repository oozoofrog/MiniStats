import AppKit
import SwiftUI

/// Content rendering for layout inspection; does not test native window chrome or mouse interaction.
/// Reads live metrics and the cached storage report without login registration, notifications, scans or deletion.
@MainActor func renderDashboard(to directory: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = DashboardModel(tailscale: .preview())
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
        for (width, layout) in [(CGFloat(360), "minimum"), (CGFloat(400), "compact"), (CGFloat(840), "wide")] {
            for (page, suffix) in [(DashboardPage.overview, "overview"), (.cpu, "cpu"), (.memory, "memory"), (.network, "network"), (.storage, "storage"), (.settings, "settings")] {
                model.page = page
                let height: CGFloat = width < RetroLayout.sidebarBreakpoint
                    ? (page == .overview ? 760 : 1260)
                    : (page == .overview || page == .network ? 860 : 1040)
                let content = DashboardView(model: model, renderOnly: true)
                    .frame(width: width, height: height)
                    .environment(\.colorScheme, scheme)
                try render(content, to: directory.appendingPathComponent("\(name)-\(layout)-\(suffix).png"))
            }
        }
    }
    try renderTailscaleFixtures(to: directory.appendingPathComponent("tailscale-fixtures"))
}

@MainActor private func render<Content: View>(_ content: Content, to target: URL) throws {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: target)
    print("Rendered content: \(target.path)")
}

/// Every object here is inert: no command, API request or listener is started.
@MainActor private func renderTailscaleFixtures(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let controller = TailscaleController.preview()
    let originalScale = FontScale.current
    defer { FontScale.current = originalScale }
    for language in [SetupLanguage.en] {
        let session = MobileSetupSession.preview(snapshot: controller.snapshot, services: controller.services, language: language)
        try MacAccessPage.setup(language: .en, account: controller.snapshot.account, accessURL: controller.access.url).write(to: directory.appendingPathComponent("mobile-setup-en.html"), atomically: true, encoding: .utf8)
        try MacAccessPage.hub(language: .en, host: "100.64.0.1", services: controller.access.services).write(to: directory.appendingPathComponent("my-mac-en.html"), atomically: true, encoding: .utf8)
        try MacAccessPage.hub(language: .en, host: "100.64.0.1", services: []).write(to: directory.appendingPathComponent("my-mac-empty-en.html"), atomically: true, encoding: .utf8)
        try MacAccessPage.unverified.write(to: directory.appendingPathComponent("my-mac-unverified-en.html"), atomically: true, encoding: .utf8)
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            for (width, layout) in [(CGFloat(360), "minimum"), (CGFloat(400), "compact"), (CGFloat(840), "wide")] {
                let view = MobileSetupView(controller: controller, session: session).frame(width: width, height: 1000).environment(\.colorScheme, scheme)
                try renderNative(view, scheme: scheme, size: CGSize(width: width, height: 1000), to: directory.appendingPathComponent("mobile-\(language == .ko ? "ko" : "en")-\(name)-\(layout).png"))
            }
        }
    }
    for scale in [FontScale.normal, .large] {
        FontScale.current = scale
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            for (width, layout) in [(CGFloat(360), "minimum"), (CGFloat(400), "compact"), (CGFloat(840), "wide")] {
                let palette = RetroPalette(finish: .ivory, scheme: scheme)
                let view = TailscalePanel(controller: controller, renderOnly: true).padding(20).frame(width: width, height: 760, alignment: .topLeading)
                    .environment(\.retroPalette, palette).environment(\.colorScheme, scheme).background(palette.paper).foregroundStyle(palette.ink).textRenderer(BitmapTextRenderer())
                try render(view, to: directory.appendingPathComponent("panel-\(scale.rawValue)-\(name)-\(layout).png"))
            }
        }
    }
    FontScale.current = originalScale
    for state in [TailscaleConnection.notInstalled, .signedOut, .extensionApproval, .deviceApproval, .connecting, .disconnected, .uncontrollable, .error] {
        let view = TailscalePanel(controller: .preview(state: state), renderOnly: true).padding(20).frame(width: 400, height: 760, alignment: .topLeading).environment(\.colorScheme, .light)
        try render(view, to: directory.appendingPathComponent("state-\(state.rawValue.replacingOccurrences(of: "/", with: "-")).png"))
    }
    for (width, name) in [(CGFloat(360), "minimum"), (CGFloat(680), "wide")] {
        let view = TailscaleAdvancedView(controller: controller).frame(width: width, height: 1000).environment(\.colorScheme, .light)
        try renderNative(view, scheme: .light, size: CGSize(width: width, height: 1000), to: directory.appendingPathComponent("manage-light-\(name).png"))
    }
}

/// Native ScrollView/TextEditor/Picker need an AppKit host; ImageRenderer omits them.
/// The window is never ordered on screen and has no app delegate or service startup.
@MainActor private func renderNative<Content: View>(_ content: Content, scheme: ColorScheme, size: CGSize, to target: URL) throws {
    let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = view; view.frame = CGRect(origin: .zero, size: size)
    window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: target)
    window.close()
    print("Rendered native fixture: \(target.path)")
}
