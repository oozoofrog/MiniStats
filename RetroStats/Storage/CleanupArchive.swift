import Foundation
import Darwin

struct CleanupArchiveReceipt: Codable, Sendable {
    let id: UUID
    let candidate: CleanupCandidate
    let directory: String
    let device: UInt64
    let directoryInode: UInt64
    let volumeUUID: String
    var sourceTopology: CleanupTopology?
    var destinationTopology: CleanupTopology?
    var copiedTree: [String: CleanupNode]?
    var local: CleanupReceipt?
    var sourceRootAfterStage: CleanupNode?
    var phase = "copy pending"
    var removed: [String] = []
    var folder: String { directory + "/" + id.uuidString }
    var payload: String { folder + "/payload" }
    var manifest: String { folder + "/manifest.json" }
}

struct CleanupArchiveRestoreFailure: Error, LocalizedError {
    let stagingPath: String
    let message: String
    var errorDescription: String? { message + "; restore staging retained: " + stagingPath }
}

struct CleanupArchiveFailure: Error, LocalizedError {
    let receipt: CleanupArchiveReceipt
    let message: String
    var errorDescription: String? { message }
}

extension AutoCleanupEngine {
    /// Only APFS is supported: other filesystems may discard ACLs/resource forks.
    func prepareArchive(_ candidate: CleanupCandidate, destination: String, capacityOverride: Int64? = nil) throws -> CleanupArchiveReceipt {
        try Task.checkCancellation()
        try validateRoot(candidate.root)
        guard destination == Self.canonicalPath(destination) else { throw Failure.blocked("External destination is redirected or unavailable") }
        let parent = try openDirectory(destination)
        defer { close(parent) }
        var st = stat(), fs = statfs()
        guard fstat(parent, &st) == 0, fstatfs(parent, &fs) == 0, st.st_uid == getuid(),
              UInt64(st.st_dev) != candidate.rootNode.device else { throw Failure.blocked("Choose a writable different volume; same-volume copying does not reclaim space") }
        let format = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        let values = try URL(fileURLWithPath: destination).resourceValues(forKeys: [.volumeUUIDStringKey])
        guard format == "apfs", let uuid = values.volumeUUIDString else { throw Failure.blocked("Archive requires APFS with a verifiable volume UUID and metadata support") }
        let sourceTopology = CleanupTopology.read(candidate.root.path), destinationTopology = CleanupTopology.read(destination)
        if let reason = CleanupTopology.externalCopyBlock(source: sourceTopology, destination: destinationTopology) { throw Failure.blocked(reason) }
        let logical = candidate.tree.values.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let required = logical + Int64(candidate.tree.count) * 16_384 + 20 * 1_048_576
        let free = capacityOverride ?? (Int64(clamping: fs.f_bavail) * Int64(fs.f_bsize))
        guard free >= required else { throw Failure.blocked("External volume lacks space for logical bytes, metadata and reserve; source kept") }
        if mkdirat(parent, "RetroStatsRecovery", 0o700) != 0 && errno != EEXIST { throw Failure.blocked("Cannot create external archive") }
        guard fsync(parent) == 0 else { throw Failure.blocked("External directory durability unknown") }
        let directory = destination + "/RetroStatsRecovery", fd = try openDirectory(directory)
        defer { close(fd) }
        var target = stat()
        guard fstat(fd, &target) == 0, target.st_uid == getuid(), target.st_mode & 0o077 == 0,
              target.st_dev == st.st_dev else { throw Failure.blocked("External archive directory is unowned, shared or redirected") }
        let receipt = CleanupArchiveReceipt(id: UUID(), candidate: candidate, directory: directory,
            device: UInt64(target.st_dev), directoryInode: UInt64(target.st_ino), volumeUUID: uuid,
            sourceTopology: sourceTopology, destinationTopology: destinationTopology)
        guard mkdirat(fd, receipt.id.uuidString, 0o700) == 0, fsync(fd) == 0 else { throw Failure.blocked("Cannot reserve durable archive transaction") }
        try writeArchive(receipt)
        return receipt
    }

