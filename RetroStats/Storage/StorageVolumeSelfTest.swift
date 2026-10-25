import Foundation

func storageVolumeSelfTest() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "StorageVolumeSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let date = Date(timeIntervalSince1970: 42)
    func volume(_ id: String, _ name: String, main: Bool = false, location: StorageVolume.Location = .external,
                container: String? = nil, capacity: StorageVolume.Capacity? = .init(total: 100, free: 20)) -> StorageVolume {
        StorageVolume(id: id, name: name, path: "/Volumes/\(name)", location: location, isMain: main,
                      capacity: capacity, sharedContainerID: container, measuredAt: date)
    }
    let main = volume("a", "Main", main: true, location: .internalDrive, container: "shared")
    let alias = volume("a", "Main alias", container: "shared")
    let shared = volume("b", "Data", container: "shared")
    let remote = volume("c", "NAS", location: .network)
    let failed = volume("d", "Unreadable", capacity: nil)
    let catalog = StorageVolumeCatalog.normalized([remote, alias, shared, failed, main])
    let rootAlias = StorageVolume(id: main.id, name: main.name, path: "/", location: .internalDrive,
        isMain: true, capacity: main.capacity, sharedContainerID: nil, measuredAt: date)
    try require(StorageVolumeCatalog.normalized([main, rootAlias]).first == main,
                "Home-volume mount must win an equivalent root alias and retain APFS topology")
    try require(catalog.count == 4, "Catalog must retain four unique mounts including unavailable capacity")
    try require(catalog.first == main, "Main volume wins alias deduplication and stays first")
    try require(catalog.last == remote, "Network volumes follow local volumes")
    try require(catalog.contains(failed), "Unreadable mounted volumes must not silently disappear")
    try require(StorageVolumeCatalog.sharedNames(for: main, in: catalog) == ["Data"], "Known APFS peers must be identified without summing their space")
    try require(StorageVolumeCatalog.sharedNames(for: remote, in: catalog).isEmpty, "Unknown topology must not imply sharing")
    try require(StorageVolume.Capacity(total: 100, free: 101) == nil, "Invalid capacity rejected")
    try require(StorageVolume.Capacity(total: 0, free: 0) == nil, "Zero capacity rejected")
    try require(StorageVolume.Capacity(total: 100, free: -1) == nil, "Negative free space rejected")
    let capacity = StorageVolume.Capacity(total: 100, free: 20, available: 35)!
    try require(capacity.used == 80 && capacity.usedPercent == 80 && capacity.purgeable == 15, "Free, used and purgeable remain distinct")
    try require(StorageVolume.Capacity(total: 100, free: 100)?.usedPercent == 0, "Empty volume is valid")
    try require(StorageVolume.Capacity(total: 100, free: 0)?.usedPercent == 100, "Full volume is valid")
    print("PASS: volume identity, main-volume precedence, unavailable mounts, APFS sharing and capacity bounds")
}
