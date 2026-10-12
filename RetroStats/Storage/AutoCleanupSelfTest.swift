import Foundation

/// Only synthetic files under a unique temporary home are ever removed.
func autoCleanupSelfTest() async throws {
    let fm = FileManager.default
    let base = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)!
    let temporaryHome = URL(fileURLWithPath: base + "/auto-cleanup-test-" + UUID().uuidString)
    try fm.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporaryHome) }
    let home = temporaryHome.path, engine = AutoCleanupEngine(home: temporaryHome.path)
    let now = Date().addingTimeInterval(90 * 86400)
    var settings = AutoCleanupSettings()
    precondition(!settings.enabled && !settings.isDue(at: now))
    settings.enabled = true; settings.lastAttempt = now
    precondition(!settings.isDue(at: now.addingTimeInterval(86400 - 1)))
    precondition(settings.isDue(at: now.addingTimeInterval(86400)))
    settings.intervalDays = 7
    precondition(!settings.isDue(at: now.addingTimeInterval(6 * 86400)))
    precondition(settings.isDue(at: now.addingTimeInterval(7 * 86400)))
    settings.exclusions = [home + "/keep"]
    precondition(settings.excludes(home + "/keep/file"))
    precondition(!settings.excludes(home + "/keep-other"))
    settings.exclusions = ["/"]
    precondition(settings.excludes(home + "/anything"))
    precondition(AutoCleanupEngine.exclusionPath("/fixture/keep/../safe/") == "/fixture/safe")
    precondition(AutoCleanupEngine.exclusionPath("relative/path") == nil)
    settings.exclusions = []
    let cacheRoot = CleanupRoot(path: home + "/Library/Caches/com.example.fixture", category: .appCaches, owners: ["FixtureApp"])
    let logsRoot = CleanupRoot(path: home + "/Library/Logs/com.example.fixture", category: .appLogs, owners: ["FixtureApp"])
    let ddRoot = CleanupRoot(path: home + "/Library/Developer/Xcode/DerivedData", category: .derivedData, owners: ["Xcode", "xcodebuild"])
    for root in [cacheRoot, logsRoot, ddRoot] { try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true) }
    func file(_ path: String, modified: Date? = nil) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: URL(fileURLWithPath: path))
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
    }
    func scan(_ roots: [CleanupRoot] = [cacheRoot], _ config: AutoCleanupSettings = settings) throws -> CleanupScan {
        try engine.scan(roots: roots, settings: config, processes: [], now: now)
    }
    func blocked(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Unsafe cleanup was allowed") } catch { }
    }
    let stale = cacheRoot.path + "/old"
    try file(stale + "/nested/cache.bin")
    let recent = cacheRoot.path + "/recent.bin"
    try file(recent, modified: now.addingTimeInterval(-86400))
    let tenDayCache = cacheRoot.path + "/ten-days.bin"
    try file(tenDayCache, modified: now.addingTimeInterval(-10 * 86400))
    let tenDayLog = logsRoot.path + "/ten-days.log"
    try file(tenDayLog, modified: now.addingTimeInterval(-10 * 86400))
    let oldLog = logsRoot.path + "/old.log"
    try file(oldLog)
    let outside = home + "/Documents/precious.txt"
    try file(outside)
    try fm.createSymbolicLink(atPath: cacheRoot.path + "/linked", withDestinationPath: outside)
    let linkedTree = cacheRoot.path + "/linked-tree"
    try file(linkedTree + "/cache.bin")
    try fm.createSymbolicLink(atPath: linkedTree + "/outside", withDestinationPath: outside)
    try fm.linkItem(atPath: outside, toPath: cacheRoot.path + "/hardlink")
    var report = try scan([cacheRoot, logsRoot])
    guard Set(report.candidates.map(\.path)) == Set([stale, tenDayCache, oldLog]) else {
        throw AutoCleanupEngine.Failure.blocked("Unexpected fixture candidates: \(report.candidates.map(\.path)); skipped: \(report.skipped)")
    }
    precondition(!report.skipped.isEmpty && report.bytes > 0)
    let active = try engine.scan(roots: [cacheRoot], settings: settings, processes: ["/Applications/Fixture.app/Contents/MacOS/FixtureApp"], now: now)
    precondition(active.candidates.isEmpty && !active.skipped.isEmpty)
    precondition(AutoCleanupEngine.active(cacheRoot, processes: ["FixtureApp"]))
    let unowned = CleanupRoot(path: cacheRoot.path, category: .appCaches, owners: [])
    let unownedReport = try engine.scan(roots: [unowned], settings: settings, processes: [], now: now)
    precondition(unownedReport.candidates.isEmpty)
    let forbidden = CleanupRoot(path: home + "/Documents", category: .appCaches, owners: ["FixtureApp"])
    let forbiddenReport = try scan([forbidden])
    precondition(forbiddenReport.candidates.isEmpty)
    var excluded = settings
    excluded.exclusions = [stale + "/nested/cache.bin"]
    let excludedReport = try scan([cacheRoot], excluded)
    precondition(!excludedReport.candidates.contains { $0.path == stale })
    let candidate = report.candidates.first { $0.path == stale }!
    blocked { try engine.delete(candidate, settings: settings, processes: ["FixtureApp"], now: now) }
    blocked { try engine.delete(candidate, settings: excluded, processes: [], now: now) }
    // Modification after review, even if still old enough, must invalidate identity.
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-15 * 86400)], ofItemAtPath: stale + "/nested/cache.bin")
    blocked { try engine.delete(candidate, settings: settings, processes: [], now: now) }
    report = try scan()
    let refreshed = report.candidates.first { $0.path == stale }!
    try engine.delete(refreshed, settings: settings, processes: [], now: now)
    precondition(!fm.fileExists(atPath: stale))
    precondition(fm.fileExists(atPath: recent) && fm.fileExists(atPath: outside))
    precondition(fm.fileExists(atPath: linkedTree + "/cache.bin"))
    // Inode replacement after preview.
    let swap = try scan().candidates.first { $0.path == tenDayCache }!
    try fm.moveItem(atPath: tenDayCache, toPath: home + "/saved-cache")
    try file(tenDayCache)
    blocked { try engine.delete(swap, settings: settings, processes: [], now: now) }
    // A redirected root after preview is rejected and never followed.
    let logCandidate = try scan([logsRoot]).candidates.first { $0.path == oldLog }!
    try fm.moveItem(atPath: logsRoot.path, toPath: home + "/saved-logs")
    try fm.createSymbolicLink(atPath: logsRoot.path, withDestinationPath: home + "/saved-logs")
    blocked { try engine.delete(logCandidate, settings: settings, processes: [], now: now) }
    precondition(fm.fileExists(atPath: home + "/saved-logs/old.log"))

    // DerivedData keeps its distinct 8-hour rule and excludes shared/unknown data.
    let project = ddRoot.path + "/project"
    try file(project + "/Build/cache")
    let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/fixture/App.xcodeproj"], format: .xml, options: 0)
    try plist.write(to: URL(fileURLWithPath: project + "/info.plist"))
    try fm.createDirectory(atPath: ddRoot.path + "/ModuleCache.noindex", withIntermediateDirectories: true)
    try file(ddRoot.path + "/unknown/keep.txt")
    let derived = try scan([ddRoot])
    precondition(derived.candidates.map(\.path) == [project])
    try engine.delete(derived.candidates[0], settings: settings, processes: [], now: now)
    precondition(!fm.fileExists(atPath: project))
    precondition(fm.fileExists(atPath: ddRoot.path + "/unknown/keep.txt"))
    precondition(fm.fileExists(atPath: ddRoot.path + "/ModuleCache.noindex"))
    // Cancellation before delete cannot remove the selected file.
    let cancelCandidate = try scan().candidates.first { $0.path == tenDayCache }!
    let worker = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        try engine.delete(cancelCandidate, settings: settings, processes: [], now: now)
    }
    do { try await worker.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { }
    precondition(fm.fileExists(atPath: tenDayCache))
    print("PASS: auto cleanup daily/weekly schedule, retention, active/unknown owners, exclusions, scoped deletion, identity recheck, nested symlink/hardlink protection, redirected roots, DerivedData protections, cancellation")
}

