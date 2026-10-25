import AppKit
import SwiftUI

enum PermissionGuideTarget: String {
    case fullDiskAccess, appManagement
    static let preferenceKey = "permissionGuideTarget"
    var label: String { self == .fullDiskAccess ? "Full Disk Access" : "App Management" }
    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" +
            (self == .fullDiskAccess ? "Privacy_AllFiles" : "Privacy_AppBundles"))!
    }
}

/// SwiftUI owns this window and the drag source. AppKit only positions it beside
/// the other application's public WindowServer bounds; no AX permission is needed.
struct PermissionGuideView: View {
    static let title = "RetroStats Permission Guide"
    @AppStorage(PermissionGuideTarget.preferenceKey) private var targetName = PermissionGuideTarget.fullDiskAccess.rawValue
    private var target: PermissionGuideTarget { PermissionGuideTarget(rawValue: targetName) ?? .fullDiskAccess }
    @StateObject private var attachment = PermissionGuideAttachment()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .padding(12)
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag RetroStats into the \(target.label) list, then enable it.")
            .accessibilityLabel("RetroStats application")
            .accessibilityHint("Drag into the \(target.label) application list. Enable access in System Settings.")
            .contextMenu {
                Button("Open \(target.label)") {
                    NSWorkspace.shared.open(target.settingsURL)
                }
                Button("Close Guide") { dismissWindow(id: "permission-guide") }
            }
            .onAppear { attachment.start() }

    }
}

@MainActor private final class PermissionGuideAttachment: ObservableObject {
    private var timer: Timer?
    private var guide: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window === self?.guide else { return }
                self?.stop()
            }
        }
        update()
    }

    func stop() {
        timer?.invalidate(); timer = nil; guide = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private func update() {
        if guide == nil { guide = NSApp.windows.first { $0.title == PermissionGuideView.title } }
        guard let guide else { return }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == settings.processIdentifier || front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let target = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == settings.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                  (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 300
              }),
              let bounds = target[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else {
            guide.orderOut(nil)
            return
        }
        let settingsRect = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(settingsRect).width < b.frame.intersection(settingsRect).width
        } ?? primary
        let visible = screen.visibleFrame
        let size = guide.frame.size
        let right = settingsRect.maxX + 10
        let x = right + size.width <= visible.maxX ? right : settingsRect.minX - size.width - 10
        let origin = CGPoint(x: max(visible.minX, min(x, visible.maxX - size.width)),
                             y: max(visible.minY, min(settingsRect.midY - size.height / 2, visible.maxY - size.height)))
        if guide.frame.origin != origin { guide.setFrameOrigin(origin) }
        if !guide.isVisible { guide.orderFront(nil) }
    }
}
