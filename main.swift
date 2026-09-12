import AppKit
import Darwin
import IOKit.ps
import ServiceManagement

func diagnostic(_ message: String) {
    guard let index = CommandLine.arguments.firstIndex(of: "--diagnostics-output"), CommandLine.arguments.count > index + 1 else { return }
    let path = CommandLine.arguments[index + 1]
    let data = Data((message + "\n").utf8)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
}

let appID = "local.jay.MiniStats"
let totalMemory = ProcessInfo.processInfo.physicalMemory
let hostPort = mach_host_self()

func cpuTicks() -> [UInt32]? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
}

struct CPULoad {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

func cpuLoad(_ before: [UInt32], _ after: [UInt32]) -> CPULoad? {
    guard before.count == 4, after.count == 4 else { return nil }
    let delta = zip(after, before).map { Double($0 &- $1) }
    let total = delta.reduce(0, +)
    guard total > 0 else { return nil }
    return CPULoad(user: 100 * (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total,
                   system: 100 * delta[Int(CPU_STATE_SYSTEM)] / total)
}

func loadAverageText() -> String {
    var load = [Double](repeating: 0, count: 3)
    guard getloadavg(&load, 3) == 3 else { return "로드 평균: 읽기 실패" }
    return String(format: "로드 평균: %.1f · %.1f · %.1f (1·5·15분, %d코어)", load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount)
}

struct MemoryUsage {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    var used: UInt64 { min(totalMemory, app + wired + compressed) }
    var percent: Double { 100 * Double(used) / Double(totalMemory) }
}

func memoryUsage() -> MemoryUsage? {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)
    let appPages = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
    return MemoryUsage(app: appPages * page, wired: UInt64(info.wire_count) * page, compressed: UInt64(info.compressor_page_count) * page)
}

func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let result = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
    guard result == 0, size == MemoryLayout<T>.size else { return nil }
    return value
}

func swapText() -> String {
    guard let swap = sysctlValue("vm.swapusage", xsw_usage()) else { return "스왑: 읽기 실패" }
    return swap.xsu_total == 0 ? "스왑: 사용 안 함" : "스왑: \(bytes(swap.xsu_used)) / \(bytes(swap.xsu_total))"
}

func memoryPressureText() -> String {
    switch sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) {
    case 1: return "메모리 압력: 정상"
    case 2: return "메모리 압력: 경고"
    case 4: return "메모리 압력: 위험"
    case let level?: return "메모리 압력: 알 수 없음 (\(level))"
    case nil: return "메모리 압력: 읽기 실패"
    }
}

struct ProcessSample {
    let name: String
    let start: UInt64
    let cpuTime: UInt64 // nanoseconds
    let memory: UInt64 // phys_footprint, Activity Monitor's "Memory" column
}

let machTimebase: Double = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

func processSamples() -> [pid_t: ProcessSample] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let listError = errno
    var usageErrors: [Int32: Int] = [:]
    var nameErrors: [Int32: Int] = [:]
    var name = [CChar](repeating: 0, count: 64)
    var result: [pid_t: ProcessSample] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
        var info = rusage_info_v4()
        // Processes of other users (root daemons, WindowServer, kernel_task) return EPERM and are left out.
        // libproc declares the buffer as `rusage_info_t *` (void **) even though it expects the struct itself.
        let usageResult = withUnsafeMutablePointer(to: &info, { proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) })
        guard usageResult == 0 else { usageErrors[errno, default: 0] += 1; continue }
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { nameErrors[errno, default: 0] += 1; continue }
        result[pid] = ProcessSample(name: String(cString: name), start: info.ri_proc_start_abstime,
                                    cpuTime: UInt64(Double(info.ri_user_time + info.ri_system_time) * machTimebase), memory: info.ri_phys_footprint)
    }
    diagnostic("Processes: uid=\(getuid()) listed=\(count) listErr=\(listError) readable=\(result.count) rusageErrors=\(usageErrors) nameErrors=\(nameErrors)")
    return result
}

