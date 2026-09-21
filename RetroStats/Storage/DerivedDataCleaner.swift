import Foundation
import Darwin

/// Native DerivedData capacity scan and cleanup, replacing the former Python
/// subprocess. Semantics mirror deriveddata.py: allocated-block sizing via
/// lstat, no symlink traversal, cross-device rejection, info.plist-based
/// classification, 8-hour eligibility, per-delete recheck, and Xcode/xcodebuild
/// idle guard. Scans run concurrently with Swift Concurrency.
struct DerivedDataCleaner {
    enum Kind: String { case project = "Project", shared = "Shared", other = "Other" }

    enum CleanerError: Error, LocalizedError {
        case crossDevice(String)
        case xcodeRunning(String)
        case pathChanged(String)
        case brokenPlist(String)
        case invalidWorkspace(String)
        case deleteBlocked(String)

        var errorDescription: String? {
            switch self {
            case .crossDevice(let p): return "Skipping because it contains another filesystem: \(p)"
            case .xcodeRunning(let s): return "Close these processes before cleaning: \(s)"
            case .pathChanged(let p): return "The deletion path changed or is a mount point: \(p)"
            case .brokenPlist(let p): return "Could not parse info.plist: \(p)"
            case .invalidWorkspace(let p): return "WorkspacePath is not a string: \(p)"
            case .deleteBlocked(let p): return "Safe deletion is not allowed: \(p)"
            }
        }
    }

    static let sharedNames: Set<String> = [
        "ModuleCache.noindex", "CompilationCache.noindex", "SDKStatCaches.noindex",
        "SDKExplicitPrecompiledModules", "SymbolCache.noindex",
    ]

    // MARK: - Public API

    /// Scan the given roots (each a DerivedData parent folder or a single cache)
    /// and return a report. Throws on the first cache that cannot be inspected
    /// (cross-device, broken info.plist). `scanning` is invoked with each path
    /// as it begins inspection, so callers can show live progress.
    func scan(roots: [String], hours: Int, includeShared: Bool,
              scanning: ((String) -> Void)? = nil) async throws -> CacheReport {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Double(hours) * 3600
        let paths = try collectScanPaths(roots: roots)
        let items = try await inspectAll(paths: paths, scanning: scanning)
        return buildReport(items: items, now: now, hours: hours, cutoff: cutoff, includeShared: includeShared)
    }

    /// Delete the given paths after re-inspecting each. Emits progress events.
    /// Sequential per item (each delete re-validates idleness and eligibility);
    /// cancellation is honored between items.
    func clean(paths: [String], hours: Int, includeShared: Bool,
               idleCheck: () throws -> Void = DerivedDataCleaner.ensureIdle,
               progress: @escaping @Sendable (CleanEvent) -> Void) async throws {
        let cutoff = Date().timeIntervalSince1970 - Double(hours) * 3600
        var removed = 0
        var freed: Int64 = 0
        for path in paths {
            try Task.checkCancellation()
            try idleCheck()
            try verifySafeDeletePath(path)
            let fresh = try inspect(path: path)
            if eligible(fresh, cutoff: cutoff, includeShared: includeShared) {
                try FileManager.default.removeItem(atPath: path)
                removed += 1
                freed += fresh.size
                progress(.deleted(path: path, size: fresh.size))
            } else {
                progress(.kept(path: path))
            }
        }
        progress(.done(removed: removed, freedBytes: freed))
    }

    // MARK: - Inspect

    struct Inspected {
        let path: String
        let size: Int64
        let latest: TimeInterval
        let kind: Kind
        let workspace: String
    }

