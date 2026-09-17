import AppKit

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