func topCPU(_ before: [pid_t: ProcessSample], _ after: [pid_t: ProcessSample], seconds: Double) -> [(name: String, percent: Double)] {
    guard seconds > 0 else { return [] }
    return after.compactMap { pid, current -> (name: String, percent: Double)? in
        guard let old = before[pid], old.start == current.start, current.cpuTime >= old.cpuTime else { return nil }
        return (current.name, 100 * Double(current.cpuTime - old.cpuTime) / 1e9 / seconds)
    }.sorted { $0.percent > $1.percent }.prefix(5).map { $0 }
}

func topMemory(_ samples: [pid_t: ProcessSample]) -> [(name: String, memory: UInt64)] {
    samples.values.sorted { $0.memory > $1.memory }.prefix(5).map { ($0.name, $0.memory) }
}

struct Traffic {
    let received: UInt64
    let sent: UInt64
}

func networkCounters() -> [String: Traffic]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
    guard read == 0 else { return nil }
    data.count = size
    return parseNetwork(data)
}

func parseNetwork(_ data: Data) -> [String: Traffic]? {
    var result: [String: Traffic] = [:]
    return data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            guard raw.count - offset >= 4 else { return nil }
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length >= 4, length <= raw.count - offset else { return nil }
            defer { offset += length }
            guard raw[offset + 3] == RTM_IFINFO2 else { continue }
            guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
            let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            guard info.ifm_flags & IFF_UP != 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
            let name = String(cString: nameBuffer)
            // ponytail: physical en* interfaces avoid counting VPN/bridge traffic twice; add other hardware prefixes if needed.
            guard name.hasPrefix("en") else { continue }
            result[name] = Traffic(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
        }
        return result
    }
}

func networkRate(_ before: [String: Traffic], _ after: [String: Traffic], seconds: Double) -> (Double, Double)? {
    guard seconds > 0, seconds.isFinite else { return nil }
    var received = 0.0
    var sent = 0.0
    for (name, current) in after {
        guard let old = before[name], current.received >= old.received, current.sent >= old.sent else { continue }
        received += Double(current.received - old.received) / seconds
        sent += Double(current.sent - old.sent) / seconds
    }
    return (received, sent)
}

func bytes(_ value: UInt64) -> String {
    value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

func speed(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    if value >= 1_048_576 { return String(format: "%.1f MiB/s", value / 1_048_576) }
    return String(format: "%.0f KiB/s", value / 1024)
}

func batteryText() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "배터리: 읽기 실패" }
    for source in sources {
        guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let capacity = values[kIOPSCurrentCapacityKey] as? Int,
              let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = values[kIOPSIsChargingKey] as? Bool == true
        return "배터리: \(capacity * 100 / maximum)% · \(charging ? "충전 중" : pluggedIn ? "전원 연결" : "배터리 사용")"
    }
    return "배터리: 없음"
}

final class StatusReadout: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let dashboard = DashboardModel()
    private let popover = NSPopover()
    private let status = NSStatusBar.system.statusItem(withLength: 38)
    private let readout = NSTextField(labelWithString: "—\n—")
    private let warningIcon = NSImageView()
    private var timer: Timer?
    private var storage: StorageController?
    private var previousCPU = cpuTicks()
    private var previousNetwork = networkCounters()
    private var previousTime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.autosaveName = "MiniStats"
        readout.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        readout.alignment = .center
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
        status.button?.setAccessibilityLabel("MiniStats 시스템 모니터")
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
        readout.stringValue = "\(cpuLabel)\n\(memoryLabel)"
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
        warningIcon.image = warning ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "스토리지 50% 이상 사용 경고")?.withSymbolConfiguration(.init(paletteColors: [.black, .systemOrange])) : nil
        warningIcon.image?.isTemplate = false
        let cpuLabel = dashboard.cpu.map { String(format: "CPU %.0f%%", $0.total) } ?? "CPU 측정 중"
        let memoryLabel = dashboard.memory.map { "메모리 \(bytes($0.used)) / \(bytes(totalMemory))" } ?? "메모리 읽기 실패"
        let diskLabel = storage.disk?.description ?? "스토리지 읽기 실패"
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
            popover.contentViewController?.view.window?.makeKey()
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
        alert.messageText = "자동 실행을 설정하지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        storage?.cleaning == true ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { storage?.stop() }
}

