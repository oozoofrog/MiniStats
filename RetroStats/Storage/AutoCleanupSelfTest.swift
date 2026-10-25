import Foundation
import Darwin

private func cleanupExpect(_ check: @autoclosure () throws -> Bool) throws {
    let result = try check()
    guard result else { throw AutoCleanupEngine.Failure.blocked("Cleanup fixture assertion failed") }
}

/// All mutation tests use a unique synthetic home; no live cache is an input.
func autoCleanupSelfTest() async throws {
    let fm = FileManager.default
    let home = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)! + "/recoverable-cleanup-" + UUID().uuidString
    try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: home) }
    let engine = AutoCleanupEngine(home: home), now = Date().addingTimeInterval(90 * 86400)
    let root = CleanupRoot(path: home + "/.npm/_cacache", category: .developerCaches, owners: ["node", "npm"])
    var settings = AutoCleanupSettings()
    try cleanupExpect(!settings.enabled && !settings.categories.contains(.derivedData) && !settings.categories.contains(.appLogs))
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    func file(_ path: String, _ byte: UInt8 = 42) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: byte, count: 8192).write(to: URL(fileURLWithPath: path))
    }
    func scan(_ processes: [String] = []) throws -> CleanupScan {
        try engine.scan(roots: [root], settings: settings, processes: processes, now: now)
    }
    func blocked(_ action: () throws -> Void) { do { try action(); preconditionFailure("Unsafe mutation allowed") } catch { } }
    let original = root.path + "/content-v2"
    try file(original + "/cache.bin")
    let recent = root.path + "/recent.bin"
    try file(recent)
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-86400)], ofItemAtPath: recent)
    let outside = home + "/Documents/precious.txt"
    try file(outside)
    try fm.createSymbolicLink(atPath: root.path + "/linked", withDestinationPath: outside)
    try file(root.path + "/nested-link/data")
    try fm.createSymbolicLink(atPath: root.path + "/nested-link/link", withDestinationPath: outside)
    try fm.linkItem(atPath: outside, toPath: root.path + "/hardlink")
    var report = try scan()
    try cleanupExpect(report.candidates.map(\.path) == [original] && !report.skipped.isEmpty)
    try cleanupExpect(report.candidates[0].hashes.count == 1 && report.candidates[0].size > 0)
    try cleanupExpect(try scan(["node"]).candidates.isEmpty)
    try cleanupExpect(try scan(["OPEN:" + original + "/cache.bin"]).candidates.isEmpty)
    try cleanupExpect(try scan(["softwareupdated"]).candidates.isEmpty)
    let candidate = report.candidates[0]
    let receipt = try engine.prepare(candidate)
    blocked { try engine.move(receipt, settings: settings, processes: ["npm"], now: now) }
    settings.exclusions = [original + "/cache.bin"]
    blocked { try engine.move(receipt, settings: settings, processes: [], now: now) }
    settings.exclusions = []
    try file(original + "/cache.bin", 24)
    blocked { try engine.move(receipt, settings: settings, processes: [], now: now) }
    try cleanupExpect(fm.fileExists(atPath: original) && !fm.fileExists(atPath: receipt.recoveryPath))
    // A new sibling invalidates the root even when the selected tree is unchanged.
    report = try scan()
    let rootChanged = try engine.prepare(report.candidates[0])
    try file(root.path + "/new-download")
    blocked { try engine.move(rootChanged, settings: settings, processes: [], now: now) }
    try fm.removeItem(atPath: root.path + "/new-download")
    // npm tmp activity protects the whole root, including unchanged content-v2.
    try file(root.path + "/tmp/nested/cache")
    try fm.setAttributes([.modificationDate: now], ofItemAtPath: root.path + "/tmp/nested/cache")
    try cleanupExpect(try scan().candidates.isEmpty)
    try fm.removeItem(atPath: root.path + "/tmp")
    report = try scan()
    let fresh = report.candidates[0], saved = try engine.prepare(fresh)
    try engine.move(saved, settings: settings, processes: [], now: now)
    try cleanupExpect(!fm.fileExists(atPath: original) && fm.fileExists(atPath: saved.recoveryPath + "/cache.bin"))
    try cleanupExpect(fm.fileExists(atPath: outside) && fm.fileExists(atPath: root.path + "/nested-link/data"))
    blocked { try engine.move(saved, settings: settings, processes: [], now: now) } // repeat never creates a second outcome
    try file(original + "/new-cache")
    blocked { try engine.restore(saved, processes: []) } // no overwrite
    try fm.removeItem(atPath: original)
    try engine.restore(saved, processes: [])
    try cleanupExpect(try Data(contentsOf: URL(fileURLWithPath: original + "/cache.bin")) == Data(repeating: 24, count: 8192))
    blocked { try engine.restore(saved, processes: []) }
    // Swap the source to a symlink immediately before atomic rename.
    let swapCandidate = try scan().candidates[0], swap = try engine.prepare(swapCandidate)
    blocked {
        try engine.move(swap, settings: settings, processes: [], now: now, beforeRename: {
            try fm.moveItem(atPath: original, toPath: home + "/held")
            try fm.createSymbolicLink(atPath: original, withDestinationPath: home + "/Documents")
        })
    }
    try cleanupExpect(fm.fileExists(atPath: outside) && fm.fileExists(atPath: home + "/held/cache.bin"))
    try fm.removeItem(atPath: original)
    try fm.moveItem(atPath: home + "/held", toPath: original)
    // Final-hook root activity is rejected even if the selected item is unchanged.
    let lastActivity = try engine.prepare(try scan().candidates[0])
    blocked { try engine.move(lastActivity, settings: settings, processes: [], now: now, beforeRename: { try file(root.path + "/late-download") }) }
    try cleanupExpect(fm.fileExists(atPath: original))
    try fm.removeItem(atPath: root.path + "/late-download")
    let lastRoot = try engine.prepare(try scan().candidates[0])
    blocked {
        try engine.move(lastRoot, settings: settings, processes: [], now: now, beforeRename: {
            try fm.moveItem(atPath: root.path, toPath: home + "/last-held-root")
            try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        })
    }
    try cleanupExpect(fm.fileExists(atPath: home + "/last-held-root/content-v2/cache.bin"))
    try fm.removeItem(atPath: root.path)
    try fm.moveItem(atPath: home + "/last-held-root", toPath: root.path)
    let lastRecovery = try engine.prepare(try scan().candidates[0])
    blocked {
        try engine.move(lastRecovery, settings: settings, processes: [], now: now, beforeRename: {
            try fm.moveItem(atPath: lastRecovery.directory, toPath: home + "/last-held-recovery")
            try fm.createDirectory(atPath: lastRecovery.directory, withIntermediateDirectories: true)
        })
    }
    try cleanupExpect(fm.fileExists(atPath: original))
    try fm.removeItem(atPath: lastRecovery.directory)
    try fm.moveItem(atPath: home + "/last-held-recovery", toPath: lastRecovery.directory)
    let lastRestore = try engine.prepare(try scan().candidates[0])
    try engine.move(lastRestore, settings: settings, processes: [], now: now)
    blocked {
        try engine.restore(lastRestore, processes: [], beforeRename: {
            try fm.moveItem(atPath: lastRestore.recoveryPath, toPath: home + "/last-held-payload")
            try fm.createSymbolicLink(atPath: lastRestore.recoveryPath, withDestinationPath: home + "/Documents")
        })
    }
    try cleanupExpect(!fm.fileExists(atPath: original) && fm.fileExists(atPath: outside))
    try fm.removeItem(atPath: lastRestore.recoveryPath)
    try fm.moveItem(atPath: home + "/last-held-payload", toPath: lastRestore.recoveryPath)
    try engine.restore(lastRestore, processes: [])
    // Redirect the root after preview: descriptors never follow the redirected path.
    let rootCandidate = try scan().candidates[0], redirected = try engine.prepare(rootCandidate)
    try fm.moveItem(atPath: root.path, toPath: home + "/held-root")
    try fm.createSymbolicLink(atPath: root.path, withDestinationPath: home + "/held-root")
    blocked { try engine.move(redirected, settings: settings, processes: [], now: now) }
    try fm.removeItem(atPath: root.path)
    try fm.moveItem(atPath: home + "/held-root", toPath: root.path)
    let cancel = try engine.prepare(try scan().candidates[0])
    let worker = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        try engine.move(cancel, settings: settings, processes: [], now: now)
    }
    do { try await worker.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { }
    try cleanupExpect(fm.fileExists(atPath: original))
    // Cancellation after the rename retains the whole item and a durable receipt.
    let lateCancel = try engine.prepare(try scan().candidates[0])
    let lateWorker = Task.detached {
        try engine.move(lateCancel, settings: settings, processes: [], now: now, afterRename: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    do { _ = try await lateWorker.value; preconditionFailure("Late cancellation ignored") } catch is CancellationError { }
    try cleanupExpect(!fm.fileExists(atPath: original) && fm.fileExists(atPath: lateCancel.recoveryPath))
    try engine.restore(lateCancel, processes: [])
    let tamper = try engine.prepare(try scan().candidates[0])
    try engine.move(tamper, settings: settings, processes: [], now: now)
    try file(tamper.recoveryPath + "/cache.bin", 17)
    blocked { try engine.restore(tamper, processes: []) } // unverified content never restored automatically
    try cleanupExpect(!fm.fileExists(atPath: original) && fm.fileExists(atPath: tamper.recoveryPath))
    // Permission-limited/special objects and protected categories remain unknown/kept.
    let permission = root.path + "/unreadable"
    try file(permission)
    chmod(permission, 0)
    try cleanupExpect(!((try scan()).candidates.contains { $0.path == permission }))
    chmod(permission, 0o600)
    let forbidden = CleanupRoot(path: home + "/Documents", category: .developerCaches, owners: ["node"])
    try cleanupExpect(try engine.scan(roots: [forbidden], settings: settings, processes: [], now: now).candidates.isEmpty)
    settings.categories = [.derivedData, .appLogs]
    let dd = CleanupRoot(path: home + "/Library/Developer/Xcode/DerivedData", category: .derivedData, owners: ["Xcode"])
    try file(dd.path + "/project/Build/cache")
    try cleanupExpect(try engine.scan(roots: [dd], settings: settings, processes: [], now: now).candidates.isEmpty)
    // APFS/container attribution and the observed real incident stay mathematically separate.
    let a = CleanupVolume(id: 1, path: "/main", name: "Main", free: 39_239_680_000, total: 500_000_000_000, importantAvailable: 45_000_000_000, measuredAt: now)
    let b = CleanupVolume(id: 1, path: "/main", name: "Main", free: 45_056_000_000, total: a.total, importantAvailable: nil, measuredAt: now)
    try cleanupExpect(b.free - a.free == 5_816_320_000 && b.free - a.free != 6_263_226_368)
    try cleanupExpect(a.purgeableEstimate == 5_760_320_000 && b.purgeableEstimate == nil)
    try cleanupExpect(CleanupVolume.delta(before: [a], after: []).first!.contains("unknown"))
    let sourceTopology = CleanupTopology(volumeUUID: "source", containerUUID: "shared", physicalStores: ["store-a"], physicalDevices: ["disk-a"], externalPhysical: false)
    let sharedTopology = CleanupTopology(volumeUUID: "different-volume", containerUUID: "shared", physicalStores: ["store-a"], physicalDevices: ["disk-a"], externalPhysical: true)
    let sameStore = CleanupTopology(volumeUUID: "different-volume", containerUUID: "different-container", physicalStores: ["store-a"], physicalDevices: ["disk-a"], externalPhysical: true)
    let differentPartition = CleanupTopology(volumeUUID: "different-volume", containerUUID: "different-container", physicalStores: ["another-partition"], physicalDevices: ["disk-a"], externalPhysical: true)
    let external = CleanupTopology(volumeUUID: "external", containerUUID: "external-container", physicalStores: ["store-b"], physicalDevices: ["disk-b"], externalPhysical: true)
    let virtual = CleanupTopology(volumeUUID: "image", containerUUID: "image-container", physicalStores: ["image-store"], physicalDevices: ["image-device"], externalPhysical: false)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: sharedTopology)?.contains("share a container") == true)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: sameStore)?.contains("share physical") == true)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: differentPartition)?.contains("share physical") == true)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: nil)?.contains("unknown") == true)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: nil, destination: external)?.contains("unknown") == true)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: virtual) != nil)
    try cleanupExpect(CleanupTopology.externalCopyBlock(source: sourceTopology, destination: external) == nil)
    try cleanupExpect(CleanupTopology.read(home + "/missing") == nil && CleanupReclaimSafety.blockers.count == 3)
    var outcome = CleanupRecord(automatic: false)
    try cleanupExpect(outcome.outcomeLabel.contains("Incomplete"))
    outcome.finished = true
    outcome.items = [.init(path: "/fixture/blocked", deleted: false, bytes: 0, reason: "Blocked")]
    try cleanupExpect(outcome.outcomeLabel.contains("No items completed"))
    outcome.items.append(.init(path: "/fixture/moved", deleted: true, bytes: 8192, reason: "Moved"))
    try cleanupExpect(outcome.outcomeLabel.contains("Partially completed"))
    outcome.items.removeFirst()
    try cleanupExpect(outcome.outcomeLabel == "Finished")
    print("PASS: APFS shared-container, shared-physical-store, virtual and unknown destination fail closed; distinct physical external identity accepted for copy only")
    print("PASS: recoverable cleanup SHA256, retention, active builds/updates/open files, exclusions, symlink/hardlink/permission protection, post-scan change, final path/root swap, cancellation, repeat, restore collision/tampering, protected DerivedData, measured capacity separated from allocated sum")
}

