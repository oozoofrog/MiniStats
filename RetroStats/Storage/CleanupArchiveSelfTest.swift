import Foundation
import Darwin

/// Explicit opt-in only, against a named disposable APFS image stored on eyedisk.
func cleanupArchiveSelfTest(destination: String) async throws {
    let fm = FileManager.default
    let values = try URL(fileURLWithPath: destination).resourceValues(forKeys: [.volumeNameKey])
    guard (values.volumeName == "RetroStatsArchiveFixture" || values.volumeName == "eyedisk"), destination.contains("/build/disk-cleanup-evidence/archive-"),
          destination == AutoCleanupEngine.canonicalPath(destination) else { throw AutoCleanupEngine.Failure.blocked("Archive tests require the isolated APFS fixture volume") }
    let temporary = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)!
    let home = temporary + "/archive-home-" + UUID().uuidString
    try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: home) }
    let engine = AutoCleanupEngine(home: home, fixtureArchiveRemoval: true), now = Date().addingTimeInterval(90 * 86400), settings = AutoCleanupSettings()
    let root = CleanupRoot(path: home + "/Library/Caches/pip", category: .developerCaches, owners: ["FixturePython"])
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    func file(_ path: String, _ value: UInt8 = 19) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: value, count: 8192).write(to: URL(fileURLWithPath: path))
    }
    func expect(_ value: Bool, _ message: String) throws { guard value else { throw AutoCleanupEngine.Failure.blocked("Archive fixture: " + message) } }
    func blocked(_ action: () throws -> Void) throws {
        do { try action() } catch { return }; throw AutoCleanupEngine.Failure.blocked("Unsafe archive fixture action succeeded")
    }
    func candidate(_ name: String) throws -> CleanupCandidate {
        guard let result = try engine.scan(roots: [root], settings: settings, processes: [], now: now).candidates.first(where: { $0.path == root.path + "/" + name }) else { throw AutoCleanupEngine.Failure.blocked("Fixture candidate missing: " + name) }
        return result
    }
    func archive(_ name: String) throws -> CleanupArchiveReceipt {
        let selected = try candidate(name)
        return try engine.prepareArchive(selected, destination: destination)
    }
    func acl(_ path: String, _ rights: String = "read,write") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(NSUserName()) allow \(rights)", path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run(); let detail = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AutoCleanupEngine.Failure.blocked("Fixture ACL setup failed: " + String(decoding: detail, as: UTF8.self)) }
    }
    let original = root.path + "/success"
    try file(original + "/a.bin"); try file(original + "/b.bin", 23)
    try acl(original + "/a.bin")
    let value = [UInt8]([1, 2, 3])
    _ = value.withUnsafeBytes { setxattr(original + "/a.bin", "com.example.fixture", $0.baseAddress, $0.count, 0, 0) }
    let selected = try candidate("success")
    try blocked { _ = try engine.prepareArchive(selected, destination: home) }
    try blocked { _ = try engine.prepareArchive(selected, destination: destination, capacityOverride: 0) }
    var receipt = try archive("success")
    receipt = try engine.copyArchive(receipt, settings: settings)
    try expect(fm.fileExists(atPath: original) && receipt.copiedTree != nil, "source preserved until verified copy")
    var mismatchedTopology = receipt
    mismatchedTopology.destinationTopology = CleanupTopology(volumeUUID: "changed", containerUUID: "changed", physicalStores: ["changed"], physicalDevices: ["changed"], externalPhysical: true)
    func sourceDirectoryFDs() -> Int {
        (0..<4096).reduce(0) { count, fd in
            var st = stat()
            return count + ((fstat(Int32(fd), &st) == 0 && st.st_dev >= 0 && UInt64(st.st_dev) == selected.rootNode.device && UInt64(st.st_ino) == selected.rootNode.inode) ? 1 : 0)
        }
    }
    let fdCount = sourceDirectoryFDs()
    for _ in 0..<24 { try blocked { _ = try engine.copyArchive(mismatchedTopology, settings: settings) } }
    try expect(sourceDirectoryFDs() == fdCount && fm.fileExists(atPath: original), "topology failure preserves source and closes descriptors across retries")
    try blocked { _ = try engine.copyArchive(receipt, settings: settings) } // idempotent, no overwriting payload
    receipt = try engine.prepareArchiveStage(receipt)
    receipt = try engine.stageArchive(receipt, settings: settings, processes: [], now: now)
    let opened = selected.tree.values.first { $0.mode & UInt32(S_IFMT) == UInt32(S_IFREG) }!
    try blocked { _ = try engine.reclaimArchive(receipt, processes: ["OPENID:\(opened.device):\(opened.inode)"]) }
    try expect(fm.fileExists(atPath: receipt.local!.recoveryPath + "/a.bin"), "inode usage protects staged source")
    let productionEngine = AutoCleanupEngine(home: home)
    try blocked { _ = try productionEngine.reclaimArchive(receipt, processes: []) }
    try expect(fm.fileExists(atPath: receipt.local!.recoveryPath), "production source-removal gate preserves staged source")
    receipt = try engine.reclaimArchive(receipt, processes: [])
    try expect(!fm.fileExists(atPath: original) && !fm.fileExists(atPath: receipt.local!.recoveryPath) && receipt.removed.count == 3, "verified source reclaim")
    try engine.verifyArchive(receipt)
    try blocked { _ = try engine.reclaimArchive(receipt, processes: []) }
    try file(original + "/collision", 99)
    let stagingBefore = try fm.contentsOfDirectory(atPath: receipt.local!.directory).sorted()
    try blocked { try engine.restoreArchive(receipt, processes: []) }
    try blocked { try engine.restoreArchive(receipt, processes: []) }
    try expect(try fm.contentsOfDirectory(atPath: receipt.local!.directory).sorted() == stagingBefore, "repeated collision creates no restore copies")
    try expect(try Data(contentsOf: URL(fileURLWithPath: original + "/collision")) == Data(repeating: 99, count: 8192), "restore never overwrites")
    try fm.removeItem(atPath: original)
    try engine.restoreArchive(receipt, processes: [])
    try expect(try Data(contentsOf: URL(fileURLWithPath: original + "/a.bin")) == Data(repeating: 19, count: 8192), "external restore hash")
    // Whole copy cannot authorize removal if the source changes during copy.
    try file(root.path + "/changing")
    let changing = try archive("changing")
    try blocked { _ = try engine.copyArchive(changing, settings: settings, afterCopy: { try file(root.path + "/changing", 72) }) }
    try expect(fm.fileExists(atPath: root.path + "/changing"), "copy-time source change preserved")
    try file(root.path + "/corrupt-copy")
    let corrupt = try archive("corrupt-copy")
    try blocked { _ = try engine.copyArchive(corrupt, settings: settings, afterCopy: { try file(corrupt.payload, 77) }) }
    try expect(fm.fileExists(atPath: root.path + "/corrupt-copy"), "copy verification failure preserved")
    // Cancellation after copy but before its verified marker keeps the untouched source.
    try file(root.path + "/changed-acl")
    try acl(root.path + "/changed-acl")
    let changedACL = try archive("changed-acl")
    try blocked { _ = try engine.copyArchive(changedACL, settings: settings, afterCopy: { try acl(changedACL.payload, "execute") }) }
    try expect(fm.fileExists(atPath: root.path + "/changed-acl"), "nonempty ACL mismatch preserves source")
    try file(root.path + "/changed-metadata")
    let metadata = try archive("changed-metadata")
    try blocked { _ = try engine.copyArchive(metadata, settings: settings, afterCopy: {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: metadata.payload)
    }) }
    try expect(fm.fileExists(atPath: root.path + "/changed-metadata"), "mtime verification failure preserves source")
    try file(root.path + "/cancel-copy")
    let cancelCopy = try archive("cancel-copy")
    let copyWorker = Task.detached {
        try engine.copyArchive(cancelCopy, settings: settings, afterCopy: { withUnsafeCurrentTask { $0?.cancel() } })
    }
    do { _ = try await copyWorker.value; throw AutoCleanupEngine.Failure.blocked("Copy cancellation ignored") } catch is CancellationError { }
    try expect(fm.fileExists(atPath: root.path + "/cancel-copy"), "copy cancellation preserves source")
    // Before-commit cancellation retains the full staged source and verified external copy.
    try file(root.path + "/cancel-commit")
    var cancelCommit = try engine.copyArchive(archive("cancel-commit"), settings: settings)
    cancelCommit = try engine.prepareArchiveStage(cancelCommit)
    cancelCommit = try engine.stageArchive(cancelCommit, settings: settings, processes: [], now: now)
    let cancellationReceipt = cancelCommit
    let commitWorker = Task.detached {
        try engine.reclaimArchive(cancellationReceipt, processes: [], beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
    }
    do { _ = try await commitWorker.value; throw AutoCleanupEngine.Failure.blocked("Commit cancellation ignored") } catch is CancellationError { }
    try expect(fm.fileExists(atPath: cancelCommit.local!.recoveryPath), "commit cancellation preserves staged source")
    try engine.restore(cancelCommit.local!, processes: [])
    // Partial removal is explicit, retains a complete verified archive, and can restore.
    try file(root.path + "/partial/a.bin"); try file(root.path + "/partial/b.bin")
    var partial = try engine.copyArchive(archive("partial"), settings: settings)
    partial = try engine.prepareArchiveStage(partial)
    partial = try engine.stageArchive(partial, settings: settings, processes: [], now: now)
    do {
        _ = try engine.reclaimArchive(partial, processes: [], afterRemoval: { _ in throw AutoCleanupEngine.Failure.blocked("Injected after-removal failure") })
        throw AutoCleanupEngine.Failure.blocked("Partial failure ignored")
    } catch let failure as CleanupArchiveFailure {
        partial = failure.receipt
        try expect(partial.removed.count == 1 && partial.phase.contains("reclaiming"), "partial commit recorded")
    }
    try engine.verifyArchive(partial)
    try blocked { _ = try engine.reclaimArchive(partial, processes: []) }
    try engine.restoreArchive(partial, processes: [])
    try expect(fm.fileExists(atPath: root.path + "/partial/a.bin") && fm.fileExists(atPath: root.path + "/partial/b.bin"), "partial source restored from full copy")
    // A changed already-removed backup is caught; never report a verified full copy.
    try file(root.path + "/backup-change/a.bin"); try file(root.path + "/backup-change/b.bin")
    var backupChange = try engine.copyArchive(archive("backup-change"), settings: settings)
    backupChange = try engine.prepareArchiveStage(backupChange)
    backupChange = try engine.stageArchive(backupChange, settings: settings, processes: [], now: now)
    let backupPath = backupChange.payload
    do {
        _ = try engine.reclaimArchive(backupChange, processes: [], afterRemoval: { relative in
            if relative == "a.bin" { try file(backupPath + "/a.bin", 84) }
        })
        throw AutoCleanupEngine.Failure.blocked("Changed backup incorrectly accepted")
    } catch let failure as CleanupArchiveFailure {
        try expect(failure.receipt.phase.contains("reclaiming") && failure.receipt.removed.count == 1, "backup mutation blocks remaining removal")
    }
    try expect(fm.fileExists(atPath: backupChange.local!.recoveryPath + "/b.bin"), "remaining source preserved after backup mutation")
    // A replaced external directory never authorizes removal, even at the final hook.
    try file(root.path + "/disconnected")
    var disconnected = try engine.copyArchive(archive("disconnected"), settings: settings)
    disconnected = try engine.prepareArchiveStage(disconnected)
    disconnected = try engine.stageArchive(disconnected, settings: settings, processes: [], now: now)
    let externalHeld = destination + "/held-recovery"
    try blocked {
        _ = try engine.reclaimArchive(disconnected, processes: [], beforeCommit: {
            try fm.moveItem(atPath: disconnected.directory, toPath: externalHeld)
            try fm.createDirectory(atPath: disconnected.directory, withIntermediateDirectories: true)
        })
    }
    try expect(fm.fileExists(atPath: disconnected.local!.recoveryPath), "destination replacement preserves full staged source")
    try fm.removeItem(atPath: disconnected.directory); try fm.moveItem(atPath: externalHeld, toPath: disconnected.directory)
    try engine.restore(disconnected.local!, processes: [])
    // The descriptor is opened before staging: rename does not revoke existing writes.
    try file(root.path + "/writer-race")
    var writerRace = try engine.copyArchive(archive("writer-race"), settings: settings)
    let writer = open(root.path + "/writer-race", O_WRONLY | O_NOFOLLOW)
    guard writer >= 0 else { throw AutoCleanupEngine.Failure.blocked("Fixture writer open failed") }
    defer { close(writer) }
    writerRace = try engine.prepareArchiveStage(writerRace)
    writerRace = try engine.stageArchive(writerRace, settings: settings, processes: [], now: now)
    var changedByte: UInt8 = 91
    try expect(pwrite(writer, &changedByte, 1, 0) == 1, "pre-existing descriptor can write staged source")
    var commitReached = false
    try blocked { _ = try productionEngine.reclaimArchive(writerRace, processes: [], beforeCommit: { commitReached = true }) }
    try expect(!commitReached && fm.fileExists(atPath: writerRace.local!.recoveryPath), "production gate rejects write race before commit")
    try expect(try Data(contentsOf: URL(fileURLWithPath: writerRace.local!.recoveryPath)).first == 91, "changed source byte preserved")
    // A valid copied backup is mutable through an already-open descriptor too.
    let backupWriter = open(writerRace.payload, O_WRONLY | O_NOFOLLOW)
    guard backupWriter >= 0 else { throw AutoCleanupEngine.Failure.blocked("Fixture backup writer failed") }
    defer { close(backupWriter) }
    try expect(pwrite(backupWriter, &changedByte, 1, 0) == 1, "verified external copy remains writable")
    try blocked { try engine.verifyArchive(writerRace) }
    try blocked { _ = try productionEngine.reclaimArchive(writerRace, processes: []) }
    try expect(fm.fileExists(atPath: writerRace.local!.recoveryPath), "mutable backup never authorizes production removal")
    print("PASS: pre-staging write FD and mutable backup FD demonstrate unresolved race; production removal refuses before commit and preserves source")
    if ProcessInfo.processInfo.environment["RETROSTATS_TEST_DETACH_ARCHIVE"] == "1" {
        guard values.volumeName == "RetroStatsArchiveFixture" else { throw AutoCleanupEngine.Failure.blocked("Actual detach test requires only the disposable image") }
        try file(root.path + "/actual-detach")
        var detach = try engine.copyArchive(archive("actual-detach"), settings: settings)
        detach = try engine.prepareArchiveStage(detach)
        detach = try engine.stageArchive(detach, settings: settings, processes: [], now: now)
        try blocked {
            _ = try engine.reclaimArchive(detach, processes: [], beforeCommit: {
                let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                task.arguments = ["detach", destination]; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                try task.run(); task.waitUntilExit()
                guard task.terminationStatus == 0 else { throw AutoCleanupEngine.Failure.blocked("Fixture unmount failed") }
            })
        }
        try expect(fm.fileExists(atPath: detach.local!.recoveryPath), "actual unmount preserves full staged source")
        try engine.restore(detach.local!, processes: [])
        try expect(fm.fileExists(atPath: root.path + "/actual-detach"), "source recovered after real external detach")
        print("PASS: actual APFS fixture-volume detach before commit protects complete source")
    }
    print("PASS: external APFS archive logical-capacity check, different-volume policy, full SHA256/ACL/xattr/permissions verification, source/copy changes, cancellation, post-stage inode usage, guarded reclaim, repeat rejection, restore collision, partial commit recovery, final destination replacement")
}

