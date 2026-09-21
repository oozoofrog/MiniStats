import Foundation

/// Native regression tests for DerivedDataCleaner, porting the behavioral
/// cases from the former tests/test_deriveddata.py. Runs only on --self-test
/// against temporary directories; never touches real DerivedData.
func derivedDataSelfTest() async throws {
    let cleaner = DerivedDataCleaner()
    let tmp = (FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path as NSString)
        .appendingPathComponent("dd-selftest-" + UUID().uuidString)
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let root = (tmp as NSString).appendingPathComponent("DerivedData")
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let old = Date().timeIntervalSince1970 - 60 * 86400
    let cutoff = Date().timeIntervalSince1970 - 30 * 86400

    func ageTree(_ path: String) {
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for e in entries { ageTree((path as NSString).appendingPathComponent(e)) }
        }
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: old)], ofItemAtPath: path)
    }

    func makeCache(_ name: String, accessed: TimeInterval = old, size: Int = 8192) throws -> String {
        let path = (root as NSString).appendingPathComponent(name)
        let products = (path as NSString).appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: true)
        let app = (products as NSString).appendingPathComponent("app")
        try Data(count: size).write(to: URL(fileURLWithPath: app))
        let infoPath = (path as NSString).appendingPathComponent("info.plist")
        let plist: [String: Any] = [
            "WorkspacePath": "/projects/Example.xcodeproj",
            "LastAccessedDate": Date(timeIntervalSince1970: accessed),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: infoPath))
        ageTree(path)
        return path
    }

    // Eligibility fixtures.
    let stale = try makeCache("stale-project")
    let recentFile = try makeCache("recent-file")
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: (recentFile as NSString).appendingPathComponent("Build/Products/app"))
    let recentAccess = try makeCache("recent-access", accessed: Date().timeIntervalSince1970)
    let within8 = try makeCache("within-eight", accessed: Date().timeIntervalSince1970 - 7 * 3600)
    let past8 = try makeCache("past-eight", accessed: Date().timeIntervalSince1970 - 9 * 3600)

    // Logs-only project cache (name matches regex, has Logs dir).
    let logsOnly = (root as NSString).appendingPathComponent("LogsOnly-" + String(repeating: "a", count: 28))
    try FileManager.default.createDirectory(atPath: (logsOnly as NSString).appendingPathComponent("Logs"), withIntermediateDirectories: true)
    ageTree(logsOnly)

    // Shared cache and unknown dir.
    let shared = (root as NSString).appendingPathComponent("ModuleCache.noindex")
    try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
    ageTree(shared)
    let unknown = (root as NSString).appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(atPath: unknown, withIntermediateDirectories: true)
    ageTree(unknown)

    // Symlinked project cache (must not be followed/deleted).
    let outside = (tmp as NSString).appendingPathComponent("outside")
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try "keep".write(to: URL(fileURLWithPath: (outside as NSString).appendingPathComponent("keep.txt")), atomically: true, encoding: .utf8)
    let linked = (root as NSString).appendingPathComponent("linked-project")
    try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: outside)

    func insp(_ p: String) -> DerivedDataCleaner.Inspected { try! cleaner.inspect(path: p) }

    precondition(cleaner.eligible(insp(stale), cutoff: cutoff, includeShared: false))
    precondition(insp(stale).size >= 8192)
    precondition(!cleaner.eligible(insp(recentFile), cutoff: cutoff, includeShared: false))
    precondition(!cleaner.eligible(insp(recentAccess), cutoff: cutoff, includeShared: false))
    precondition(cleaner.eligible(insp(logsOnly), cutoff: cutoff, includeShared: false))
    precondition(!cleaner.eligible(insp(shared), cutoff: cutoff, includeShared: false))
    precondition(cleaner.eligible(insp(shared), cutoff: cutoff, includeShared: true))
    precondition(!cleaner.eligible(insp(unknown), cutoff: cutoff, includeShared: true))
    precondition(!cleaner.eligible(insp(linked), cutoff: cutoff, includeShared: true))

    // 8-hour cutoff semantics.
    let cutoff8 = Date().timeIntervalSince1970 - 8 * 3600
    precondition(cleaner.eligible(insp(past8), cutoff: cutoff8, includeShared: false))
    precondition(!cleaner.eligible(insp(within8), cutoff: cutoff8, includeShared: false))

    // Report at the app's real 8-hour cutoff: stale, past8, logsOnly are candidates.
    let report = try await cleaner.scan(roots: [root], hours: 8, includeShared: false)
    precondition(report.hours == 8)
    precondition(report.items.allSatisfy { $0.size >= 0 && $0.path.hasPrefix("/") })
    precondition(report.totalBytes == report.items.reduce(Int64(0)) { $0 + $1.size })
    precondition(report.candidateBytes == report.items.filter(\.candidate).reduce(Int64(0)) { $0 + $1.size })
    let candidatePaths = Set(report.candidates.map(\.path))
    precondition(candidatePaths == Set([stale, past8, logsOnly]))

    // Selected-only deletion: delete only `stale`, keep `logsOnly` and `past8`.
    var events: [CleanEvent] = []
    try await cleaner.clean(paths: [stale], hours: 8, includeShared: false, idleCheck: {}) { events.append($0) }
    precondition(!FileManager.default.fileExists(atPath: stale))
    precondition(FileManager.default.fileExists(atPath: logsOnly))
    precondition(events.contains { if case .deleted(let p, _) = $0 { return p == stale } else { return false } })

    // Recheck-keeps: a selected path whose mtime became recent is kept, not deleted.
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: (logsOnly as NSString).appendingPathComponent("Logs"))
    events.removeAll()
    try await cleaner.clean(paths: [logsOnly], hours: 8, includeShared: false, idleCheck: {}) { events.append($0) }
    precondition(FileManager.default.fileExists(atPath: logsOnly))
    precondition(events.contains { if case .kept(let p) = $0 { return p == logsOnly } else { return false } })

    // Shared cleanup: include-shared removes the old shared cache.
    try await cleaner.clean(paths: [shared], hours: 8, includeShared: true, idleCheck: {}) { _ in }
    precondition(!FileManager.default.fileExists(atPath: shared))
    precondition(FileManager.default.fileExists(atPath: within8))
    precondition(FileManager.default.fileExists(atPath: past8))

    // Hours=6 removes within8 (7h old).
    try await cleaner.clean(paths: [within8], hours: 6, includeShared: false, idleCheck: {}) { _ in }
    precondition(!FileManager.default.fileExists(atPath: within8))

    // Symlink and outside survive all cleans.
    precondition(FileManager.default.fileExists(atPath: (outside as NSString).appendingPathComponent("keep.txt")))
    let linkType = try FileManager.default.attributesOfItem(atPath: linked)[.type] as? FileAttributeType
    precondition(linkType == .typeSymbolicLink)

    // Broken info.plist aborts inspect (and thus scan).
    let broken = (root as NSString).appendingPathComponent("broken")
    try FileManager.default.createDirectory(atPath: broken, withIntermediateDirectories: true)
    try "broken plist".write(to: URL(fileURLWithPath: (broken as NSString).appendingPathComponent("info.plist")), atomically: true, encoding: .utf8)
    precondition((try? cleaner.inspect(path: broken)) == nil)

    print("PASS: DerivedData inspect/eligibility, report, selected-only deletion, recheck-keeps, shared cleanup, hours cutoff, symlink safety, broken-plist abort")
}

/// `--bench-cleanup [items]`: times the clean loop over synthetic paths with the
/// filesystem stubbed out (recheck returns a stale cache, remove is a no-op),
/// so only the per-item orchestration and event delivery are measured.
func derivedDataBenchmark(items: Int) async throws {
    let cleaner = DerivedDataCleaner()
    let paths = (0..<items).map { "/bench/DerivedData/Cache-\($0)" }
    let stale = { (path: String) in DerivedDataCleaner.Inspected(path: path, size: 1024, latest: 0, kind: .project, workspace: "") }
    var events = 0
    let elapsed = try await ContinuousClock().measure {
        try await cleaner.clean(paths: paths, hours: 8, includeShared: false, idleCheck: {}, recheck: stale, remove: { _ in }) { _ in events += 1 }
    }
    precondition(events == items + 1, "one event per item plus done")
    print("BENCH clean loop items=\(items) total=\(elapsed) per-item=\(elapsed / items)")
}