@MainActor func autoCleanupSettingsSelfTest() throws {
    let name = "RetroStats.AutoCleanupTest." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let controller = AutoCleanupController(defaults: defaults, support: support, allowOperations: true, changed: {})
    precondition(!controller.settings.enabled)
    controller.setEnabled(true)
    controller.setInterval(7)
    controller.setCategory(.appLogs, enabled: false)
    controller.exclude("/fixture/keep")
    precondition(!controller.busy && controller.settings.nextRun! > Date())
    let restored = AutoCleanupController(defaults: defaults, support: support, allowOperations: false, changed: {})
    precondition(restored.settings.enabled && restored.settings.intervalDays == 7)
    precondition(!restored.settings.categories.contains(.appLogs) && restored.settings.excludes("/fixture/keep/cache"))
    restored.preview(); restored.tick(now: Date.distantFuture); restored.confirmDeletion()
    precondition(!restored.busy && restored.scan == nil && !FileManager.default.fileExists(atPath: support.path))
    controller.stop()
    print("PASS: auto cleanup opt-in, delayed first run, settings persistence, inert preview/services-disabled controller")
}

@MainActor func autoCleanupControllerSelfTest() throws {
    let fm = FileManager.default
    let home = AutoCleanupEngine.canonicalPath(fm.temporaryDirectory.path)! + "/auto-controller-" + UUID().uuidString
    try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: home) }
    let root = CleanupRoot(path: home + "/Library/Caches/com.example.fixture", category: .appCaches, owners: ["FixtureApp"])
    try fm.createDirectory(atPath: root.path, withIntermediateDirectories: true)
    let path = root.path + "/old.bin"
    try Data(repeating: 42, count: 8192).write(to: URL(fileURLWithPath: path))
    let suite = "RetroStats.AutoController." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let date = Date().addingTimeInterval(90 * 86400)
    let controller = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/support"),
        allowOperations: true, engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { date }, changed: {})
    func settle(_ target: AutoCleanupController) throws {
        let deadline = Date().addingTimeInterval(5)
        while target.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !target.busy else { target.stop(); throw AutoCleanupEngine.Failure.blocked("Controller fixture timed out") }
    }
    // Main-run-loop integration: preview is read-only, duplicate starts are ignored,
    // then a concrete confirmation deletes only that reviewed synthetic snapshot.
    controller.preview(); controller.preview()
    try settle(controller)
    precondition(controller.candidateCount == 1 && fm.fileExists(atPath: path))
    precondition(fm.fileExists(atPath: controller.previewURL.path))
    controller.confirmDeletion()
    try settle(controller)
    precondition(!fm.fileExists(atPath: path))
    precondition(controller.history.count == 1 && controller.history[0].finished && !controller.history[0].automatic)
    precondition(controller.history[0].deletedCount == 1 && controller.history[0].freedBytes > 0)

    try Data(repeating: 42, count: 8192).write(to: URL(fileURLWithPath: path))
    controller.setEnabled(true)
    controller.tick(now: date)
    precondition(!controller.busy && fm.fileExists(atPath: path))
    controller.canRun = { false }
    controller.tick(now: date.addingTimeInterval(86400))
    precondition(!controller.busy && controller.settings.lastAttempt == date)
    controller.canRun = { true }
    controller.tick(now: date.addingTimeInterval(86400))
    controller.tick(now: date.addingTimeInterval(86400))
    try settle(controller)
    precondition(!fm.fileExists(atPath: path))
    precondition(controller.history.count == 2 && controller.history[0].automatic && controller.history[0].finished)
    let restored = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/support"), allowOperations: false, changed: {})
    precondition(restored.history.count == 2 && restored.history[0].automatic && restored.history[0].finished)
    controller.tick(now: date.addingTimeInterval(86400))
    precondition(!controller.busy) // The same schedule cannot start twice.
    controller.stop()

    // Process-query failure is fail-closed and creates an incomplete history entry.
    try Data(repeating: 42, count: 8192).write(to: URL(fileURLWithPath: path))
    let failing = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/failure"),
        allowOperations: true, engine: AutoCleanupEngine(home: home), roots: { [root] },
        processes: { throw AutoCleanupEngine.Failure.blocked("Process query fixture failure") }, now: { date }, changed: {})
    failing.tick(now: date.addingTimeInterval(3 * 86400))
    try settle(failing)
    precondition(fm.fileExists(atPath: path) && failing.error != nil)
    precondition(failing.history.first?.finished == false && failing.history.first?.deletedCount == 0)
    failing.stop()

    // A failed durable start marker must prevent every deletion.
    let blockedSupport = home + "/not-a-directory"
    try Data([1]).write(to: URL(fileURLWithPath: blockedSupport))
    let noHistory = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: blockedSupport),
        allowOperations: true, engine: AutoCleanupEngine(home: home), roots: { [root] }, processes: { [] }, now: { date }, changed: {})
    noHistory.tick(now: date.addingTimeInterval(5 * 86400))
    try settle(noHistory)
    precondition(fm.fileExists(atPath: path) && noHistory.error != nil && noHistory.history.isEmpty)
    noHistory.stop()

    // Cancellation propagates through a suspended process query.
    let cancelling = AutoCleanupController(defaults: defaults, support: URL(fileURLWithPath: home + "/cancel"),
        allowOperations: true, engine: AutoCleanupEngine(home: home), roots: { [root] },
        processes: { try await Task.sleep(for: .seconds(60)); return [] }, now: { date }, changed: {})
    cancelling.tick(now: date.addingTimeInterval(7 * 86400))
    cancelling.cancel()
    try settle(cancelling)
    precondition(fm.fileExists(atPath: path) && cancelling.history.first?.finished == false && cancelling.error != nil)
    cancelling.stop()
    print("PASS: auto cleanup controller read-only preview, explicit confirmation, persisted/reloaded results, due execution, mutual exclusion, duplicate schedule suppression, process-query failure, history-write failure, cancellation")
}