    /// Recursively size a cache by allocated blocks without following symlinks.
    /// A vanished entry during the walk marks the cache as freshly modified.
    func inspect(path: String) throws -> Inspected {
        var initial = stat()
        guard lstat(path, &initial) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Scan failed: \(path)"])
        }
        let initialDev = initial.st_dev
        let now = Date().timeIntervalSince1970
        var size: Int64 = 0
        var latest = mtime(initial)
        var seen = Set<DevIno>()
        var pending: [String] = [path]
        let fm = FileManager.default
        while let current = pending.popLast() {
            var item = stat()
            if lstat(current, &item) != 0 {
                latest = max(latest, now)
                continue
            }
            if item.st_dev != initialDev { throw CleanerError.crossDevice(current) }
            latest = max(latest, mtime(item))
            let key = DevIno(dev: item.st_dev, ino: item.st_ino)
            if seen.contains(key) { continue }
            seen.insert(key)
            size += Int64(item.st_blocks) * 512
            if (item.st_mode & S_IFMT) == S_IFDIR {
                if let entries = try? fm.contentsOfDirectory(atPath: current) {
                    pending.append(contentsOf: entries.map { (current as NSString).appendingPathComponent($0) })
                } else {
                    latest = max(latest, now)
                }
            }
        }
        return try classify(path: path, initial: initial, size: size, latest: latest)
    }

    private struct DevIno: Hashable { let dev: dev_t; let ino: ino_t }

    private func mtime(_ st: stat) -> TimeInterval {
        TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    private func classify(path: String, initial: stat, size: Int64, latest: TimeInterval) throws -> Inspected {
        var latestTime = latest
        var kind = Kind.other
        var workspace = ""
        if (initial.st_mode & S_IFMT) == S_IFDIR {
            let infoPath = (path as NSString).appendingPathComponent("info.plist")
            var infoSt = stat()
            if lstat(infoPath, &infoSt) == 0 && (infoSt.st_mode & S_IFMT) == S_IFLNK {
                throw CleanerError.brokenPlist(infoPath)
            }
            let info = try readPlist(infoPath)
            if let ws = info["WorkspacePath"] {
                guard let wsString = ws as? String else { throw CleanerError.invalidWorkspace(infoPath) }
                workspace = wsString
            }
            if let accessed = info["LastAccessedDate"] as? Date {
                latestTime = max(latestTime, accessed.timeIntervalSince1970)
            } else if info["LastAccessedDate"] != nil {
                throw CleanerError.brokenPlist(infoPath)
            }
            let name = (path as NSString).lastPathComponent
            if Self.sharedNames.contains(name) {
                kind = .shared
            } else if !workspace.isEmpty || isProjectCacheName(name, path: path) {
                kind = .project
            }
        }
        return Inspected(path: path, size: size, latest: latestTime, kind: kind, workspace: workspace)
    }

    private func readPlist(_ path: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }  // missing
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
            throw CleanerError.brokenPlist(path)  // unparseable
        }
        guard let dict = pl as? [String: Any] else {
            throw CleanerError.brokenPlist(path)  // root is not a dict
        }
        return dict
    }

    private func isProjectCacheName(_ name: String, path: String) -> Bool {
        guard name.wholeMatch(of: /.+-[a-z]{28}/) != nil else { return false }
        for sub in ["Build", "Logs", "Index.noindex", "SourcePackages"] {
            var st = stat()
            let p = (path as NSString).appendingPathComponent(sub)
            if lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR { return true }
        }
        return false
    }

    // MARK: - Eligibility

    func eligible(_ item: Inspected, cutoff: TimeInterval, includeShared: Bool) -> Bool {
        item.latest < cutoff && (item.kind == .project || (includeShared && item.kind == .shared))
    }

    // MARK: - Roots and scan paths

    func defaultRoots() -> [String] {
        var roots = [NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"]
        if let custom = CFPreferencesCopyAppValue("IDECustomDerivedDataLocation" as CFString,
                                                  "com.apple.dt.Xcode" as CFString) as? String {
            let expanded = (custom as NSString).expandingTildeInPath
            if (custom as NSString).isAbsolutePath {
                roots.append(expanded)
            }
        }
        return roots
    }

    private func collectScanPaths(roots: [String]) throws -> [String] {
        let forbidden: Set<String> = [
            "/", NSHomeDirectory(),
            NSHomeDirectory() + "/Library",
            NSHomeDirectory() + "/Library/Developer",
            NSHomeDirectory() + "/Library/Developer/Xcode",
        ]
        var paths: [String] = []
        for root in roots {
            let resolved = (root as NSString).resolvingSymlinksInPath
            guard !forbidden.contains(resolved) else { throw CleanerError.deleteBlocked(root) }
            guard FileManager.default.fileExists(atPath: resolved) else { continue }
            let infoPath = (resolved as NSString).appendingPathComponent("info.plist")
            var st = stat()
            if lstat(infoPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                paths.append(resolved)
            } else {
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: resolved) {
                    paths.append(contentsOf: entries.map { (resolved as NSString).appendingPathComponent($0) })
                }
            }
        }
        return paths
    }

    // MARK: - Concurrent inspect

    private func inspectAll(paths: [String], scanning: ((String) -> Void)? = nil) async throws -> [Inspected] {
        // The cooperative pool bounds actual parallelism to the core count; for a
        // modest number of DerivedData caches this is sufficient and avoids the
        // contention of a separate concurrency limiter.
        try await withThrowingTaskGroup(of: Inspected.self) { group in
            for path in paths {
                group.addTask {
                    scanning?(path)
                    return try self.inspect(path: path)
                }
            }
            var results: [Inspected] = []
            results.reserveCapacity(paths.count)
            for try await item in group { results.append(item) }
            return results
        }
    }

    // MARK: - Report building

    private func buildReport(items: [Inspected], now: TimeInterval, hours: Int,
                             cutoff: TimeInterval, includeShared: Bool) -> CacheReport {
        let sorted = items.sorted { ($0.size, $0.path) > ($1.size, $1.path) }
        let entries = sorted.map { item -> CacheEntry in
            CacheEntry(path: item.path, size: item.size, workspace: item.workspace,
                       candidate: eligible(item, cutoff: cutoff, includeShared: includeShared))
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        let candidateBytes = entries.filter(\.candidate).reduce(Int64(0)) { $0 + $1.size }
        return CacheReport(generatedAt: now, hours: hours, totalBytes: total,
                           candidateBytes: candidateBytes, items: entries)
    }

    // MARK: - Clean guards

    static func ensureIdle() throws {
        // ponytail: sees only this user's processes; Xcode run by another account is not detected.
        let active = Set(processSamples().values.map(\.name)).intersection(["Xcode", "xcodebuild"])
        if !active.isEmpty { throw CleanerError.xcodeRunning(active.sorted().joined(separator: ", ")) }
    }

    private func verifySafeDeletePath(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw CleanerError.deleteBlocked(path) }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw CleanerError.pathChanged(path) }
        let resolved = (path as NSString).resolvingSymlinksInPath
        if resolved != path { throw CleanerError.pathChanged(path) }
        if isMount(path) { throw CleanerError.pathChanged(path) }
    }

    /// Mirrors os.path.ismount: a directory whose parent lives on a different device.
    private func isMount(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        var pst = stat()
        guard stat(parent, &pst) == 0 else { return false }
        return st.st_dev != pst.st_dev
    }
}

// MARK: - Clean events

enum CleanEvent: Sendable {
    case deleted(path: String, size: Int64)
    case kept(path: String)
    case done(removed: Int, freedBytes: Int64)
}