func selfTest() {
    precondition(cpuLoad([0, 0, 0, 0], [20, 10, 70, 0])?.total == 30)
    precondition(cpuLoad([0, 0, 0, 0], [20, 10, 70, 0])?.system == 10)
    precondition(cpuLoad([1, 1, 1, 1], [1, 1, 1, 1]) == nil)
    precondition(cpuLoad([UInt32.max, 0, 0, 0], [0, 0, 1, 0])?.user == 50)
    precondition(cpuLoad([], []) == nil)
    let idle = ProcessSample(name: "idle", start: 1, cpuTime: 0, memory: 10)
    let busy = ProcessSample(name: "idle", start: 1, cpuTime: 1_500_000_000, memory: 10)
    let old = ProcessSample(name: "old", start: 2, cpuTime: 100, memory: 20)
    let reused = ProcessSample(name: "new", start: 3, cpuTime: 5_000_000_000, memory: 5)
    let ranked = topCPU([1: idle, 2: old], [1: busy, 2: reused], seconds: 3)
    precondition(ranked.count == 1 && ranked[0].name == "idle" && ranked[0].percent == 50)
    precondition(topCPU([1: idle], [1: busy], seconds: 0).isEmpty)
    precondition(topMemory([1: busy, 2: reused]).map(\.name) == ["idle", "new"])
    let processes = processSamples()
    precondition((processes[getpid()]?.memory ?? 0) > 0)
    precondition(sysctlValue("vm.swapusage", xsw_usage()) != nil)
    precondition([1, 2, 4].contains(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) ?? 0))
    let before = ["en0": Traffic(received: 100, sent: 200)]
    let after = ["en0": Traffic(received: 1124, sent: 2248), "en1": Traffic(received: 99999, sent: 99999)]
    let rate = networkRate(before, after, seconds: 2)!
    precondition(rate.0 == 512 && rate.1 == 1024)
    precondition(networkRate(before, after, seconds: 0) == nil)
    let reset = networkRate(before, ["en0": Traffic(received: 0, sent: 0)], seconds: 1)!
    precondition(reset.0 == 0 && reset.1 == 0)
    let large = networkRate(["en0": Traffic(received: 0, sent: 0)], ["en0": Traffic(received: 5_000_000_000, sent: 0)], seconds: 1)!
    precondition(large.0 == 5_000_000_000)
    precondition(parseNetwork(Data([0, 0, 0, 0])) == nil)
    precondition(parseNetwork(Data([8, 0, 0, 0])) == nil)
    precondition(parseNetwork(Data([4, 0, 0, UInt8(RTM_IFINFO2)])) == nil)
    precondition(parseNetwork(Data([4, 0, 0, 0]))?.isEmpty == true)
    precondition(speed(1_048_576) == "1.0 MiB/s")
    precondition(cpuTicks()?.count == 4)
    guard let memory = memoryUsage(), memory.used > 0, memory.used <= totalMemory,
          let network = networkCounters() else { fatalError("Live metric read failed") }
    let ticks = cpuTicks()!
    Thread.sleep(forTimeInterval: 3)
    guard let cpu = cpuLoad(ticks, cpuTicks()!), (0...100).contains(cpu.total) else { fatalError("Live CPU delta failed") }
    let live = topCPU(processes, processSamples(), seconds: 3)
    precondition(live.allSatisfy { $0.percent >= 0 && $0.percent <= 100 * Double(ProcessInfo.processInfo.activeProcessorCount) })
    print("PASS: CPU math/wraparound, memory bounds, network parser/rates/reset/64-bit counters, process ranking/pid reuse, sysctl reads, formatting, live sampling")
    print("CPU \(String(format: "%.1f", cpu.total))% · Memory \(bytes(memory.used))/\(bytes(totalMemory)) · \(swapText()) · \(memoryPressureText()) · \(loadAverageText()) · Interfaces \(network.keys.sorted()) · \(batteryText())")
    print("Processes \(processes.count) · top CPU \(live.map { "\($0.name) \(String(format: "%.1f", $0.percent))%" }) · top memory \(topMemory(processes).map { "\($0.name) \(bytes($0.memory))" })")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
    try storageSelfTest()
    dashboardSelfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--render-dashboard"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try renderDashboard(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if CommandLine.arguments.contains("--notification-status") {
    printNotificationStatus()
} else {
    let app = NSApplication.shared
    guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else { exit(0) }
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
