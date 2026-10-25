import Foundation
import Darwin

/// Cooperative cancellation is checked between filesystem calls. No deletion APIs are used.
final class StorageScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct StorageFolderEntry: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    var allocatedBytes: UInt64
}

struct StorageFolderSnapshot: Sendable {
    let path: String
    let entries: [StorageFolderEntry]
    let inspected: Int
    let excluded: Int
    let limited: Bool
    let cancelled: Bool
    let device: UInt64
    let inode: UInt64
    let measuredAt: Date
    var measuredBytes: UInt64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
}

enum StorageFolderScanner {
    struct Limits { var entries = 200_000; var seconds: TimeInterval = 20; var depth = 64 }
    static func scan(path: String, rootPath: String? = nil, expectedDevice: UInt64? = nil, limits: Limits = Limits(), cancellation: StorageScanCancellation) throws -> StorageFolderSnapshot {
        let anchor = URL(fileURLWithPath: rootPath ?? path).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == anchor || target.hasPrefix(anchor == "/" ? "/" : anchor + "/") else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        var root = open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(root) }
        let components = target.dropFirst(anchor.count).split(separator: "/")
        for component in components {
            let child = openat(root, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            close(root); root = child
        }
        var identity = stat()
        guard fstat(root, &identity) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if let expectedDevice, UInt64(identity.st_dev) != expectedDevice {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, limits.seconds)
        var inspected = 0, excluded = 0, limited = false
        var seen = Set<String>()
        var entries: [StorageFolderEntry] = []
        func shouldStop() -> Bool {
            if cancellation.isCancelled { return true }
            if inspected >= limits.entries || ProcessInfo.processInfo.systemUptime >= deadline {
                limited = true; return true
            }
            return false
        }
        func walk(_ fd: Int32, path current: String, depth: Int, group: Int?) {
            guard !shouldStop() else { return }
            guard depth <= limits.depth else { excluded += 1; limited = true; return }
            let copy = dup(fd)
            guard copy >= 0 else { excluded += 1; return }
            guard let stream = fdopendir(copy) else { close(copy); excluded += 1; return }
            defer { closedir(stream) }
            while !shouldStop() {
                errno = 0
                guard let raw = readdir(stream) else { if errno != 0 { excluded += 1 }; break }
                let name = withUnsafePointer(to: &raw.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                inspected += 1
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { excluded += 1; continue }
                let kind = info.st_mode & S_IFMT
                guard info.st_dev == identity.st_dev, kind == S_IFDIR || kind == S_IFREG else {
                    excluded += 1; continue
                }
                let childPath = URL(fileURLWithPath: current).appendingPathComponent(name).path
                let index: Int
                if let group { index = group }
                else {
                    index = entries.count
                    entries.append(StorageFolderEntry(path: childPath, name: name, isDirectory: kind == S_IFDIR, allocatedBytes: 0))
                }
                if kind == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { excluded += 1; continue }
                    var opened = stat()
                    if fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino {
                        walk(child, path: childPath, depth: depth + 1, group: index)
                    } else { excluded += 1 }
                    close(child)
                } else if seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                    entries[index].allocatedBytes += UInt64(max(0, info.st_blocks)) * 512
                }
            }
        }
        walk(root, path: target, depth: 0, group: nil)
        // A removed/replaced mount must not receive an old traversal result.
        var current = stat()
        guard lstat(target, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
        }
        return StorageFolderSnapshot(path: target, entries: entries.sorted {
            $0.allocatedBytes == $1.allocatedBytes ? $0.name < $1.name : $0.allocatedBytes > $1.allocatedBytes
        }, inspected: inspected, excluded: excluded, limited: limited, cancelled: cancellation.isCancelled,
           device: UInt64(identity.st_dev), inode: UInt64(identity.st_ino), measuredAt: Date())
    }
}
