import AppKit
import ServiceManagement
import SwiftUI

private struct BitmapStatusText: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.bitmap(9))
            .multilineTextAlignment(.center)
            .frame(width: 26)
            .textRenderer(BitmapTextRenderer())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let dashboard = DashboardModel()
    private let popover = TransparentPopover()
    private let status = NSStatusBar.system.statusItem(withLength: 38)
    private let readout = NSHostingView(rootView: BitmapStatusText(value: "—\n—"))
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
        popover.contentViewController = DashboardSurfaceController(model: dashboard)
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        status.button?.target = self
        status.button?.action = #selector(toggleDashboard)

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
            DispatchQueue.main.async { self.showDashboard(storage: CommandLine.arguments.contains("--show-storage")) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func refresh() {
        let currentCPU = cpuTicks()
        let cpu = previousCPU.flatMap { old in currentCPU.flatMap { cpuLoad(old, $0) } }
        previousCPU = currentCPU
        let memory = memoryUsage()
        let cpuLabel = cpu.map { String(format: "%.0f%%", $0.total) } ?? "—"
        let memoryLabel = memory.map { String(format: "%.0f%%", $0.percent) } ?? "—"
        readout.rootView = BitmapStatusText(value: "\(cpuLabel)\n\(memoryLabel)")
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
        warningIcon.image = warning ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Storage usage at or above 50%")?.withSymbolConfiguration(.init(paletteColors: [.black, .systemOrange])) : nil
        warningIcon.image?.isTemplate = false
        let cpuLabel = dashboard.cpu.map { String(format: "CPU %.0f%%", $0.total) } ?? "CPU measuring…"
        let memoryLabel = dashboard.memory.map { "Memory \(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Memory read failed"
        let diskLabel = storage.disk?.description ?? "Storage read failed"
        status.button?.toolTip = [cpuLabel, memoryLabel, "↓ \(dashboard.download)  ↑ \(dashboard.upload)", diskLabel].joined(separator: "\n")
        status.button?.setAccessibilityValue([cpuLabel, memoryLabel, diskLabel].joined(separator: ", "))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CommandLine.arguments.contains("--show-storage") { showStorageMenu() }
        else { status.button?.performClick(nil) }
        return true
    }

    @objc private func toggleDashboard() {
        if popover.isShown { popover.performClose(nil) }
        else { showDashboard(storage: false) }
    }

    private func showDashboard(storage: Bool) {
        guard let button = status.button else { return }
        if storage { dashboard.page = .storage }
        else { dashboard.page = .overview }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        self.storage?.checkDisk()
    }

    func popoverDidShow(_ notification: Notification) { dashboard.begin() }

    func popoverDidClose(_ notification: Notification) { dashboard.end() }

    private func showStorageMenu() { showDashboard(storage: true) }

    @objc private func didWake() {
        if popover.isShown { dashboard.begin() }
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