@MainActor func cleanupExternalCopyControllerSelfTest(destination: String) throws {
    let fm = FileManager.default
    let temporary = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)!
    let home = temporary + "/archive-home-controller-" + UUID().uuidString
    try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: home) }
    let root = CleanupRoot(path: home + "/Library/Caches/pip", category: .developerCaches, owners: ["FixturePython"])
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    let original = root.path + "/cache.bin"
    try Data(repeating: 18, count: 16384).write(to: URL(fileURLWithPath: original))
    let suite = "RetroStats.ExternalCopyController." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/support"), allowOperations: true,
        archiveDestination: destination, engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { Date().addingTimeInterval(90 * 86400) }, changed: {})
    func settle() throws {
        let deadline = Date().addingTimeInterval(15)
        while controller.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !controller.busy else { controller.stop(); throw AutoCleanupEngine.Failure.blocked("External controller fixture timeout") }
    }
    controller.preview(); try settle()
    guard controller.candidateCount == 1 else { throw AutoCleanupEngine.Failure.blocked("External controller fixture candidate missing") }
    controller.select(original, enabled: true)
    controller.confirmArchive()
    guard !controller.busy, controller.error != nil, fm.fileExists(atPath: original), controller.history.isEmpty else { throw AutoCleanupEngine.Failure.blocked("Production reclaim gate failed") }
    controller.confirmExternalCopy(); try settle()
    guard let item = controller.history.first?.items.first, let archive = item.archive, archive.copiedTree != nil,
          !item.deleted, fm.fileExists(atPath: original), fm.fileExists(atPath: archive.payload), controller.history[0].copiedBytes > 0 else { throw AutoCleanupEngine.Failure.blocked("External copy controller failed: " + (controller.error ?? controller.history.first?.items.first?.reason ?? "unknown")) }
    controller.restore(recordID: controller.history[0].id, index: 0); try settle()
    guard controller.error?.contains("no restore copy created") == true else { throw AutoCleanupEngine.Failure.blocked("Restore collision preflight failed") }
    controller.stop()
    let blockedController = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/blocked-support"), allowOperations: true,
        archiveDestination: home, engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { Date().addingTimeInterval(90 * 86400) }, changed: {})
    func settleBlocked() throws {
        let deadline = Date().addingTimeInterval(15)
        while blockedController.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !blockedController.busy else { blockedController.stop(); throw AutoCleanupEngine.Failure.blocked("Blocked copy fixture timeout") }
    }
    blockedController.preview(); try settleBlocked(); blockedController.select(original, enabled: true)
    blockedController.confirmExternalCopy(); try settleBlocked()
    guard blockedController.error?.contains("Copy blocked:") == true,
          blockedController.error?.contains("same-volume") == true,
          blockedController.history.first?.outcomeLabel.contains("No items completed") == true,
          blockedController.history.first?.copiedBytes == 0,
          try Data(contentsOf: URL(fileURLWithPath: original)) == Data(repeating: 18, count: 16384) else { throw AutoCleanupEngine.Failure.blocked("Blocked copy UI state did not retain source and display its reason") }
    blockedController.stop()
    print("PASS: same-volume copy exposes immediate error and no-items-completed outcome while retaining source")
    print("PASS: production external-copy controller selection, durable copy-only history, source retention, reclamation gate, no-copy restore collision")
}
