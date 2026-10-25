import AppKit
import Darwin
import ServiceManagement
import SwiftUI

/// System-service lifetime only. SwiftUI owns every production UI surface.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let dashboard: DashboardModel
    private let fixture = CommandLine.arguments.contains("--menu-ui-fixture")

    override init() {
        dashboard = CommandLine.arguments.contains("--menu-ui-fixture")
            ? MainActor.assumeIsolated { DashboardModel(tailscale: .preview()) } : DashboardModel()
        super.init()
    }
    @Published private(set) var dashboardRequest: UUID?
    private var timer: Timer?
    private var storage: StorageController?
    private var previousCPU = cpuTicks()
    private var previousNetwork = networkCounters()
    private var previousTime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostic("Application services starting (fixture: \(fixture))")
        storage = StorageController(changed: { [weak self] in self?.dashboard.objectWillChange.send() }, openMenu: { [weak self] in self?.requestDashboard(page: .storage) }, startServices: !fixture)
        dashboard.storage = storage
        if !fixture { dashboard.tailscale.restoreAccess() }
        dashboard.toggleLogin = { [weak self] in
            guard let self, !self.fixture else { return }
            self.toggleLogin()
        }
        dashboard.quit = { [weak self] in self?.quitApp() }
        if !fixture && !UserDefaults.standard.bool(forKey: "loginConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginConfigured")
            } catch { showError(error) }
        }
        refresh()
        dashboard.updateIntervalChanged = { [weak self] interval in self?.scheduleRefresh(every: interval) }
        scheduleRefresh(every: dashboard.updateInterval)
        if CommandLine.arguments.contains("--show-dashboard") || CommandLine.arguments.contains("--show-storage") {
            DispatchQueue.main.async { self.requestDashboard(page: CommandLine.arguments.contains("--show-storage") ? .storage : .overview) }
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestDashboard(page: dashboard.page)
        return true
    }

    func requestDashboard(page: DashboardPage) {
        diagnostic("Dashboard requested: \(page)")
        dashboard.page = page
        dashboardRequest = UUID()
    }

    func consumeDashboardRequest(_ request: UUID) {
        if dashboardRequest == request { dashboardRequest = nil }
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
        dashboard.loginError = error.localizedDescription
        requestDashboard(page: .settings)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        storage?.cleaning == true || storage?.autoCleanup.running == true ? .terminateCancel : .terminateNow
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
