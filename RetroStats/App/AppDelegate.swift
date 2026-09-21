import AppKit
import Darwin
import ServiceManagement
import SwiftUI

/// Two-line CPU/MEM readout. "100%" does not fit the 26pt column, so a full
/// value shows the PixelMax icon instead of a number.
private struct BitmapStatusText: View {
    let cpu: Double?
    let memory: Double?

    var body: some View {
        VStack(spacing: 1) {
            row(cpu)
            row(memory)
        }
        .font(.bitmap(9, scaled: false))
        .frame(width: 26)
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
    }

    @ViewBuilder private func row(_ value: Double?) -> some View {
        if let value, value.rounded() >= 100 { PixelMax(size: 9) }
        else { Text(value.map { String(format: "%.0f%%", $0) } ?? "—") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let dashboard = DashboardModel()
    private let popover = TransparentPopover()
    private var dashboardWindow: NSWindow?
    private let status = NSStatusBar.system.statusItem(withLength: 38)
    private let readout = NSHostingView(rootView: BitmapStatusText(cpu: nil, memory: nil))
    private let warningIcon = NSImageView()
    private var timer: Timer?
    private var storage: StorageController?
    private var previousCPU = cpuTicks()
    private var previousNetwork = networkCounters()
    private var previousTime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.autosaveName = "RetroStats"
        readout.setAccessibilityElement(false)
        warningIcon.setAccessibilityElement(false)
        if let button = status.button {
            let content = StatusReadout(views: [warningIcon, readout])
            content.orientation = .horizontal
            content.alignment = .centerY
            content.spacing = 6
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                readout.widthAnchor.constraint(equalToConstant: 26),
                warningIcon.widthAnchor.constraint(equalToConstant: 16),
                warningIcon.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        status.button?.setAccessibilityLabel("RetroStats system monitor")
        storage = StorageController(changed: { [weak self] in self?.updateStorageWarning() }, openMenu: { [weak self] in self?.showStorageMenu() })
        dashboard.storage = storage
        dashboard.toggleLogin = { [weak self] in self?.toggleLogin() }
        dashboard.quit = { [weak self] in self?.quitApp() }
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView(model: dashboard) { [weak self] page, order in
            self?.openDashboard(page: page, order: order)
        })
        popover.contentSize = RetroLayout.popoverSize
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        status.button?.target = self
        status.button?.action = #selector(toggleDashboard)
        installMainMenu()

        updateStorageWarning()
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginConfigured")
            } catch { showError(error) }
        }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if CommandLine.arguments.contains("--show-dashboard") || CommandLine.arguments.contains("--show-storage") {
            DispatchQueue.main.async { self.openDashboard(page: CommandLine.arguments.contains("--show-storage") ? .storage : .overview) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func refresh() {
        let currentCPU = cpuTicks()
        let cpu = previousCPU.flatMap { old in currentCPU.flatMap { cpuLoad(old, $0) } }
        previousCPU = currentCPU
        let memory = memoryUsage()
        readout.rootView = BitmapStatusText(cpu: cpu?.total, memory: memory?.percent)
        let now = ProcessInfo.processInfo.systemUptime
        let currentNetwork = networkCounters()
        let rates = previousNetwork.flatMap { old in currentNetwork.flatMap { networkRate(old, $0, seconds: now - previousTime) } }
        previousNetwork = currentNetwork
        previousTime = now
        dashboard.update(cpu: cpu, memory: memory, rates: rates)
        updateStorageWarning()
    }

    private func updateStorageWarning() {
        dashboard.objectWillChange.send()
        guard let storage else { return }
        let warning = storage.disk?.warning == true
        status.length = warning ? 60 : 38
        warningIcon.isHidden = !warning
        warningIcon.image = warning ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Storage usage at or above 50%") : nil
        warningIcon.image?.isTemplate = true
        let cpuLabel = dashboard.cpu.map { String(format: "CPU %.0f%%", $0.total) } ?? "CPU measuring…"
        let memoryLabel = dashboard.memory.map { "Memory \(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Memory read failed"
        let diskLabel = storage.disk?.description ?? "Storage read failed"
        status.button?.toolTip = [cpuLabel, memoryLabel, "↓ \(dashboard.download)  ↑ \(dashboard.upload)", diskLabel].joined(separator: "\n")
        status.button?.setAccessibilityValue([cpuLabel, memoryLabel, diskLabel].joined(separator: ", "))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CommandLine.arguments.contains("--show-storage") { showStorageMenu() }
        else { openDashboard(page: dashboard.page) }
        return true
    }

    @objc private func toggleDashboard() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = status.button else { return }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        self.storage?.checkDisk()
    }

    func popoverDidShow(_ notification: Notification) { dashboard.setPresented(.popover, true) }

    func popoverDidClose(_ notification: Notification) { dashboard.setPresented(.popover, false) }

    private func showStorageMenu() { openDashboard(page: .storage) }

    private func openDashboard(page: DashboardPage, order: ProcessOrder? = nil) {
        if let order { dashboard.order = order }
        dashboard.page = page
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: RetroLayout.dashboardSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "RetroStats"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = RetroLayout.dashboardMinimum
            window.contentViewController = DashboardSurfaceController(model: dashboard)
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("RetroStatsDashboard")
            dashboardWindow = window
        }
        // Register the destination before closing the source so sampling stays live.
        dashboard.setPresented(.window, true)
        dashboard.refreshContext()
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.deminiaturize(nil)
        dashboardWindow?.makeKeyAndOrderFront(nil)
        popover.performClose(nil)
        storage?.checkDisk()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboardWindow else { return }
        dashboard.setPresented(.window, false)
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RetroStats", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func didWake() {
        dashboard.resumeIfPresented()
        previousCPU = cpuTicks()
        previousNetwork = networkCounters()
        previousTime = ProcessInfo.processInfo.systemUptime
        storage?.checkDisk()
    }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not configure automatic launch"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        storage?.cleaning == true ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { storage?.stop() }
}

let appID = "local.jay.RetroStats"
let totalMemory = ProcessInfo.processInfo.physicalMemory
let hostPort = mach_host_self()

let machTimebase: Double = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

func diagnostic(_ message: String) {
    guard let index = CommandLine.arguments.firstIndex(of: "--diagnostics-output"), CommandLine.arguments.count > index + 1 else { return }
    let path = CommandLine.arguments[index + 1]
    let data = Data((message + "\n").utf8)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
}

final class StatusReadout: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if DEBUG
#Preview("Menu Bar Readout") {
    HStack(spacing: 24) {
        BitmapStatusText(cpu: nil, memory: nil)
        BitmapStatusText(cpu: 7, memory: 43)
        BitmapStatusText(cpu: 99.6, memory: 62)
        BitmapStatusText(cpu: 100, memory: 100)
    }
    .padding(12)
    .frame(height: 22)
}
#endif
