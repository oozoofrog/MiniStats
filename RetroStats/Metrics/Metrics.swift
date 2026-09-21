import AppKit
import Foundation
import IOKit.ps

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
    guard getloadavg(&load, 3) == 3 else { return "Load average: read failed" }
    return String(format: "Load average: %.1f · %.1f · %.1f (1·5·15 min, %d cores)", load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount)
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
    guard let swap = sysctlValue("vm.swapusage", xsw_usage()) else { return "Swap: read failed" }
    return swap.xsu_total == 0 ? "Swap: not in use" : "Swap: \(bytes(swap.xsu_used)) / \(bytes(swap.xsu_total))"
}

func memoryPressureText() -> String {
    switch sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) {
    case 1: return "Memory pressure: normal"
    case 2: return "Memory pressure: warning"
    case 4: return "Memory pressure: critical"
    case let level?: return "Memory pressure: unknown (\(level))"
    case nil: return "Memory pressure: read failed"
    }
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

func batteryText() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "Battery: read failed" }
    for source in sources {
        guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let capacity = values[kIOPSCurrentCapacityKey] as? Int,
              let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = values[kIOPSIsChargingKey] as? Bool == true
        return "Battery: \(capacity * 100 / maximum)% · \(charging ? "Charging" : pluggedIn ? "Plugged in" : "On battery")"
    }
    return "Battery: none"
}

struct DiskUsage {
    let total: UInt64
    let free: UInt64
    let name: String
    /// Finder's "available" figure: free space plus purgeable data. The 50% warning stays on `free`.
    let available: UInt64?
    var percent: Double { 100 * Double(total - free) / Double(total) }
    var warning: Bool { percent >= 50 }
    var purgeable: UInt64 { available.map { $0 > free ? $0 - free : 0 } ?? 0 }
    var description: String { String(format: "%@ %.1f%% used · free %@ / %@", name, percent, bytes(free), bytes(total)) }
    var detail: String? { available.map { "Available according to Finder \(bytes($0)) · reclaimable \(bytes(purgeable))" } }

    init?(total: UInt64, free: UInt64, name: String = "Storage", available: UInt64? = nil) {
        guard total > 0, free <= total else { return nil }
        self.total = total
        self.free = free
        self.name = name
        self.available = available
    }

    static func read() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0, free >= 0 else { return nil }
        return DiskUsage(total: UInt64(total), free: UInt64(free), name: values.volumeName ?? "Storage",
                         available: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) })
    }
}

func bytes(_ value: UInt64) -> String {
    value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

func speed(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    if value >= 1_048_576 { return String(format: "%.1f MiB/s", value / 1_048_576) }
    return String(format: "%.0f KiB/s", value / 1024)
}

func englishDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
