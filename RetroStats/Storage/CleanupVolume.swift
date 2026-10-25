import Foundation
import Darwin

/// Raw filesystem free blocks, deliberately separate from Finder's purgeable estimate.
struct CleanupVolume: Codable, Sendable, Identifiable {
    let id: UInt64
    let path: String
    let name: String
    let free: Int64
    let total: Int64
    let importantAvailable: Int64?
    let measuredAt: Date
    var topology: CleanupTopology?
    var purgeableEstimate: Int64? { importantAvailable.map { max(0, $0 - free) } }

    static func read(_ path: String) -> CleanupVolume? {
        var fs = statfs(), st = stat()
        guard statfs(path, &fs) == 0, stat(path, &st) == 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey])
        return CleanupVolume(id: UInt64(st.st_dev), path: mount, name: values?.volumeName ?? mount,
            free: Int64(clamping: fs.f_bavail) * Int64(fs.f_bsize),
            total: Int64(clamping: fs.f_blocks) * Int64(fs.f_bsize),
            importantAvailable: values?.volumeAvailableCapacityForImportantUsage, measuredAt: Date(), topology: CleanupTopology.read(path))
    }

    static func mounted() -> [CleanupVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var seen = Set<UInt64>()
        return ([URL(fileURLWithPath: NSHomeDirectory())] + urls).compactMap { url in
            guard let volume = read(url.path), seen.insert(volume.id).inserted else { return nil }
            return volume
        }
    }

    static func delta(before: [CleanupVolume], after: [CleanupVolume]) -> [String] {
        before.map { initial in
            guard let final = after.first(where: { $0.id == initial.id }) else {
                return "\(initial.name) [\(initial.path)]: after measurement unknown"
            }
            let change = final.free - initial.free
            return "\(initial.name) [\(initial.path)]: \(bytes(UInt64(initial.free))) → \(bytes(UInt64(final.free))); measured change \(change >= 0 ? "+" : "−")\(bytes(UInt64(abs(change))))"
        }
    }
}