@MainActor func autoCleanupSettingsSelfTest() throws {
    let suite = "RetroStats.CleanupSettings." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    var legacy = AutoCleanupSettings(); legacy.enabled = true; legacy.exclusions = ["/fixture/keep"]
    defaults.set(try JSONEncoder().encode(legacy), forKey: "storageAutoCleanup.v1")
    let controller = AutoCleanupController(defaults: defaults, support: support, allowOperations: true, changed: {})
    try cleanupExpect(!controller.settings.enabled && controller.settings.excludes("/fixture/keep/x"))
    controller.setEnabled(true); controller.setInterval(7)
    let restored = AutoCleanupController(defaults: defaults, support: support, allowOperations: false, changed: {})
    try cleanupExpect(restored.settings.enabled && restored.settings.intervalDays == 7)
    restored.preview(); restored.tick(now: .distantFuture); restored.confirmMove()
    try cleanupExpect(!restored.busy && restored.scan == nil && !FileManager.default.fileExists(atPath: support.path))
    controller.stop()
    print("PASS: legacy destructive schedule migrated off, delayed preview opt-in, persistence, inert services-disabled controller")
}

@MainActor func autoCleanupControllerSelfTest() throws {
    let fm = FileManager.default
    let home = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)! + "/cleanup-controller-" + UUID().uuidString
    try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: home) }
    let root = CleanupRoot(path: home + "/Library/Caches/pip", category: .developerCaches, owners: ["python3"])
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    for name in ["a.bin", "b.bin", "c.bin", "unselected.bin"] { try Data(repeating: 42, count: 8192).write(to: URL(fileURLWithPath: root.path + "/" + name)) }
    let suite = "RetroStats.CleanupController." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let date = Date().addingTimeInterval(90 * 86400), support = URL(fileURLWithPath: home + "/support")
    let controller = AutoCleanupController(defaults: defaults, support: support, allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { date }, changed: {})
    func settle(_ target: AutoCleanupController) throws {
        let deadline = Date().addingTimeInterval(10)
        while target.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !target.busy else { target.stop(); throw AutoCleanupEngine.Failure.blocked("Fixture timeout") }
    }
    controller.preview(); controller.preview(); try settle(controller)
    try cleanupExpect(controller.candidateCount == 4 && controller.selected.isEmpty)
    controller.confirmMove(); try cleanupExpect(!controller.busy)
    controller.select(root.path + "/a.bin", enabled: true)
    controller.select(root.path + "/b.bin", enabled: true)
    controller.select(root.path + "/c.bin", enabled: true)
    // Partial batch: b changes after review, a still succeeds, unselected remains.
    try Data([99]).write(to: URL(fileURLWithPath: root.path + "/b.bin"))
    controller.confirmMove(); try settle(controller)
    let record = controller.history[0]
    try cleanupExpect(record.finished && record.deletedCount == 2 && record.items.count == 3)
    try cleanupExpect(record.before != nil && record.after != nil)
    try cleanupExpect(!fm.fileExists(atPath: root.path + "/a.bin") && fm.fileExists(atPath: root.path + "/b.bin") && fm.fileExists(atPath: root.path + "/unselected.bin"))
    let loaded = AutoCleanupController(defaults: defaults, support: support, allowOperations: false, changed: {})
    try cleanupExpect(loaded.history[0].items.contains { $0.receipt != nil })
    let index = record.items.firstIndex { $0.path == root.path + "/a.bin" }!
    controller.restore(recordID: record.id, index: index); try settle(controller)
    try cleanupExpect(fm.fileExists(atPath: root.path + "/a.bin") && controller.history[0].items[index].restored == true)
    controller.setEnabled(true); controller.tick(now: date.addingTimeInterval(86400)); try settle(controller)
    try cleanupExpect(fm.fileExists(atPath: root.path + "/a.bin") && controller.history.count == 1) // scheduled preview only
    // More than 20 later completed records must not hide unresolved recovery.
    var many = (0..<25).map { _ in CleanupRecord(automatic: false, finished: true) }
    many.append(controller.history[0])
    try JSONEncoder().encode(many).write(to: controller.historyURL)
    let longHistory = AutoCleanupController(defaults: defaults, support: support, allowOperations: false, changed: {})
    try cleanupExpect(longHistory.history.count == 26 && longHistory.history.last!.items.contains { $0.receipt != nil && $0.restored != true })
    controller.stop()
    // Durable journal failure prevents moves, even after selection.
    let badSupport = home + "/not-a-directory"; try Data([1]).write(to: URL(fileURLWithPath: badSupport))
    let blocked = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: badSupport), allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { date }, changed: {})
    blocked.preview(); try settle(blocked)
    try cleanupExpect(blocked.scan == nil && blocked.error != nil && fm.fileExists(atPath: root.path + "/a.bin")); blocked.stop()
    let outsideJournal = home + "/Documents/keep-history"
    try fm.createDirectory(atPath: outsideJournal, withIntermediateDirectories: true)
    let witness = outsideJournal + "/auto-cleanup-preview.txt"
    try Data([77]).write(to: URL(fileURLWithPath: witness))
    try fm.createSymbolicLink(atPath: home + "/support-link", withDestinationPath: outsideJournal)
    let redirectedJournal = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/support-link"), allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { date }, changed: {})
    redirectedJournal.preview(); try settle(redirectedJournal)
    try cleanupExpect(redirectedJournal.error != nil && redirectedJournal.scan == nil)
    try cleanupExpect(try Data(contentsOf: URL(fileURLWithPath: witness)) == Data([77]))
    redirectedJournal.stop()
    let failed = AutoCleanupController(defaults: defaults, support: support, allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { throw AutoCleanupEngine.Failure.blocked("Unknown process query") }, now: { date }, changed: {})
    failed.preview(); try settle(failed)
    try cleanupExpect(failed.error != nil && failed.scan == nil); failed.stop()
    let cancelled = AutoCleanupController(defaults: defaults, support: support, allowOperations: true,
        engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { try await Task.sleep(for: .seconds(60)); return [] }, now: { date }, changed: {})
    cancelled.preview(); cancelled.cancel(); try settle(cancelled)
    try cleanupExpect(cancelled.error != nil && fm.fileExists(atPath: root.path + "/a.bin")); cancelled.stop()
    print("PASS: cleanup controller explicit selection, partial failure, durable receipts/history/reload, measured volume snapshots, restoration, schedule preview only, journal/query failure, cancellation")
}
