import Foundation
import Darwin

func storageExplorerSelfTest() throws {
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "StorageExplorerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("RetroStats-explorer-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let inside = root.appendingPathComponent("inside")
    try fm.createDirectory(at: inside, withIntermediateDirectories: true)
    let folder = inside.appendingPathComponent("folder")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 42, count: 16_384).write(to: folder.appendingPathComponent("file.bin"))
    let outside = root.appendingPathComponent("outside.bin")
    try Data(repeating: 8, count: 32_768).write(to: outside)
    try fm.createSymbolicLink(at: inside.appendingPathComponent("alias"), withDestinationURL: root)
    try fm.linkItem(at: folder.appendingPathComponent("file.bin"), to: inside.appendingPathComponent("hardlink.bin"))
    let snapshot = try StorageFolderScanner.scan(path: inside.path, cancellation: StorageScanCancellation())
    try require(snapshot.entries.contains { $0.name == "folder" && $0.isDirectory }, "Real directory retained for drill-down")
    try require(!snapshot.entries.contains { $0.name == "alias" }, "Symlink must not be traversed or presented as measurable content")
    try require(snapshot.excluded >= 1 && !snapshot.limited && !snapshot.cancelled, "Skipped symlinks reported without marking complete scan as limited")
    var fileInfo = stat()
    try require(lstat(folder.appendingPathComponent("file.bin").path, &fileInfo) == 0, "Fixture stat succeeds")
    try require(snapshot.measuredBytes == UInt64(fileInfo.st_blocks) * 512, "Hardlinks must not double count allocated file bytes")
    do {
        _ = try StorageFolderScanner.scan(path: inside.path, expectedDevice: UInt64.max, cancellation: StorageScanCancellation())
        throw NSError(domain: "StorageExplorerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Different mount accepted"])
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) {}
    let outsideFolder = root.appendingPathComponent("outside-folder")
    try fm.createDirectory(at: outsideFolder.appendingPathComponent("leaf"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: inside.appendingPathComponent("redirect"), withDestinationURL: outsideFolder)
    do {
        _ = try StorageFolderScanner.scan(path: inside.appendingPathComponent("redirect/leaf").path,
                                          rootPath: inside.path, cancellation: StorageScanCancellation())
        throw NSError(domain: "StorageExplorerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Intermediate symlink accepted"])
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain {}
    let cancelled = StorageScanCancellation(); cancelled.cancel()
    let cancelledResult = try StorageFolderScanner.scan(path: inside.path, cancellation: cancelled)
    try require(cancelledResult.cancelled && cancelledResult.inspected == 0, "Cancellation must stop before traversal")
    let limited = try StorageFolderScanner.scan(path: inside.path, limits: .init(entries: 1, seconds: 20, depth: 64), cancellation: StorageScanCancellation())
    try require(limited.limited && limited.inspected <= 1, "Entry limit yields explicitly partial result")
    do {
        _ = try StorageFolderScanner.scan(path: inside.appendingPathComponent("alias").path, cancellation: StorageScanCancellation())
        throw NSError(domain: "StorageExplorerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Symlink root accepted"])
    } catch let e as NSError where e.domain == NSPOSIXErrorDomain {}
    try require(fm.fileExists(atPath: outside.path), "Read-only scanner must leave all files intact")
    print("PASS: read-only folder scan, symlink exclusion, hardlink deduplication, cancellation and bounded partial results")
}
