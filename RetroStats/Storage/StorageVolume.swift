import Foundation

/// A mounted volume is not a physical disk. Shared APFS space is never totalled.
struct StorageVolume: Identifiable, Equatable, Sendable {
    enum Location: String, CaseIterable, Sendable {
        case internalDrive = "Internal", external = "External", network = "Network", unknown = "Other"
    }
    struct Capacity: Equatable, Sendable {
        let total: UInt64
        let free: UInt64
        let available: UInt64?
        init?(total: Int64, free: Int64, available: Int64? = nil) {
            guard total > 0, free >= 0, free <= total else { return nil }
            self.total = UInt64(total)
            self.free = UInt64(free)
            self.available = available.flatMap { $0 >= 0 ? UInt64($0) : nil }
        }
        var used: UInt64 { total - free }
        var usedPercent: Double { Double(used) / Double(total) * 100 }
        var purgeable: UInt64? { available.map { $0 > free ? $0 - free : 0 } }
    }
    let id: String
    let name: String
    let path: String
    let location: Location
    let isMain: Bool
    let capacity: Capacity?
    let sharedContainerID: String?
    let measuredAt: Date
}

enum StorageVolumeCatalog {
    static func normalized(_ volumes: [StorageVolume]) -> [StorageVolume] {
        // Prefer the home-volume representation when a mount appears through aliases.
        var unique: [StorageVolume] = []
        for volume in volumes {
            if let index = unique.firstIndex(where: { $0.id == volume.id }) {
                if volume.isMain && !unique[index].isMain { unique[index] = volume }
            } else { unique.append(volume) }
        }
        return unique.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            let a = StorageVolume.Location.allCases.firstIndex(of: lhs.location)!
            let b = StorageVolume.Location.allCases.firstIndex(of: rhs.location)!
            if a != b { return a < b }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.path < rhs.path
        }
    }
    static func sharedNames(for volume: StorageVolume, in volumes: [StorageVolume]) -> [String] {
        guard let container = volume.sharedContainerID else { return [] }
        return volumes.filter { $0.id != volume.id && $0.sharedContainerID == container }.map(\.name).sorted()
    }
}