    func archiveDirectory(_ receipt: CleanupArchiveReceipt) throws -> Int32 {
        let directory = try openDirectory(receipt.directory)
        var st = stat()
        let values = try? URL(fileURLWithPath: receipt.directory).resourceValues(forKeys: [.volumeUUIDStringKey])
        guard fstat(directory, &st) == 0, UInt64(st.st_dev) == receipt.device,
              UInt64(st.st_ino) == receipt.directoryInode, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              values?.volumeUUIDString == receipt.volumeUUID else {
            close(directory); throw Failure.blocked("External archive changed or disconnected; source removal blocked")
        }
        if let expected = receipt.destinationTopology, CleanupTopology.read(receipt.directory) != expected {
            close(directory); throw Failure.blocked("External container/physical storage identity changed or is unknown; source kept")
        }
        return directory
    }

    func writeArchive(_ receipt: CleanupArchiveReceipt) throws {
        let directory = try archiveDirectory(receipt)
        defer { close(directory) }
        let folder = openat(directory, receipt.id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.blocked("Archive transaction missing") }
        defer { close(folder) }
        let name = ".manifest-" + UUID().uuidString
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.blocked("Archive manifest cannot be saved") }
        defer { close(file) }
        let data = try JSONEncoder().encode(receipt)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw Failure.blocked("Archive manifest write failed") }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(folder, name, folder, "manifest.json") == 0, fsync(folder) == 0 else {
            throw Failure.blocked("Archive manifest durability unknown; source removal blocked")
        }
    }

    func copyArchive(_ receipt: CleanupArchiveReceipt, settings: AutoCleanupSettings,
                     afterCopy: (() throws -> Void)? = nil) throws -> CleanupArchiveReceipt {
        let candidate = receipt.candidate
        try validateRoot(candidate.root)
        let source = try openDirectory(candidate.root.path)
        defer { close(source) }
        let directory = try archiveDirectory(receipt)
        defer { close(directory) }
        let folder = openat(directory, receipt.id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.blocked("Archive transaction disappeared") }
        defer { close(folder) }
        try copyTree(source: source, name: (candidate.path as NSString).lastPathComponent, target: folder, targetName: "payload",
            tree: candidate.tree, attributes: candidate.attributes, verifyDestination: { try verifyPath(receipt.directory, descriptor: directory) })
        try afterCopy?()
        try Task.checkCancellation()
        let fresh = try inspect(path: candidate.path, root: candidate.root, settings: settings, now: .distantFuture, deadline: ProcessInfo.processInfo.systemUptime + 60)
        guard candidate.tree == fresh.tree, candidate.hashes == fresh.hashes, candidate.attributes == fresh.attributes,
              candidate.rootNode == fresh.rootNode else { throw Failure.blocked("Source changed during copy; source kept, incomplete archive is not a recovery copy") }
        let copied = try snapshot(parent: folder, name: "payload", original: candidate.path, settings: settings,
            device: receipt.device, cutoff: nil, deadline: ProcessInfo.processInfo.systemUptime + 60)
        guard contentMatches(candidate, tree: copied.tree, hashes: copied.hashes, attributes: copied.attributes) else {
            throw Failure.blocked("Whole archive content/metadata verification failed; source kept")
        }
        var verified = receipt; verified.copiedTree = copied.tree; verified.phase = "copy verified; source intact"
        try writeArchive(verified)
        return verified
    }

    func prepareArchiveStage(_ receipt: CleanupArchiveReceipt) throws -> CleanupArchiveReceipt {
        guard receipt.copiedTree != nil else { throw Failure.blocked("Copy is unverified") }
        var staged = receipt; staged.local = try prepare(receipt.candidate); staged.phase = "stage pending"
        try writeArchive(staged)
        return staged
    }

    func stageArchive(_ receipt: CleanupArchiveReceipt, settings: AutoCleanupSettings, processes: [String], now: Date,
                      expectedRoot: CleanupNode? = nil) throws -> CleanupArchiveReceipt {
        guard let local = receipt.local else { throw Failure.blocked("No durable local recovery receipt") }
        try verifyArchive(receipt)
        let updatedRoot = try move(local, settings: settings, processes: processes, now: now, expectedRoot: expectedRoot)
        var staged = receipt; staged.sourceRootAfterStage = updatedRoot; staged.phase = "source staged; removal pending"
        try writeArchive(staged)
        return staged
    }

    func verifyArchive(_ receipt: CleanupArchiveReceipt) throws {
        guard let expected = receipt.copiedTree else { throw Failure.blocked("Archive copy is unverified") }
        let directory = try archiveDirectory(receipt)
        defer { close(directory) }
        let folder = openat(directory, receipt.id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.blocked("Archive transaction unavailable") }
        defer { close(folder) }
        let actual = try snapshot(parent: folder, name: "payload", original: receipt.candidate.path, settings: AutoCleanupSettings(),
            device: receipt.device, cutoff: nil, deadline: ProcessInfo.processInfo.systemUptime + 60)
        guard same(expected, actual.tree, moved: false), contentMatches(receipt.candidate, tree: actual.tree, hashes: actual.hashes, attributes: actual.attributes) else {
            throw Failure.blocked("Archive changed or metadata verification failed; source removal blocked")
        }
    }

    /// The only source-removal API requires a durable verified archive and private staging.
    /// Cancellation before commit preserves the full staged source. After commit, stop at
    /// the next file and report the partial source; the verified external copy is retained.
    func reclaimArchive(_ receipt: CleanupArchiveReceipt, processes: [String], beforeCommit: (() throws -> Void)? = nil, afterRemoval: ((String) throws -> Void)? = nil) throws -> CleanupArchiveReceipt {
        guard fixtureArchiveRemoval else { throw Failure.blocked(CleanupReclaimSafety.explanation) }
        try validateRoot(receipt.candidate.root)
        guard let local = receipt.local, local.directory == home + "/Library/Application Support/RetroStats/Recovery",
              local.candidate.path == receipt.candidate.path, local.candidate.root.path == receipt.candidate.root.path,
              local.candidate.hashes == receipt.candidate.hashes else { throw Failure.blocked("Source is not in a verified private recovery stage") }
        guard !Self.inUse(receipt.candidate, processes: processes, staged: local.recoveryPath) else { throw Failure.blocked("Source in use; full staged source kept") }
        try verifyArchive(receipt)
        let parent = try openDirectory(local.directory)
        defer { close(parent) }
        let snapshot = try snapshot(parent: parent, name: local.id.uuidString, original: receipt.candidate.path,
            settings: AutoCleanupSettings(), device: receipt.candidate.rootNode.device, cutoff: nil, deadline: ProcessInfo.processInfo.systemUptime + 60)
        guard same(receipt.candidate.tree, snapshot.tree, moved: true), receipt.candidate.hashes == snapshot.hashes,
              receipt.candidate.attributes == snapshot.attributes else { throw Failure.blocked("Staged source changed; source kept") }
        try beforeCommit?()
        try Task.checkCancellation()
        var committed = receipt; committed.phase = "reclaiming; external verified copy retained"
        try writeArchive(committed)
        let children = Dictionary(grouping: snapshot.tree.keys.filter { !$0.isEmpty }, by: { ($0 as NSString).deletingLastPathComponent == "." ? "" : ($0 as NSString).deletingLastPathComponent })
        func remove(_ fd: Int32, _ name: String, _ relative: String) throws {
            try Task.checkCancellation()
            try verifyArchive(committed)
            let archive = try archiveDirectory(committed); close(archive)
            let path = committed.payload + (relative.isEmpty ? "" : "/" + relative)
            let archiveParent = try openDirectory((path as NSString).deletingLastPathComponent)
            defer { close(archiveParent) }
            var backup = stat()
            guard fstatat(archiveParent, (path as NSString).lastPathComponent, &backup, AT_SYMLINK_NOFOLLOW) == 0,
                  CleanupNode(backup) == committed.copiedTree?[relative] else { throw Failure.blocked("Backup changed during removal; remaining source kept") }
            try verifyPath(local.directory, descriptor: parent)
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, CleanupNode(st) == snapshot.tree[relative] else {
                throw Failure.blocked("Staged source replaced/changed; remaining source kept")
            }
            if st.st_mode & S_IFMT == S_IFDIR {
                let directory = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw Failure.blocked("Staged directory changed") }
                defer { close(directory) }
                for child in (children[relative] ?? []).sorted() { try remove(directory, (child as NSString).lastPathComponent, child) }
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                      UInt64(st.st_dev) == snapshot.tree[relative]?.device, UInt64(st.st_ino) == snapshot.tree[relative]?.inode,
                      unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw Failure.blocked("Directory changed/nonempty; remaining source kept") }
            } else {
                guard unlinkat(fd, name, 0) == 0 else { throw Failure.blocked("Source removal failed; remaining source kept") }
            }
            committed.removed.append(relative)
            try writeArchive(committed)
            try afterRemoval?(relative)
        }
        do {
            try remove(parent, local.id.uuidString, "")
            guard fsync(parent) == 0 else { throw Failure.blocked("Source removal completed; durability unknown") }
            try verifyArchive(committed)
            committed.phase = "reclaimed; external verified copy retained"
            try writeArchive(committed)
            return committed
        } catch {
            throw CleanupArchiveFailure(receipt: committed, message: error.localizedDescription + "; external verified copy retained; local source may be partial")
        }
    }

    func restoreArchive(_ receipt: CleanupArchiveReceipt, processes: [String]) throws {
        let local = try prepareArchiveRestore(receipt, processes: processes)
        try restore(local, processes: processes)
    }

    func prepareArchiveRestore(_ receipt: CleanupArchiveReceipt, processes: [String]) throws -> CleanupReceipt {
        try validateRoot(receipt.candidate.root)
        guard !Self.inUse(receipt.candidate, processes: processes) else { throw Failure.blocked("Source owner is running; restore kept pending") }
        // Check collision before allocating/copying any source-volume staging bytes.
        let original = try openDirectory(receipt.candidate.root.path)
        defer { close(original) }
        var st = stat()
        guard fstat(original, &st) == 0, UInt64(st.st_ino) == receipt.candidate.rootNode.inode,
              UInt64(st.st_dev) == receipt.candidate.rootNode.device else { throw Failure.blocked("Original root changed; no restore copy created") }
        let exists = fstatat(original, (receipt.candidate.path as NSString).lastPathComponent, &st, AT_SYMLINK_NOFOLLOW)
        guard exists != 0 && errno == ENOENT else { throw Failure.blocked("Original path already exists or access is unknown; no restore copy created") }
        try verifyArchive(receipt)
        let directory = try archiveDirectory(receipt)
        defer { close(directory) }
        let folder = openat(directory, receipt.id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.blocked("Archive transaction missing") }
        defer { close(folder) }
        let local = try prepare(receipt.candidate), target = try openDirectory(local.directory)
        defer { close(target) }
        do {
            try copyTree(source: folder, name: "payload", target: target, targetName: local.id.uuidString,
                tree: receipt.copiedTree!, attributes: receipt.candidate.attributes, verifyDestination: { try verifyPath(local.directory, descriptor: target) })
            let copy = try snapshot(parent: target, name: local.id.uuidString, original: receipt.candidate.path,
                settings: AutoCleanupSettings(), device: receipt.candidate.rootNode.device, cutoff: nil, deadline: ProcessInfo.processInfo.systemUptime + 60)
            guard contentMatches(receipt.candidate, tree: copy.tree, hashes: copy.hashes, attributes: copy.attributes) else { throw Failure.blocked("Restore copy verification failed; original untouched") }
            let candidate = CleanupCandidate(path: receipt.candidate.path, root: receipt.candidate.root, size: receipt.candidate.size,
                tree: copy.tree, hashes: copy.hashes, attributes: copy.attributes, rootNode: receipt.candidate.rootNode, volume: receipt.candidate.volume)
            let verified = CleanupReceipt(id: local.id, candidate: candidate, directory: local.directory)
            try persistRecoveryReceipt(verified)
            return verified
        } catch { throw CleanupArchiveRestoreFailure(stagingPath: local.recoveryPath, message: error.localizedDescription) }
    }

    private func contentMatches(_ candidate: CleanupCandidate, tree: [String: CleanupNode], hashes: [String: String], attributes: [String: String]) -> Bool {
        guard candidate.hashes == hashes, candidate.attributes == attributes, candidate.tree.keys.sorted() == tree.keys.sorted() else { return false }
        return candidate.tree.allSatisfy { key, original in
            guard let copy = tree[key] else { return false }
            return original.mode == copy.mode && original.uid == copy.uid && original.gid == copy.gid && original.flags == copy.flags && original.modified == copy.modified &&
                (original.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) || original.size == copy.size)
        }
    }

    private func copyTree(source: Int32, name: String, target: Int32, targetName: String,
                          tree: [String: CleanupNode], attributes: [String: String], verifyDestination: () throws -> Void) throws {
        let children = Dictionary(grouping: tree.keys.filter { !$0.isEmpty }, by: { ($0 as NSString).deletingLastPathComponent == "." ? "" : ($0 as NSString).deletingLastPathComponent })
        func copy(_ source: Int32, _ name: String, _ target: Int32, _ targetName: String, _ relative: String) throws {
            try Task.checkCancellation(); try verifyDestination()
            var st = stat()
            guard fstatat(source, name, &st, AT_SYMLINK_NOFOLLOW) == 0, CleanupNode(st) == tree[relative] else { throw Failure.blocked("Source changed during copy") }
            let isDirectory = st.st_mode & S_IFMT == S_IFDIR
            let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_DIRECTORY : O_NONBLOCK))
            guard input >= 0 else { throw Failure.blocked("Source read failed") }; defer { close(input) }
            guard fstat(input, &st) == 0, CleanupNode(st) == tree[relative] else { throw Failure.blocked("Source replaced during copy") }
            if isDirectory && mkdirat(target, targetName, 0o700) != 0 { throw Failure.blocked("Destination already exists or capacity unavailable") }
            let output = openat(target, targetName, O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_RDONLY | O_DIRECTORY : O_WRONLY | O_CREAT | O_EXCL), 0o600)
            guard output >= 0 else { throw Failure.blocked("Destination write failed; source kept") }; defer { close(output) }
            if isDirectory {
                let expected = (children[relative] ?? []).sorted()
                guard try names(input) == expected.map({ ($0 as NSString).lastPathComponent }).sorted() else { throw Failure.blocked("Source file list changed") }
                for child in expected { try copy(input, (child as NSString).lastPathComponent, output, (child as NSString).lastPathComponent, child) }
            } else {
                var buffer = [UInt8](repeating: 0, count: 1_048_576)
                while true {
                    try Task.checkCancellation(); try verifyDestination()
                    let count = read(input, &buffer, buffer.count)
                    guard count >= 0 else { throw Failure.blocked("Source read error") }; if count == 0 { break }
                    var offset = 0
                    while offset < count {
                        let written = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                        guard written > 0 else { throw Failure.blocked("Destination full/disconnected; source kept") }; offset += written
                    }
                }
            }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0, fsync(output) == 0,
                  try attributeHash(output) == attributes[relative], fstat(input, &st) == 0, CleanupNode(st) == tree[relative] else {
                throw Failure.blocked("Metadata copy failed or source changed; source kept")
            }
        }
        try copy(source, name, target, targetName, "")
        guard fsync(target) == 0 else { throw Failure.blocked("Destination durability unknown; source kept") }
    }
}
