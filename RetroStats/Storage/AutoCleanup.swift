import AppKit
import Darwin

enum CleanupCategory: String, CaseIterable, Codable, Sendable {
    case derivedData, developerCaches, appCaches, appLogs
    var label: String {
        switch self {
        case .derivedData: return "DerivedData"
        case .developerCaches: return "Developer caches"
        case .appCaches: return "App caches"
        case .appLogs: return "App logs"
        }
    }
    var days: Int { self == .appLogs ? 30 : 7 }
}

struct AutoCleanupSettings: Codable, Sendable {
    var enabled = false
    var intervalDays = 1
    var categories = Set(CleanupCategory.allCases)
    var exclusions: Set<String> = []
    var lastAttempt: Date?
    var nextRun: Date? { lastAttempt.map { $0.addingTimeInterval(Double(intervalDays) * 86400) } }
    func isDue(at now: Date) -> Bool { enabled && !categories.isEmpty && now >= (nextRun ?? .distantPast) }
    func excludes(_ path: String) -> Bool {
        exclusions.contains { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct CleanupRoot: Sendable {
    let path: String
    let category: CleanupCategory
    /// App bundle path or tool executable names. Empty ownership never permits cleanup.
    let owners: [String]
}

struct CleanupCandidate: Sendable {
    let path: String
    let root: CleanupRoot
    let size: Int64
    let tree: [String: CleanupNode]
}

struct CleanupNode: Equatable, Sendable {
    let device: UInt64, inode: UInt64
    let mode: UInt32
    let modified: Double, changed: Double
    let size: Int64, blocks: Int64
    init(_ st: stat) {
        device = UInt64(st.st_dev); inode = UInt64(st.st_ino); mode = UInt32(st.st_mode)
        modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        changed = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9
        size = st.st_size; blocks = Int64(st.st_blocks)
    }
}

struct CleanupScan: Sendable {
    var candidates: [CleanupCandidate] = []
    var skipped: [String] = []
    var bytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
}

struct CleanupRecord: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    var automatic: Bool
    var finished = false
    var items: [Item] = []
    var notes: [String] = []
    struct Item: Codable, Sendable {
        let path: String
        let deleted: Bool
        let bytes: Int64
        let reason: String
    }
    var freedBytes: Int64 { items.filter(\.deleted).reduce(0) { $0 + $1.bytes } }
    var deletedCount: Int { items.filter(\.deleted).count }
}

/// Independent native implementation. Mole supplies the workflow reference, not executable code.
struct AutoCleanupEngine: Sendable {
    enum Failure: Error, LocalizedError {
        case blocked(String)
        var errorDescription: String? {
            switch self { case .blocked(let reason): return reason }
        }
    }
    let home: String
    init(home: String = NSHomeDirectory()) { self.home = home }
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func exclusionPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if let existing = canonicalPath(path) { return existing }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Only registered app bundle IDs and a small list of rebuildable tool caches.
    /// Application Support, containers, Trash, Downloads and system paths are never scanned.
    @MainActor func roots() -> [CleanupRoot] {
        var result = DerivedDataCleaner().defaultRoots().map {
            CleanupRoot(path: $0, category: .derivedData, owners: ["Xcode", "xcodebuild", "swift-frontend", "clang"])
        }
        for category in [CleanupCategory.appCaches, .appLogs] {
            let base = home + (category == .appCaches ? "/Library/Caches" : "/Library/Logs")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                guard !name.hasPrefix("com.apple."), name != appID,
                      name.split(separator: ".").count >= 3,
                      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name),
                      let bundle = Bundle(url: app), bundle.bundleIdentifier == name,
                      let executable = bundle.executableURL else { continue }
                result.append(CleanupRoot(path: base + "/" + name, category: category,
                                          owners: [app.path + "/", executable.lastPathComponent]))
            }
        }
        // Many apps use their app name rather than bundle ID for log folders.
        // Resolve only exact installed names, and retain every owner on collisions.
        var logOwners: [String: [String]] = [:]
        for directory in ["/Applications", "/Applications/Utilities", home + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: directory + "/" + name)
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !id.hasPrefix("com.apple."), id != appID, let executable = bundle.executableURL else { continue }
                let logName = String(name.dropLast(4))
                logOwners[logName, default: []] += [url.path + "/", executable.lastPathComponent]
            }
        }
        result += logOwners.map { name, owners in
            CleanupRoot(path: home + "/Library/Logs/" + name, category: .appLogs, owners: owners.sorted())
        }
        result += [
            CleanupRoot(path: home + "/.npm/_cacache", category: .developerCaches, owners: ["node", "npm", "npx"]),
            CleanupRoot(path: home + "/Library/Caches/pip", category: .developerCaches, owners: ["python", "python3", "pip", "pip3"]),
            CleanupRoot(path: home + "/Library/Caches/Homebrew", category: .developerCaches, owners: ["brew", "ruby", "curl"]),
        ]
        return result
    }

    /// A failed process query aborts the run instead of treating it as an idle Mac.
    static func processes() async throws -> [String] {
        let task = Task.detached(priority: .utility) { () throws -> [String] in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "comm="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.blocked("Could not verify running processes. Nothing was deleted.")
            }
            return text.split(separator: "\n").map(String.init)
        }
        return try await task.value
    }

    static func active(_ root: CleanupRoot, processes: [String]) -> Bool {
        guard !root.owners.isEmpty else { return true }
        return processes.contains { command in
            root.owners.contains { owner in
                owner.contains("/") ? command.contains(owner) :
                    URL(fileURLWithPath: command).lastPathComponent.caseInsensitiveCompare(owner) == .orderedSame ||
                    URL(fileURLWithPath: command).lastPathComponent.lowercased().hasPrefix(owner.lowercased() + ".")
            }
        }
    }

    func scan(roots: [CleanupRoot], settings: AutoCleanupSettings, processes: [String],
              now: Date = Date()) throws -> CleanupScan {
        var report = CleanupScan()
        var seen = Set<String>()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        for root in roots where settings.categories.contains(root.category) {
            try Task.checkCancellation()
            guard !settings.excludes(root.path) else { continue }
            guard !Self.active(root, processes: processes) else {
                report.skipped.append("In use: \(root.path)"); continue
            }
            var st = stat()
            guard lstat(root.path, &st) == 0 else {
                if errno != ENOENT { report.skipped.append("Cannot read: \(root.path)") }
                continue
            }
            do {
                try validateRoot(root)
                let children = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                guard children.count <= 2000 else { throw Failure.blocked("Too many entries: \(root.path)") }
                for name in children {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        report.skipped.append("Scan time limit reached. Unscanned items were kept.")
                        return report
                    }
                    let path = root.path + "/" + name
                    guard !settings.excludes(path), seen.insert(path).inserted else { continue }
                    do {
                        let candidate = try inspect(path: path, root: root, settings: settings, now: now, deadline: deadline)
                        report.candidates.append(candidate)
                    } catch is CancellationError { throw CancellationError() }
                    catch { report.skipped.append("\(path): \(error.localizedDescription)") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.skipped.append("\(root.path): \(error.localizedDescription)") }
        }
        report.candidates.sort { $0.size > $1.size }
        return report
    }

    private func validateRoot(_ root: CleanupRoot) throws {
        let allowed: Bool
        switch root.category {
        case .derivedData:
            allowed = root.path == home + "/Library/Developer/Xcode/DerivedData" ||
                DerivedDataCleaner().defaultRoots().contains(root.path)
        case .developerCaches:
            allowed = [home + "/.npm/_cacache", home + "/Library/Caches/pip", home + "/Library/Caches/Homebrew"].contains(root.path)
        case .appCaches, .appLogs:
            let base = home + (root.category == .appCaches ? "/Library/Caches" : "/Library/Logs")
            allowed = (root.path as NSString).deletingLastPathComponent == base &&
                !(root.path as NSString).lastPathComponent.hasPrefix("com.apple.") &&
                (root.path as NSString).lastPathComponent != appID
        }
        guard allowed, !root.owners.isEmpty,
              root.path == Self.canonicalPath(root.path) else {
            throw Failure.blocked("Unverified or redirected cache root")
        }
        let fd = try openDirectory(root.path)
        defer { close(fd) }
        var st = stat(), parent = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(),
              lstat((root.path as NSString).deletingLastPathComponent, &parent) == 0,
              st.st_dev == parent.st_dev else { throw Failure.blocked("Unowned root or mount point") }
    }

    private func inspect(path: String, root: CleanupRoot, settings: AutoCleanupSettings, now: Date,
                         deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 10) throws -> CleanupCandidate {
        guard (path as NSString).deletingLastPathComponent == root.path else { throw Failure.blocked("Outside cache root") }
        var tree: [String: CleanupNode] = [:]
        var pending = [path]
        var total: Int64 = 0
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else { throw Failure.blocked("Root disappeared") }
        let cutoff = now.timeIntervalSince1970 - Double(root.category.days) * 86400
        while let current = pending.popLast() {
            try Task.checkCancellation()
            guard tree.count < 100_000, ProcessInfo.processInfo.systemUptime < deadline,
                  !settings.excludes(current) else { throw Failure.blocked("Excluded descendant or scan limit") }
            var st = stat()
            guard lstat(current, &st) == 0, st.st_dev == rootStat.st_dev, st.st_uid == getuid(),
                  st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0,
                  access(current, R_OK) == 0 else {
                throw Failure.blocked("Unreadable, protected or mounted entry")
            }
            let type = st.st_mode & S_IFMT
            guard type == S_IFDIR || (type == S_IFREG && st.st_nlink == 1) else {
                throw Failure.blocked("Symlink, hard link or special file")
            }
            let node = CleanupNode(st)
            if root.category != .derivedData {
                guard max(node.modified, node.changed) < cutoff else { throw Failure.blocked("Within retention period") }
            }
            tree[current] = node
            total += node.blocks * 512
            if type == S_IFDIR {
                pending += try FileManager.default.contentsOfDirectory(atPath: current).map { current + "/" + $0 }
            }
        }
        if root.category == .derivedData {
            let cleaner = DerivedDataCleaner()
            guard cleaner.eligible(try cleaner.inspect(path: path), cutoff: now.timeIntervalSince1970 - 8 * 3600,
                                   includeShared: false) else { throw Failure.blocked("Recent, shared or unrecognized DerivedData") }
        }
        return CleanupCandidate(path: path, root: root, size: total, tree: tree)
    }

    func delete(_ candidate: CleanupCandidate, settings: AutoCleanupSettings, processes: [String], now: Date = Date()) throws {
        try Task.checkCancellation()
        guard settings.categories.contains(candidate.root.category), !settings.excludes(candidate.path),
              !Self.active(candidate.root, processes: processes) else { throw Failure.blocked("Excluded or in use") }
        try validateRoot(candidate.root)
        let fresh = try inspect(path: candidate.path, root: candidate.root, settings: settings, now: now)
        guard candidate.tree == fresh.tree else { throw Failure.blocked("Changed since preview") }
        let parent = try openDirectory(candidate.root.path)
        defer { close(parent) }
        let children = Dictionary(grouping: fresh.tree.keys, by: { ($0 as NSString).deletingLastPathComponent })
        try remove(name: (candidate.path as NSString).lastPathComponent, path: candidate.path, parent: parent, tree: fresh.tree, children: children)
    }

    /// Open every component without following symlinks. Deletion stays anchored to
    /// these descriptors even if a path component is swapped during the operation.
    private func openDirectory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.blocked("Cannot open filesystem root") }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Failure.blocked("Cannot open cache directory without following links") }
            fd = next
        }
        return fd
    }

    private func remove(name: String, path: String, parent: Int32, tree: [String: CleanupNode], children: [String: [String]]) throws {
        try Task.checkCancellation()
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              tree[path] == CleanupNode(st) else { throw Failure.blocked("Entry changed during deletion") }
        if st.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.blocked("Directory changed during deletion") }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, CleanupNode(opened) == tree[path] else { throw Failure.blocked("Directory identity changed") }
            for child in (children[path] ?? []).sorted() {
                try remove(name: (child as NSString).lastPathComponent, path: child, parent: fd, tree: tree, children: children)
            }
            // mtime/ctime change as our own children are removed; verify inode again.
            guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  UInt64(st.st_ino) == tree[path]?.inode, UInt64(st.st_dev) == tree[path]?.device,
                  unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Failure.blocked("Directory changed or is no longer empty") }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw Failure.blocked("Could not delete file (errno \(errno))") }
        }
    }
}
