import AppKit
import Darwin
import CryptoKit

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
    var categories: Set<CleanupCategory> = [.developerCaches, .appCaches]
    var exclusions: Set<String> = []
    var lastAttempt: Date?
    var nextRun: Date? { lastAttempt.map { $0.addingTimeInterval(Double(intervalDays) * 86400) } }
    func isDue(at now: Date) -> Bool { enabled && !categories.isEmpty && now >= (nextRun ?? .distantPast) }
    func excludes(_ path: String) -> Bool {
        exclusions.contains { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct CleanupRoot: Codable, Sendable {
    let path: String
    let category: CleanupCategory
    /// App bundle path or tool executable names. Empty ownership never permits cleanup.
    let owners: [String]
}

struct CleanupCandidate: Codable, Sendable {
    let path: String
    let root: CleanupRoot
    let size: Int64
    let tree: [String: CleanupNode]
    let hashes: [String: String]
    let attributes: [String: String]
    let rootNode: CleanupNode
    let volume: CleanupVolume?
    var reason: String { "Rebuildable cache · idle owner and no open files observed · all entries older than \(root.category.days) days" }
}

struct CleanupNode: Codable, Equatable, Sendable {
    let device: UInt64, inode: UInt64
    let mode: UInt32
    let modified: Double, changed: Double
    let size: Int64, blocks: Int64
    let uid: UInt32, gid: UInt32, links: UInt16, flags: UInt32
    init(_ st: stat) {
        device = UInt64(st.st_dev); inode = UInt64(st.st_ino); mode = UInt32(st.st_mode)
        modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        changed = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9
        size = st.st_size; blocks = Int64(st.st_blocks)
        uid = st.st_uid; gid = st.st_gid; links = st.st_nlink; flags = st.st_flags
    }
}

struct CleanupScan: Sendable {
    var candidates: [CleanupCandidate] = []
    var volumes: [CleanupVolume] = []
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
    var before: [CleanupVolume]?
    var after: [CleanupVolume]?
    struct Item: Codable, Sendable {
        let path: String
        var deleted: Bool
        var bytes: Int64
        var reason: String
        var recoveryPath: String? = nil
        var receipt: CleanupReceipt? = nil
        var restored: Bool? = nil
        var archive: CleanupArchiveReceipt? = nil
        var restoreReceipt: CleanupReceipt? = nil
        var restoreStagingPath: String? = nil
    }
    /// Legacy field is allocated item size, never measured free-space gain.
    var freedBytes: Int64 { items.filter(\.deleted).reduce(0) { $0 + $1.bytes } }
    var deletedCount: Int { items.filter(\.deleted).count }
    var copiedBytes: Int64 { items.compactMap(\.archive).filter { $0.copiedTree != nil }.reduce(0) { $0 + $1.candidate.size } }
    var completedItemCount: Int { items.filter { $0.deleted || $0.archive?.copiedTree != nil }.count }
    var outcomeLabel: String {
        guard finished else { return "Incomplete / check recovery" }
        guard completedItemCount > 0 else { return "No items completed · review reasons" }
        return completedItemCount == items.count ? "Finished" : "Partially completed · review reasons"
    }
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
    let fixtureArchiveRemoval: Bool
    init(home: String = NSHomeDirectory(), fixtureArchiveRemoval: Bool = false) {
        self.home = home
        let temporary = Self.canonicalPath(FileManager.default.temporaryDirectory.path) ?? "invalid"
        self.fixtureArchiveRemoval = fixtureArchiveRemoval && home.hasPrefix(temporary + "/archive-home-") && home != NSHomeDirectory()
    }
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
            CleanupRoot(path: home + "/.cache/uv", category: .developerCaches, owners: ["uv", "uvx", "python", "python3"]),
            CleanupRoot(path: home + "/Library/Caches/go-build", category: .developerCaches, owners: ["go", "compile", "link"]),
        ]
        return result
    }

    /// Reuse the existing bounded native command runner; no shell or elevated query.
    static func processes() async throws -> [String] {
        let runner = TailscaleCLI(limit: 32 * 1_048_576)
        func query(_ executable: String, _ arguments: [String]) async throws -> String {
            let result = try await runner.run(executable: executable, arguments: arguments, timeout: 12)
            guard result.status == 0, result.stderr.isEmpty, !result.stdout.isEmpty,
                  let text = String(data: result.stdout, encoding: .utf8) else {
                throw Failure.blocked("Unknown usage: incomplete process/open-file query. Items kept; no extra permission requested.")
            }
            try Task.checkCancellation()
            return text
        }
        let commands = try await query("/bin/ps", ["-axo", "comm="]).split(separator: "\n").map(String.init)
        let fields = try await query("/usr/sbin/lsof", ["-a", "-u", String(getuid()), "-FDin"]).split(separator: "\n")
        var files: [String] = [], device: UInt64?
        for field in fields {
            if field.hasPrefix("D0x") { device = UInt64(field.dropFirst(3), radix: 16) }
            else if field.hasPrefix("i"), let device, let inode = UInt64(field.dropFirst()) { files.append("OPENID:\(device):\(inode)") }
            else if field.hasPrefix("n/") { files.append("OPEN:" + field.dropFirst()) }
        }
        return commands + files
    }

    static func inUse(_ candidate: CleanupCandidate, processes: [String], staged: String? = nil) -> Bool {
        if active(candidate.root, processes: processes) { return true }
        let identities = Set(candidate.tree.values.map { "OPENID:\($0.device):\($0.inode)" })
        return processes.contains { line in
            if identities.contains(line) { return true }
            guard let staged, line.hasPrefix("OPEN:") else { return false }
            let path = String(line.dropFirst(5))
            return path == staged || path.hasPrefix(staged + "/")
        }
    }

    static func active(_ root: CleanupRoot, processes: [String]) -> Bool {
        guard !root.owners.isEmpty else { return true }
        return processes.contains { command in
            if command.hasPrefix("OPEN:") {
                let path = String(command.dropFirst(5))
                return path == root.path || path.hasPrefix(root.path + "/")
            }
            let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
            // Build/update activity is deliberately conservative, without stopping anything.
            if ["xcodebuild", "swift-frontend", "clang", "softwareupdated", "installer", "installd", "autoupdate", "updater"].contains(name) { return true }
            return root.owners.contains { owner in
                owner.contains("/") ? command.contains(owner) :
                    name == owner.lowercased() || name.hasPrefix(owner.lowercased() + ".")
            }
        }
    }

    func scan(roots: [CleanupRoot], settings: AutoCleanupSettings, processes: [String], now: Date = Date()) throws -> CleanupScan {
        var report = CleanupScan()
        var seen = Set<String>()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        for root in roots where settings.categories.contains(root.category) {
            try Task.checkCancellation()
            if settings.excludes(root.path) { report.skipped.append("Excluded: " + root.path); continue }
            var st = stat()
            guard lstat(root.path, &st) == 0 else {
                if errno != ENOENT { report.skipped.append("Unknown / permission limited: " + root.path) }
                continue
            }
            if let volume = CleanupVolume.read(root.path), !report.volumes.contains(where: { $0.id == volume.id }) { report.volumes.append(volume) }
            do {
                try validateRoot(root)
                guard !Self.active(root, processes: processes) else { throw Failure.blocked("In use: running owner, build/update or open file") }
                // Root changes (including npm tmp activity) protect the entire cache.
                guard max(CleanupNode(st).modified, CleanupNode(st).changed) < now.timeIntervalSince1970 - 86400 else {
                    throw Failure.blocked("Root changed within 24 hours; possible download/build/update")
                }
                try validateTransientActivity(root, now: now)
                let fd = try openDirectory(root.path)
                defer { close(fd) }
                for name in try names(fd) {
                    let path = root.path + "/" + name
                    guard seen.insert(path).inserted else { continue }
                    do {
                        // Generic app caches can contain offline/user data. Only updater caches
                        // have a known rebuild policy; no arbitrary folder is declared safe.
                        if root.category == .appCaches && name != "org.sparkle-project.Sparkle" {
                            throw Failure.blocked("Protected: regeneration of this app data is unverified")
                        }
                        report.candidates.append(try inspect(path: path, root: root, settings: settings, now: now, deadline: deadline))
                    } catch is CancellationError { throw CancellationError() }
                    catch { report.skipped.append(path + ": " + error.localizedDescription) }
                    if ProcessInfo.processInfo.systemUptime >= deadline { report.skipped.append("Scan incomplete: time limit; unread items kept"); break }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.skipped.append(root.path + ": " + error.localizedDescription) }
        }
        report.skipped += [
            "Protected by default: source, authentication, settings, containers, photos, ebooks, backups and verification evidence are outside the cache policy.",
            "Protected: CoreSimulator is user data. DeviceSupport and DerivedData need current-use verification; not eligible in this workflow.",
            "Protected: Downloads/installers need manual ownership and mounted-image verification; not eligible by filename alone."
        ]
        report.candidates.sort { $0.size > $1.size }
        return report
    }

    func validateRoot(_ root: CleanupRoot) throws {
        let allowed: Bool
        switch root.category {
        case .derivedData, .appLogs: allowed = false
        case .developerCaches:
            allowed = [home + "/.npm/_cacache", home + "/Library/Caches/pip", home + "/Library/Caches/Homebrew",
                       home + "/.cache/uv", home + "/Library/Caches/go-build"].contains(root.path)
        case .appCaches:
            let base = home + "/Library/Caches"
            allowed = (root.path as NSString).deletingLastPathComponent == base &&
                !(root.path as NSString).lastPathComponent.hasPrefix("com.apple.") &&
                (root.path as NSString).lastPathComponent != appID
        }
        guard allowed, !root.owners.isEmpty, root.path == Self.canonicalPath(root.path) else {
            throw Failure.blocked("Protected / unverified policy or redirected root")
        }
        let fd = try openDirectory(root.path)
        defer { close(fd) }
        var st = stat(), parent = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), lstat((root.path as NSString).deletingLastPathComponent, &parent) == 0,
              st.st_dev == parent.st_dev else { throw Failure.blocked("Unowned root or mount point") }
    }

    private func validateTransientActivity(_ root: CleanupRoot, now: Date) throws {
        let parent = try openDirectory(root.path)
        defer { close(parent) }
        var st = stat()
        for name in try names(parent) where name == "tmp" || name == ".tmp" || name.hasSuffix(".lock") {
            guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.blocked("Transient usage unknown") }
            if max(CleanupNode(st).modified, CleanupNode(st).changed) >= now.timeIntervalSince1970 - 86400 {
                throw Failure.blocked("Temporary/lock entry changed within 24 hours; entire cache kept")
            }
            // Nested writes need not update the top-level tmp directory.
            if st.st_mode & S_IFMT == S_IFDIR {
                _ = try snapshot(parent: parent, name: name, original: root.path + "/" + name,
                    settings: AutoCleanupSettings(), device: UInt64(st.st_dev),
                    cutoff: now.timeIntervalSince1970 - 86400, deadline: ProcessInfo.processInfo.systemUptime + 10)
            }
        }
    }

    func verifyPath(_ path: String, descriptor: Int32) throws {
        let current = try openDirectory(path)
        defer { close(current) }
        var a = stat(), b = stat()
        guard fstat(current, &a) == 0, fstat(descriptor, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw Failure.blocked("Path changed during operation; manual review required") }
    }

    func inspect(path: String, root: CleanupRoot, settings: AutoCleanupSettings, now: Date,
                         deadline: TimeInterval) throws -> CleanupCandidate {
        guard (path as NSString).deletingLastPathComponent == root.path, !settings.excludes(path) else { throw Failure.blocked("Excluded or outside root") }
        let parent = try openDirectory(root.path)
        defer { close(parent) }
        var st = stat()
        guard fstat(parent, &st) == 0 else { throw Failure.blocked("Unknown root") }
        let rootNode = CleanupNode(st)
        let snapshot = try snapshot(parent: parent, name: (path as NSString).lastPathComponent, original: path,
            settings: settings, device: rootNode.device, cutoff: now.timeIntervalSince1970 - Double(root.category.days) * 86400, deadline: deadline)
        return CleanupCandidate(path: path, root: root, size: snapshot.tree.values.reduce(0) { $0 + $1.blocks * 512 },
            tree: snapshot.tree, hashes: snapshot.hashes, attributes: snapshot.attributes, rootNode: rootNode, volume: CleanupVolume.read(root.path))
    }

    func names(_ fd: Int32) throws -> [String] {
        // openat "." gives an independent directory offset (dup would share it).
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Failure.blocked("Unknown directory access") }
        guard let directory = fdopendir(copy) else { close(copy); throw Failure.blocked("Unknown directory listing") }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 100_000 else { throw Failure.blocked("Directory size limit") }
            errno = 0
        }
        guard errno == 0 else { throw Failure.blocked("Incomplete directory listing") }
        return result.sorted()
    }

    func snapshot(parent: Int32, name: String, original: String, settings: AutoCleanupSettings,
                          device: UInt64, cutoff: Double?, deadline: TimeInterval) throws -> (tree: [String: CleanupNode], hashes: [String: String], attributes: [String: String]) {
        var tree: [String: CleanupNode] = [:], hashes: [String: String] = [:], attributes: [String: String] = [:]
        func walk(_ parent: Int32, _ name: String, _ relative: String) throws {
            try Task.checkCancellation()
            guard tree.count < 100_000, relative.split(separator: "/").count < 256, ProcessInfo.processInfo.systemUptime < deadline,
                  !settings.excludes(original + (relative.isEmpty ? "" : "/" + relative)) else { throw Failure.blocked("Excluded descendant or inspection limit; unknown") }
            var st = stat()
            guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  UInt64(st.st_dev) == device, st.st_uid == getuid(),
                  st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
                throw Failure.blocked("Unknown / permission limited, mounted or protected entry")
            }
            let type = st.st_mode & S_IFMT, node = CleanupNode(st)
            guard type == S_IFDIR || (type == S_IFREG && st.st_nlink == 1) else { throw Failure.blocked("Protected symlink, hard link or special file") }
            if let cutoff, max(node.modified, node.changed) >= cutoff { throw Failure.blocked("Recently changed: within retention period") }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (type == S_IFDIR ? O_DIRECTORY : O_NONBLOCK))
            guard fd >= 0 else { throw Failure.blocked("Unknown / permission limited") }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, CleanupNode(opened) == node else { throw Failure.blocked("Replaced during inspection") }
            tree[relative] = node
            attributes[relative] = try attributeHash(fd)
            if type == S_IFDIR {
                for child in try names(fd) { try walk(fd, child, relative.isEmpty ? child : relative + "/" + child) }
            } else {
                var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
                while true {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.blocked("Hash verification time limit; unknown") }
                    let count = read(fd, &buffer, buffer.count)
                    guard count >= 0 else { throw Failure.blocked("Read failed; content unverified") }
                    if count == 0 { break }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                hashes[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            guard fstat(fd, &opened) == 0, CleanupNode(opened) == node,
                  fstatat(parent, name, &opened, AT_SYMLINK_NOFOLLOW) == 0, CleanupNode(opened) == node else { throw Failure.blocked("Changed during inspection") }
        }
        try walk(parent, name, "")
        return (tree, hashes, attributes)
    }

    func attributeHash(_ fd: Int32) throws -> String {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 1_048_576 else { throw Failure.blocked("Extended attributes unknown") }
        var names = [CChar](repeating: 0, count: max(1, size))
        guard flistxattr(fd, &names, size, 0) == size else { throw Failure.blocked("Extended attributes changed") }
        let keys = Data(names.prefix(size).map { UInt8(bitPattern: $0) }).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
        var hash = SHA256()
        for key in keys {
            let length = fgetxattr(fd, key, nil, 0, 0, 0)
            guard length >= 0, length <= 16 * 1_048_576 else { throw Failure.blocked("Extended attribute inaccessible") }
            var value = [UInt8](repeating: 0, count: max(1, length))
            guard fgetxattr(fd, key, &value, length, 0, 0) == length else { throw Failure.blocked("Extended attribute changed") }
            hash.update(data: Data(key.utf8)); hash.update(data: Data([0])); hash.update(data: Data(value.prefix(length))); hash.update(data: Data([0]))
        }
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            let count = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            guard count == 0 || (entry == nil && errno == EINVAL) else { throw Failure.blocked("ACL metadata unreadable") }
            // macOS returns zero on success, unlike the Linux iteration convention.
            if count == 0 && entry != nil {
                var length = 0
                guard let text = acl_to_text(acl, &length) else { throw Failure.blocked("ACL metadata unreadable") }
                defer { acl_free(text) }
                hash.update(data: Data(bytes: text, count: length))
            }
        } else if errno != ENOENT { throw Failure.blocked("ACL metadata unknown") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every component is opened without following a link. Mutations stay anchored to descriptors.
    func openDirectory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.blocked("Unknown filesystem root") }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Failure.blocked("Unknown / redirected directory") }
            fd = next
        }
        return fd
    }

    private var recoveryDirectory: String { home + "/Library/Application Support/RetroStats/Recovery" }

    private func openRecoveryCreating() throws -> Int32 {
        var fd = try openDirectory(home)
        for component in ["Library", "Application Support", "RetroStats", "Recovery"] {
            if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { close(fd); throw Failure.blocked("Cannot create recovery directory") }
            guard fsync(fd) == 0 else { close(fd); throw Failure.blocked("Recovery parent durability unknown") }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Failure.blocked("Redirected recovery directory") }
            fd = next
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid() else { close(fd); throw Failure.blocked("Unowned recovery path") }
        }
        return fd
    }


    /// Durable receipt is written before the single atomic rename. No unlink, copy/delete,
    /// Trash emptying or cross-volume fallback exists in this engine.
    func prepare(_ candidate: CleanupCandidate) throws -> CleanupReceipt {
        try validateRoot(candidate.root)
        let parent = try openDirectory(candidate.root.path)
        defer { close(parent) }
        let recovery = try openRecoveryCreating()
        defer { close(recovery) }
        var st = stat()
        guard fstat(recovery, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              UInt64(st.st_dev) == candidate.rootNode.device else { throw Failure.blocked("Recovery directory unverified") }
        let receipt = CleanupReceipt(id: UUID(), candidate: candidate, directory: recoveryDirectory)
        let name = receipt.id.uuidString + ".json"
        let fd = openat(recovery, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.blocked("Cannot reserve recovery receipt") }
        defer { close(fd) }
        let data = try JSONEncoder().encode(receipt)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw Failure.blocked("Recovery receipt write failed") }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(recovery) == 0 else { throw Failure.blocked("Recovery receipt could not be made durable") }
        // Recovery is outside cache trees, so cache purges cannot remove our receipts.
        return receipt
    }

    /// History/preview writes are anchored to owned directories below this home.
    /// A redirected support directory can never turn journaling into an unrelated write.
    func writeJournal(support: URL, name: String, data: Data) throws {
        guard support.path.hasPrefix(home + "/"), !name.contains("/"),
              !support.path.dropFirst(home.count + 1).split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.blocked("Unverified journal path") }
        var directory = try openDirectory(home)
        defer { close(directory) }
        for part in support.path.dropFirst(home.count + 1).split(separator: "/") {
            let component = String(part)
            if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST { throw Failure.blocked("Cannot create journal directory") }
            guard fsync(directory) == 0 else { throw Failure.blocked("Journal directory durability unknown") }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.blocked("Journal directory is redirected or unavailable") }
            close(directory); directory = next
            var st = stat()
            guard fstat(directory, &st) == 0, st.st_uid == getuid() else { throw Failure.blocked("Journal directory is unowned") }
        }
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1, existing.st_uid == getuid() else { throw Failure.blocked("Journal file is linked, unowned or protected") }
        } else if errno != ENOENT { throw Failure.blocked("Journal access unknown") }
        let temporary = "." + name + "." + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.blocked("Journal cannot be saved") }
        defer { close(file) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw Failure.blocked("Journal write failed") }; offset += count
            }
        }
        try verifyPath(support.path, descriptor: directory)
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw Failure.blocked("Journal durability unknown; source operation blocked") }
    }

    func persistRecoveryReceipt(_ receipt: CleanupReceipt) throws {
        guard receipt.directory == recoveryDirectory else { throw Failure.blocked("Unverified recovery receipt directory") }
        let directory = try openDirectory(receipt.directory)
        defer { close(directory) }
        let name = ".receipt-" + UUID().uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.blocked("Cannot save verified recovery receipt") }
        defer { close(fd) }
        let data = try JSONEncoder().encode(receipt)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw Failure.blocked("Recovery receipt write failed") }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, name, directory, receipt.id.uuidString + ".json") == 0,
              fsync(directory) == 0 else { throw Failure.blocked("Recovery receipt durability unknown") }
    }

    func same(_ a: [String: CleanupNode], _ b: [String: CleanupNode], moved: Bool) -> Bool {
        guard a.keys.sorted() == b.keys.sorted() else { return false }
        return a.allSatisfy { key, old in
            guard let fresh = b[key] else { return false }
            if moved && key.isEmpty {
                return old.device == fresh.device && old.inode == fresh.inode && old.mode == fresh.mode &&
                    old.modified == fresh.modified && old.size == fresh.size && old.blocks == fresh.blocks &&
                    old.uid == fresh.uid && old.gid == fresh.gid && old.links == fresh.links && old.flags == fresh.flags
            }
            return old == fresh
        }
    }

    @discardableResult func move(_ receipt: CleanupReceipt, settings: AutoCleanupSettings, processes: [String], now: Date = Date(),
              expectedRoot: CleanupNode? = nil, beforeRename: (() throws -> Void)? = nil, afterRename: (() throws -> Void)? = nil) throws -> CleanupNode {
        try Task.checkCancellation()
        let candidate = receipt.candidate
        guard settings.categories.contains(candidate.root.category), !settings.excludes(candidate.path),
              !Self.inUse(candidate, processes: processes) else { throw Failure.blocked("Excluded or in use") }
        try validateRoot(candidate.root)
        try validateTransientActivity(candidate.root, now: now)
        let fresh = try inspect(path: candidate.path, root: candidate.root, settings: settings, now: now, deadline: ProcessInfo.processInfo.systemUptime + 60)
        guard same(candidate.tree, fresh.tree, moved: false), candidate.hashes == fresh.hashes, candidate.attributes == fresh.attributes,
              (expectedRoot ?? candidate.rootNode) == fresh.rootNode else { throw Failure.blocked("Changed since preview; item kept") }
        let parent = try openDirectory(candidate.root.path)
        defer { close(parent) }
        guard receipt.directory == recoveryDirectory else { throw Failure.blocked("Unverified recovery location") }
        let recovery = try openDirectory(receipt.directory)
        defer { close(recovery) }
        try beforeRename?() // Deterministic fixture hook for the last possible path swap.
        try verifyPath(candidate.root.path, descriptor: parent)
        try verifyPath(receipt.directory, descriptor: recovery)
        try Task.checkCancellation()
        var st = stat()
        let name = (candidate.path as NSString).lastPathComponent
        guard fstat(parent, &st) == 0, CleanupNode(st) == fresh.rootNode,
              fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0, CleanupNode(st) == candidate.tree[""] else { throw Failure.blocked("Replaced before move; kept") }
        guard renameatx_np(parent, name, recovery, receipt.id.uuidString, UInt32(RENAME_EXCL)) == 0 else { throw Failure.blocked("Move failed (errno \(errno)); original kept") }
        try afterRename?()
        // Cancellation after rename can interrupt verification; the pending receipt is durable.
        // A swapped or changing tree is retained in recovery, never recursively removed.
        guard fsync(parent) == 0, fsync(recovery) == 0 else { throw Failure.blocked("Move completed but directory durability unknown; check recovery") }
        let moved = try snapshotUncancelled(parent: recovery, name: receipt.id.uuidString, candidate: candidate)
        guard same(candidate.tree, moved.tree, moved: true), candidate.hashes == moved.hashes, candidate.attributes == moved.attributes else {
            throw Failure.blocked("Changed during move; retained in recovery for manual review: " + receipt.recoveryPath)
        }
        guard fstat(parent, &st) == 0 else { throw Failure.blocked("Move completed; root state unknown") }
        return CleanupNode(st)
    }

    private func snapshotUncancelled(parent: Int32, name: String, candidate: CleanupCandidate) throws -> (tree: [String: CleanupNode], hashes: [String: String], attributes: [String: String]) {
        // The atomic operation is the commit boundary. Verification can be interrupted;
        // the durable receipt and retained whole item still allow recovery.
        try snapshot(parent: parent, name: name, original: candidate.path, settings: AutoCleanupSettings(),
                     device: candidate.rootNode.device, cutoff: nil, deadline: ProcessInfo.processInfo.systemUptime + 60)
    }

    func restore(_ receipt: CleanupReceipt, processes: [String], beforeRename: (() throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        let candidate = receipt.candidate
        try validateRoot(candidate.root)
        guard !Self.inUse(candidate, processes: processes) else { throw Failure.blocked("In use; restoration kept pending") }
        let parent = try openDirectory(candidate.root.path)
        defer { close(parent) }
        guard receipt.directory == recoveryDirectory else { throw Failure.blocked("Unverified recovery location") }
        let recovery = try openDirectory(receipt.directory)
        defer { close(recovery) }
        var st = stat()
        guard fstat(parent, &st) == 0, UInt64(st.st_ino) == candidate.rootNode.inode, UInt64(st.st_dev) == candidate.rootNode.device else { throw Failure.blocked("Original root changed; manual recovery required") }
        let saved = try snapshotUncancelled(parent: recovery, name: receipt.id.uuidString, candidate: candidate)
        guard same(candidate.tree, saved.tree, moved: true), candidate.hashes == saved.hashes, candidate.attributes == saved.attributes else { throw Failure.blocked("Recovery content changed/unverified; manual review required") }
        try beforeRename?()
        try verifyPath(candidate.root.path, descriptor: parent)
        try verifyPath(receipt.directory, descriptor: recovery)
        guard fstatat(recovery, receipt.id.uuidString, &st, AT_SYMLINK_NOFOLLOW) == 0,
              CleanupNode(st) == saved.tree[""] else { throw Failure.blocked("Recovery replaced before restoration") }
        try Task.checkCancellation()
        guard renameatx_np(recovery, receipt.id.uuidString, parent, (candidate.path as NSString).lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw Failure.blocked("Restore blocked: original exists or path changed; nothing overwritten") }
        guard fsync(parent) == 0, fsync(recovery) == 0 else { throw Failure.blocked("Restored but directory durability unknown; inspect original path") }
    }
}

struct CleanupReceipt: Codable, Sendable {
    let id: UUID
    let candidate: CleanupCandidate
    let directory: String
    var recoveryPath: String { directory + "/" + id.uuidString }
}
