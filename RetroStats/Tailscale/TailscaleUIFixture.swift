import AppKit
import SwiftUI

/// Explicit developer fixture; skips the production delegate, login items and notifications.
@MainActor func showTailscaleUIFixture() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let controller = TailscaleController.preview()
    let session = MobileSetupSession.preview(snapshot: controller.snapshot, services: controller.services, language: .system)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "RetroStats · Tailscale Fixture"
    window.minSize = NSSize(width: 360, height: 560)
    window.isReleasedWhenClosed = false
    let delegate = TailscaleFixtureWindowDelegate()
    window.delegate = delegate
    window.contentView = NSHostingView(rootView: TailscaleUIFixture(controller: controller, session: session, close: { window.close() }))
    window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    print("Tailscale UI fixture PID: \(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    withExtendedLifetime((window, delegate)) { app.run() }
}
@MainActor private final class TailscaleFixtureWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}
private struct TailscaleUIFixture: View {
    @ObservedObject var controller: TailscaleController
    @ObservedObject var session: MobileSetupSession
    var close: () -> Void
    @State private var mobile = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DEVELOPMENT FIXTURE").font(.caption)
                Spacer()
                Picker("Surface", selection: $mobile) { Text("Manage").tag(false); Text("Mobile helper").tag(true) }.pickerStyle(.segmented).frame(width: 250)
            }.padding(12)
            if mobile { MobileSetupView(controller: controller, session: session, onClose: close) }
            else { TailscaleAdvancedView(controller: controller, onClose: close) }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
