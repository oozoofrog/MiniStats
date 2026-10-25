import Foundation

extension StorageVolumeCatalog {
    static func identity(at path: String) -> (id: String, device: UInt64)? {
        guard let raw = CleanupVolume.read(path) else { return nil }
        let info = try? URL(fileURLWithPath: raw.path).resourceValues(forKeys: [.volumeUUIDStringKey])
        return (info?.volumeUUIDString ?? "\(raw.id):\(raw.path)", raw.id)
    }

    /// Runs on the storage utility queue; remote mounts must not block the UI.
    static func read() -> [StorageVolume] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let mainDevice = CleanupVolume.read(home.path)?.id
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let rows = ([home] + urls).map { url -> StorageVolume in
            let raw = CleanupVolume.read(url.path)
            let path = raw?.path ?? url.path
            let mount = URL(fileURLWithPath: path)
            let info = try? mount.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey])
            let isMain = raw.map { $0.id == mainDevice } ?? (url == home)
            let location: StorageVolume.Location
            if info?.volumeIsLocal == false { location = .network }
            else if isMain || info?.volumeIsInternal == true { location = .internalDrive }
            else if info?.volumeIsInternal == false { location = .external }
            else { location = .unknown }
            return StorageVolume(id: info?.volumeUUIDString ?? raw.map { "\($0.id):\(path)" } ?? "unavailable:\(path)",
                name: info?.volumeName ?? raw?.name ?? mount.lastPathComponent, path: path, location: location,
                isMain: isMain, capacity: raw.flatMap { .init(total: $0.total, free: $0.free, available: $0.importantAvailable) },
                sharedContainerID: raw?.topology?.containerUUID, measuredAt: Date())
        }
        return normalized(rows)
    }
}
