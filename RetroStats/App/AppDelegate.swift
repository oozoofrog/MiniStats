import AppKit
import Darwin
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let dashboard = DashboardModel()
    private var dashboardWindow: NSWindow?
    private let status = NSStatusBar.system.statusItem(withLength: 38)
    private let readout = StatusReadout()
    private var timer: Timer?
    private var storage: StorageController?
    private var previousCPU = cpuTicks()
    private var previousNetwork = networkCounters()
    private var previousTime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.autosaveName = "RetroStats"
        readout.setAccessibilityElement(false)
        if let button = status.button {
            readout.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(readout)
            NSLayoutConstraint.activate([
                readout.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                readout.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                readout.topAnchor.constraint(equalTo: button.topAnchor),
                readout.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
        status.button?.setAccessibilityLabel("RetroStats system monitor")
        storage = StorageController(changed: { [weak self] in self?.updateStatusReadout() }, openMenu: { [weak self] in self?.showStorageMenu() })
        dashboard.storage = storage
        dashboard.toggleLogin = { [weak self] in self?.toggleLogin() }
        dashboard.quit = { [weak self] in self?.quitApp() }
        status.button?.target = self
        status.button?.action = #selector(toggleDashboard)
        installMainMenu()

        updateStatusReadout()
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginConfigured")
            } catch { showError(error) }
        }
        refresh()
        dashboard.updateIntervalChanged = { [weak self] interval in self?.scheduleRefresh(every: interval) }
        scheduleRefresh(every: dashboard.updateInterval)
        if CommandLine.arguments.contains("--show-dashboard") || CommandLine.arguments.contains("--show-storage") {
            DispatchQueue.main.async { self.openDashboard(page: CommandLine.arguments.contains("--show-storage") ? .storage : .overview) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func scheduleRefresh(every interval: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = min(0.1, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let currentCPU = cpuTicks()
        let cpu = previousCPU.flatMap { old in currentCPU.flatMap { cpuLoad(old, $0) } }
        previousCPU = currentCPU
        let memory = memoryUsage()
        let now = ProcessInfo.processInfo.systemUptime
        let currentNetwork = networkCounters()
        let rates = previousNetwork.flatMap { old in currentNetwork.flatMap { networkRate(old, $0, seconds: now - previousTime) } }
        previousNetwork = currentNetwork
        previousTime = now
        dashboard.update(cpu: cpu, memory: memory, rates: rates)
        updateStatusReadout()
    }

    private func updateStatusReadout() {
        dashboard.objectWillChange.send()
        readout.update(cpu: dashboard.cpu?.total, memory: dashboard.memory?.percent, storagePercent: storage?.disk?.percent)
        let cpuLabel = dashboard.cpu.map { String(format: "CPU %.0f%%", $0.total) } ?? "CPU measuring…"
        let memoryLabel = dashboard.memory.map { "Memory \(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Memory read failed"
        let diskLabel = storage?.disk?.description ?? "Storage read failed"
        status.button?.toolTip = [cpuLabel, memoryLabel, "↓ \(dashboard.download)  ↑ \(dashboard.upload)", diskLabel].joined(separator: "\n")
        status.button?.setAccessibilityValue([cpuLabel, memoryLabel, diskLabel].joined(separator: ", "))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CommandLine.arguments.contains("--show-storage") { showStorageMenu() }
        else { openDashboard(page: dashboard.page) }
        return true
    }

    @objc private func toggleDashboard() {
        if let window = dashboardWindow, window.isVisible && !window.isMiniaturized {
            window.performClose(nil)
        } else {
            openDashboard(page: dashboard.page)
        }
    }

    private func showStorageMenu() { openDashboard(page: .storage) }

    private func openDashboard(page: DashboardPage) {
        dashboard.page = page
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: RetroLayout.compactSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "RetroStats"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = RetroLayout.dashboardMinimum
            window.contentViewController = DashboardSurfaceController(model: dashboard, toggleSize: { [weak self] in self?.toggleDashboardSize() })
            window.delegate = self
            window.center()
            if !window.setFrameUsingName("RetroStatsResponsiveDashboard"),
               let button = status.button, let statusWindow = button.window {
                let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
                let screen = statusWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
                let x = min(max(anchor.midX - window.frame.width / 2, screen.minX), screen.maxX - window.frame.width)
                let y = max(screen.minY, anchor.minY - window.frame.height - 6)
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            window.setFrameAutosaveName("RetroStatsResponsiveDashboard")
            dashboardWindow = window
        }
        dashboard.setPresented(true)
        dashboard.refreshContext()
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.deminiaturize(nil)
        dashboardWindow?.makeKeyAndOrderFront(nil)
        storage?.checkDisk()
    }

    private func toggleDashboardSize() {
        guard let window = dashboardWindow else { return }
        let compact = (window.contentView?.bounds.width ?? 0) < RetroLayout.sidebarBreakpoint
        let size = compact ? RetroLayout.dashboardSize : RetroLayout.compactSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboardWindow else { return }
        dashboard.setPresented(false)
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
