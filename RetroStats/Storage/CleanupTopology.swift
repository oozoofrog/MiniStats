import Foundation
import Darwin
import IOKit
import CryptoKit

/// Read-only registry identity. Device numbers alone cannot distinguish shared APFS space.
/// Missing/ambiguous properties are unknown; no disk utility, mounting or elevation fallback.
struct CleanupTopology: Codable, Equatable, Sendable {
    let volumeUUID: String
    let containerUUID: String
    let physicalStores: [String]
    let physicalDevices: [String]
    let externalPhysical: Bool

    static func read(_ path: String) -> CleanupTopology? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let format = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        guard format == "apfs" else { return nil }
        let device = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard device.hasPrefix("/dev/"), let uuid = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return nil }
        func matchingVolume() -> io_registry_entry_t {
            var matches: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, (device as NSString).lastPathComponent), &matches) == KERN_SUCCESS else { return 0 }
            defer { IOObjectRelease(matches) }
            let first = IOIteratorNext(matches), second = IOIteratorNext(matches)
            if second != 0 { IOObjectRelease(second) }
            guard first != 0, second == 0, IOIteratorIsValid(matches) != 0 else {
                if first != 0 { IOObjectRelease(first) }; return 0
            }
            return first
        }
        let service = matchingVolume()
        guard service != 0 else { return nil }
        var serviceID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &serviceID) == KERN_SUCCESS else { IOObjectRelease(service); return nil }
        var stack = [service], visited = Set<UInt64>(), containers = Set<String>(), stores = Set<String>()
        var volume: String?, locations: [String] = [], devices = Set<String>(), invalid = false
        defer { stack.forEach { IOObjectRelease($0) } }
        while let entry = stack.popLast() {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
            if !visited.insert(id).inserted { continue }
            guard visited.count <= 96 else { return nil }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let p = properties?.takeRetainedValue() as? [String: Any] else { return nil }
            func identity(_ key: String) -> String? { (p[key] as? String).flatMap { UUID(uuidString: $0)?.uuidString } }
            if entry == service { volume = identity("UUID") }
            if IOObjectConformsTo(entry, "AppleAPFSContainer") != 0 {
                guard let value = identity("UUID") else { return nil }; containers.insert(value)
            }
            if p["Content"] as? String == "7C3457EF-0000-11AA-AA11-00306543ECAC" {
                guard let value = identity("UUID") else { return nil }; stores.insert(value)
            }
            if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                guard let protocolInfo = p["Protocol Characteristics"] as? [String: Any],
                      let interconnect = protocolInfo["Physical Interconnect"] as? String,
                      ["Apple Fabric", "PCI-Express", "USB", "SATA", "SAS", "FireWire", "Thunderbolt"].contains(interconnect),
                      let location = protocolInfo["Physical Interconnect Location"] as? String,
                      ["Internal", "External"].contains(location),
                      let characteristics = p["Device Characteristics"] as? [String: Any],
                      let serial = characteristics["Serial Number"] as? String, !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let product = characteristics["Product Name"] as? String, !product.isEmpty else { invalid = true; continue }
                locations.append(location)
                // Distinct APFS partitions can still be on the same physical device.
                // Persist only a digest, never the hardware serial itself.
                let identityData = try? JSONEncoder().encode([interconnect, characteristics["Vendor Name"] as? String ?? "", product, serial])
                guard let identityData else { return nil }
                devices.insert(SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined())
            }
            var parents: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parents) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(parents) }
            while case let parent = IOIteratorNext(parents), parent != 0 {
                stack.append(parent)
                guard stack.count <= 192 else { return nil }
            }
            guard IOIteratorIsValid(parents) != 0 else { return nil }
        }
        let finalService = matchingVolume()
        guard finalService != 0 else { return nil }
        defer { IOObjectRelease(finalService) }
        var finalServiceID: UInt64 = 0
        var finalFS = statfs()
        let finalUUID = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard !invalid, !locations.isEmpty, !devices.isEmpty, containers.count == 1, !stores.isEmpty,
              volume == UUID(uuidString: uuid)?.uuidString, statfs(path, &finalFS) == 0,
              finalUUID == uuid,
              IORegistryEntryGetRegistryEntryID(finalService, &finalServiceID) == KERN_SUCCESS, serviceID == finalServiceID,
              memcmp(&fs.f_fsid, &finalFS.f_fsid, MemoryLayout<fsid_t>.size) == 0 else { return nil }
        return CleanupTopology(volumeUUID: volume!, containerUUID: containers.first!,
            physicalStores: stores.sorted(), physicalDevices: devices.sorted(), externalPhysical: locations.allSatisfy { $0 == "External" })
    }

    static func externalCopyBlock(source: CleanupTopology?, destination: CleanupTopology?) -> String? {
        guard let source, let destination else { return "APFS container or physical storage identity is unknown; source kept" }
        guard source.containerUUID != destination.containerUUID else { return "APFS volumes share a container; choose separate physical external storage" }
        guard !source.physicalDevices.isEmpty, !destination.physicalDevices.isEmpty else { return "Physical device identity is unknown; source kept" }
        guard Set(source.physicalStores).isDisjoint(with: destination.physicalStores),
              Set(source.physicalDevices).isDisjoint(with: destination.physicalDevices) else { return "Source and destination share physical storage; source kept" }
        guard destination.externalPhysical else { return "Destination is not verified physical external storage; virtual/unknown storage is blocked" }
        return nil
    }
}

enum CleanupReclaimSafety {
    static let blockers = [
        "Source writes through existing file descriptors cannot be excluded throughout removal.",
        "Removal cannot atomically require the inspected inode; a replacement could be removed.",
        "The external copy remains writable; verification does not make it immutable."
    ]
    static var explanation: String { "Source removal unavailable. " + blockers.joined(separator: " ") + " Original source kept; verified copy reclaims no space." }
}
