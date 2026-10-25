import AppKit

/// Owned by StorageController. UI and published state use the main run loop;
/// filesystem work runs on utility tasks and receives cancellation explicitly.
final class AutoCleanupController: @unchecked Sendable {
    private(set) var settings: AutoCleanupSettings
    private(set) var scan: CleanupScan?
    private(set) var selected: Set<String> = []
    static let sourceReclaimEnabled = false
    private(set) var archiveDestination: String?
    private(set) var volumes: [CleanupVolume] = []
    private(set) var busy = false
    private(set) var running = false
    private(set) var history: [CleanupRecord] = []
    private(set) var error: String?
    private(set) var currentPath: String?
    private(set) var activeRecordID: UUID?
    var canRun: () -> Bool = { true }
    var completed: () -> Void = {}
    private let defaults: UserDefaults
    private let support: URL
    private let changed: () -> Void
    private let allowOperations: Bool
    private let engine: AutoCleanupEngine
    private let roots: @MainActor () -> [CleanupRoot]
    private let processes: @Sendable () async throws -> [String]
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var stopped = false
    static let settingsKey = "storageAutoCleanup.v2"

    init(defaults: UserDefaults = .standard, support: URL, allowOperations: Bool, archiveDestination: String? = nil,
         engine: AutoCleanupEngine = AutoCleanupEngine(), roots: (@MainActor () -> [CleanupRoot])? = nil,
         processes: @escaping @Sendable () async throws -> [String] = { try await AutoCleanupEngine.processes() },
         now: @escaping @Sendable () -> Date = { Date() }, changed: @escaping () -> Void) {
        self.defaults = defaults; self.support = support
        self.allowOperations = allowOperations; self.changed = changed; self.archiveDestination = archiveDestination
        self.engine = engine; self.roots = roots ?? { engine.roots() }
        self.processes = processes; self.now = now
        var settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AutoCleanupSettings.self, from: $0) } ?? AutoCleanupSettings()
        settings.intervalDays = settings.intervalDays == 7 ? 7 : 1
        settings.exclusions = Set(settings.exclusions.compactMap(AutoCleanupEngine.exclusionPath))
        // v1 enabled permanent deletion. Never inherit that authorization for a new workflow.
        if defaults.data(forKey: Self.settingsKey) == nil,
           let data = defaults.data(forKey: "storageAutoCleanup.v1"),
           let old = try? JSONDecoder().decode(AutoCleanupSettings.self, from: data) {
            settings.exclusions = old.exclusions; settings.enabled = false
        }
        self.settings = settings
        self.volumes = CleanupVolume.mounted()
        if let data = try? Data(contentsOf: historyURL), let records = try? JSONDecoder().decode([CleanupRecord].self, from: data) {
            history = records
        }
    }

    var historyURL: URL { support.appendingPathComponent("auto-cleanup-history.json") }
    var previewURL: URL { support.appendingPathComponent("auto-cleanup-preview.txt") }
    var hasReview: Bool { scan != nil && !busy }
    var candidateCount: Int { scan?.candidates.count ?? 0 }
    var candidateBytes: Int64 { scan?.bytes ?? 0 }

    func setEnabled(_ enabled: Bool) {
        guard allowOperations else { return }
        settings.enabled = enabled
        if enabled { settings.lastAttempt = now() } // First deletion is at the next scheduled check.
        else if running { task?.cancel() }
        saveSettings(); changed()
    }

    func setInterval(_ days: Int) {
        guard !busy, allowOperations else { return }
        settings.intervalDays = days == 7 ? 7 : 1
        saveSettings(); changed()
    }

    func setCategory(_ category: CleanupCategory, enabled: Bool) {
        guard !busy, allowOperations else { return }
        if enabled { settings.categories.insert(category) } else { settings.categories.remove(category) }
        scan = nil; saveSettings(); changed()
    }

    func exclude(_ path: String) {
        guard !busy, allowOperations else { return }
        guard let resolved = AutoCleanupEngine.exclusionPath(path) else { return }
        settings.exclusions.insert(resolved)
        scan = nil; saveSettings(); changed()
    }

    func removeExclusion(_ path: String) {
        guard !busy, allowOperations else { return }
        settings.exclusions.remove(path)
        scan = nil; saveSettings(); changed()
    }

    func chooseExclusion() {
        guard !busy, allowOperations else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "Exclude"
        if panel.runModal() == .OK { panel.urls.forEach { exclude($0.path) } }
    }

    func select(_ path: String, enabled: Bool) {
        guard !busy, scan?.candidates.contains(where: { $0.path == path }) == true else { return }
        if enabled { selected.insert(path) } else { selected.remove(path) }
        changed()
    }
    var selectedBytes: Int64 { scan?.candidates.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size } ?? 0 }

    func tick(now: Date = Date()) {
        guard settings.isDue(at: now), !busy, canRun(), allowOperations, !stopped else { return }
        settings.lastAttempt = now
        saveSettings()
        start(automatic: true, deleting: false)
    }

    func preview() { start(automatic: false, deleting: false) }
    func confirmMove() {
        guard hasReview, !selected.isEmpty else { return }
        start(automatic: false, deleting: true)
    }
    func cancel() { task?.cancel() }
    func stop() { stopped = true; task?.cancel() }

    func chooseArchiveDestination() {
        guard allowOperations, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose External Archive"
        if panel.runModal() == .OK { archiveDestination = panel.url?.path; changed() }
    }

    private func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func confirmExternalCopy() {
        guard allowOperations, !busy, !stopped, canRun(), let report = scan, !selected.isEmpty, let destination = archiveDestination else { return }
        let candidates = report.candidates.filter { selected.contains($0.path) }, settings = self.settings
        busy = true; running = true; error = nil; changed()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var record = CleanupRecord(automatic: false)
            record.date = self.now(); record.before = CleanupVolume.mounted()
            record.notes = ["Verified external copy only. Original source is retained; no reclamation is performed."]
            do {
                try self.persist(record)
                for candidate in candidates {
                    try Task.checkCancellation()
                    self.currentPath = candidate.path; self.changed()
                    let index = record.items.count
                    record.items.append(.init(path: candidate.path, deleted: false, bytes: 0, reason: "Copy pending; source retained"))
                    try self.persist(record)
                    do {
                        let engine = self.engine, processes = try await self.processes()
                        guard !AutoCleanupEngine.inUse(candidate, processes: processes), self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else { throw AutoCleanupEngine.Failure.blocked("Owner or usage unknown; source kept") }
                        let reserved = try await self.work { try engine.prepareArchive(candidate, destination: destination) }
                        record.items[index].archive = reserved; try self.persist(record)
                        let verified = try await self.work { try engine.copyArchive(reserved, settings: settings) }
                        record.items[index].archive = verified
                        record.items[index].reason = "Whole external copy verified. Original retained; reclaimed space: 0 attributed bytes"
                    } catch {
                        record.items[index].reason = error.localizedDescription
                        if self.error == nil { self.error = "Copy blocked: " + error.localizedDescription + ". Original source kept." }
                    }
                    try self.persist(record)
                }
                try Task.checkCancellation(); record.finished = true
            } catch { self.error = error.localizedDescription; record.notes.append(error.localizedDescription) }
            record.after = CleanupVolume.mounted(); self.volumes = record.after ?? []
            do { try self.persist(record) } catch { self.error = "History save failed: " + error.localizedDescription }
            self.busy = false; self.running = false; self.currentPath = nil; self.task = nil
            self.changed(); self.completed()
        }
    }

    func confirmArchive() {
        guard Self.sourceReclaimEnabled else { error = CleanupReclaimSafety.explanation; changed(); return }
        guard allowOperations, !busy, !stopped, canRun(), let report = scan, !selected.isEmpty,
              let destination = archiveDestination else { return }
        let candidates = report.candidates.filter { selected.contains($0.path) }, settings = self.settings
        busy = true; running = true; error = nil; changed()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var record = CleanupRecord(automatic: false)
            record.date = self.now(); record.before = CleanupVolume.mounted()
            record.notes = ["External archive chosen: " + destination,
                "Allocated bytes are separate from measured free-space changes; APFS sharing and concurrent writes can change attribution."]
            self.activeRecordID = record.id
            do {
                try self.persist(record)
                var expectedRoots: [String: CleanupNode] = [:]
                for original in candidates {
                    try Task.checkCancellation()
                    self.currentPath = original.path; self.changed()
                    let candidate = CleanupCandidate(path: original.path, root: original.root, size: original.size, tree: original.tree,
                        hashes: original.hashes, attributes: original.attributes, rootNode: expectedRoots[original.root.path] ?? original.rootNode, volume: original.volume)
                    var receipt: CleanupArchiveReceipt?
                    let index = record.items.count
                    record.items.append(.init(path: candidate.path, deleted: false, bytes: 0, reason: "External copy pending; source intact"))
                    try self.persist(record)
                    do {
                        let engine = self.engine
                        let processes = try await self.processes()
                        guard !AutoCleanupEngine.inUse(candidate, processes: processes),
                              self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else {
                            throw AutoCleanupEngine.Failure.blocked("Owner/usage unverified; source kept")
                        }
                        receipt = try await self.work { try engine.prepareArchive(candidate, destination: destination) }
                        record.items[index].archive = receipt; try self.persist(record)
                        let reserved = receipt!
                        receipt = try await self.work { try engine.copyArchive(reserved, settings: settings) }
                        record.items[index].archive = receipt; try self.persist(record)
                        let verified = receipt!
                        receipt = try await self.work { try engine.prepareArchiveStage(verified) }
                        record.items[index].archive = receipt
                        record.items[index].receipt = receipt?.local
                        record.items[index].recoveryPath = receipt?.local?.recoveryPath
                        try self.persist(record)
                        let stageProcesses = try await self.processes(), prepared = receipt!, time = self.now()
                        guard self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else { throw AutoCleanupEngine.Failure.blocked("Owner changed; source kept") }
                        receipt = try await self.work { try engine.stageArchive(prepared, settings: settings, processes: stageProcesses, now: time) }
                        record.items[index].archive = receipt; try self.persist(record)
                        let finalProcesses = try await self.processes(), staged = receipt!
                        guard self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else { throw AutoCleanupEngine.Failure.blocked("Owner changed after staging; source removal blocked") }
                        // Re-query inode identities after staging, before any source removal.
                        receipt = try await self.work { try engine.reclaimArchive(staged, processes: finalProcesses) }
                        expectedRoots[candidate.root.path] = receipt?.sourceRootAfterStage
                        record.items[index].deleted = true
                        record.items[index].bytes = candidate.size
                        record.items[index].reason = "Source removed after whole external content/metadata verification; external recovery retained"
                    } catch {
                        if let failure = error as? CleanupArchiveFailure { receipt = failure.receipt }
                        record.items[index].reason = error.localizedDescription
                        // Before removal commit, return the full staged source when still idle.
                        if let local = receipt?.local, receipt?.phase.contains("reclaiming") != true,
                           receipt?.phase.contains("reclaimed") != true,
                           FileManager.default.fileExists(atPath: local.recoveryPath) {
                            let engine = self.engine, query = self.processes
                            let rollback = Task.detached(priority: .utility) {
                                let usage = try await query()
                                try engine.restore(local, processes: usage)
                            }
                            do { try await rollback.value; record.items[index].reason += "; staged source restored" }
                            catch { record.items[index].reason += "; full staged source kept for recovery: " + local.recoveryPath }
                        }
                    }
                    record.items[index].archive = receipt
                    try self.persist(record); self.changed()
                }
                try Task.checkCancellation()
                record.finished = true
            } catch { self.error = error.localizedDescription; record.notes.append(error.localizedDescription) }
            record.after = CleanupVolume.mounted(); self.volumes = record.after ?? []
            do { try self.persist(record) } catch { self.error = "History save failed: " + error.localizedDescription }
            self.scan = nil; self.selected = []
            self.busy = false; self.running = false; self.currentPath = nil; self.activeRecordID = nil; self.task = nil
            self.changed(); self.completed()
        }
    }

    func restore(recordID: UUID, index: Int) {
        guard allowOperations, !busy, !stopped, canRun(), let recordIndex = history.firstIndex(where: { $0.id == recordID }),
              history[recordIndex].items.indices.contains(index), history[recordIndex].items[index].restored != true else { return }
        let item = history[recordIndex].items[index]
        guard item.receipt != nil || item.archive?.copiedTree != nil else { return }
        busy = true; error = nil; changed()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let processes = try await self.processes()
                let candidate = item.archive?.candidate ?? item.receipt!.candidate
                guard self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else {
                    throw AutoCleanupEngine.Failure.blocked("Owner registration changed; manual recovery required")
                }
                let engine = self.engine
                let recovery: CleanupReceipt
                if let saved = item.restoreReceipt { recovery = saved }
                else if let archive = item.archive, archive.copiedTree != nil {
                    recovery = try await self.work { try engine.prepareArchiveRestore(archive, processes: processes) }
                    var journal = self.history.first { $0.id == recordID }!
                    journal.items[index].restoreReceipt = recovery
                    journal.items[index].restoreStagingPath = recovery.recoveryPath
                    try self.persist(journal)
                } else { recovery = item.receipt! }
                let finalUsage = try await self.processes()
                guard self.roots().contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) else { throw AutoCleanupEngine.Failure.blocked("Owner changed before restore; staging retained") }
                try await self.work { try engine.restore(recovery, processes: finalUsage) }
                var record = self.history.first { $0.id == recordID }!
                record.items[index].restored = true
                try self.persist(record)
            } catch {
                self.error = error.localizedDescription
                if let failure = error as? CleanupArchiveRestoreFailure {
                    var record = self.history.first { $0.id == recordID }!
                    record.items[index].restoreStagingPath = failure.stagingPath
                    do { try self.persist(record) } catch { self.error = "Restore staging retained; history save failed: " + failure.stagingPath }
                }
            }
            self.volumes = CleanupVolume.mounted()
            self.busy = false; self.task = nil; self.changed(); self.completed()
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func persist(_ record: CleanupRecord) throws {
        var records = history.filter { $0.id != record.id }
        records.insert(record, at: 0)
        // Recovery records must never age out while a receipt is unresolved.
        var completedCount = 0
        records = records.filter { entry in
            if entry.items.contains(where: { ($0.receipt != nil || $0.archive != nil) && $0.restored != true }) || !entry.finished { return true }
            completedCount += 1
            return completedCount <= 20
        }
        try engine.writeJournal(support: support, name: historyURL.lastPathComponent, data: JSONEncoder().encode(records))
        history = records
    }

    private func persistPreview(_ report: CleanupScan) throws {
        let lines = ["Cleanup preview · \(now())", "Candidates: \(report.candidates.count); allocated bytes (not free-space gain): \(report.bytes)"] +
            report.candidates.map { "\($0.root.category.label)\t\($0.size) bytes\t\($0.path)\t\($0.volume?.path ?? "unknown volume")\t\($0.reason)" } +
            ["", "Kept / skipped:"] + report.skipped
        try engine.writeJournal(support: support, name: previewURL.lastPathComponent, data: Data(lines.joined(separator: "\n").utf8))
    }

    private func start(automatic: Bool, deleting: Bool) {
        guard allowOperations, !stopped, !busy, canRun(), !settings.categories.isEmpty else { return }
        busy = true; running = deleting; error = nil; currentPath = nil
        let settings = self.settings
        let reviewed = automatic ? nil : scan
        let selected = self.selected
        changed()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var record = CleanupRecord(automatic: automatic)
            record.date = self.now()
            if deleting { self.activeRecordID = record.id }
            do {
                let engine = self.engine
                let roots = self.roots()
                let processes = try await self.processes()
                let now = self.now()
                let report: CleanupScan
                if deleting, let reviewed { report = reviewed }
                else {
                    let worker = Task.detached(priority: .utility) { try engine.scan(roots: roots, settings: settings, processes: processes, now: now) }
                    report = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                }
                try Task.checkCancellation()
                if deleting {
                    record.notes = report.skipped
                    record.before = CleanupVolume.mounted()
                    record.notes.append("Same-volume recovery moves retain storage. Candidate bytes are not freed space. APFS shared capacity and simultaneous writes affect measured free-space changes.")
                    // A durable start marker must succeed before the first deletion.
                    try self.persist(record)
                    var expectedRoots: [String: CleanupNode] = [:]
                    for candidate in report.candidates where selected.contains(candidate.path) {
                        try Task.checkCancellation()
                        self.currentPath = candidate.path; self.changed()
                        let currentProcesses = try await self.processes()
                        let result: CleanupRecord.Item
                        // Revalidate current owner registration as well as process state.
                        let currentRoots = self.roots()
                        if !currentRoots.contains(where: { $0.path == candidate.root.path && $0.owners == candidate.root.owners }) {
                            result = .init(path: candidate.path, deleted: false, bytes: 0, reason: "Owner registration changed")
                        } else {
                            let deletionTime = self.now()
                            // Reserve a durable receipt and journal intent before moving anything.
                            let receipt = try engine.prepare(candidate)
                            record.items.append(.init(path: candidate.path, deleted: false, bytes: 0,
                                reason: "Move pending; inspect recovery if interrupted", recoveryPath: receipt.recoveryPath, receipt: receipt))
                            try self.persist(record)
                            let expectedRoot = expectedRoots[candidate.root.path] ?? candidate.rootNode
                            let worker = Task.detached(priority: .utility) { try engine.move(receipt, settings: settings, processes: currentProcesses, now: deletionTime, expectedRoot: expectedRoot) }
                            do {
                                let updatedRoot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                                expectedRoots[candidate.root.path] = updatedRoot
                                result = .init(path: candidate.path, deleted: true, bytes: candidate.size, reason: "Moved to recovery; same-volume storage retained", recoveryPath: receipt.recoveryPath, receipt: receipt)
                            } catch {
                                result = .init(path: candidate.path, deleted: false, bytes: 0, reason: error.localizedDescription + "; check recovery receipt", recoveryPath: receipt.recoveryPath, receipt: receipt)
                            }
                            record.items.removeLast()
                        }
                        record.items.append(result)
                        // Persist each result so interruption does not erase earlier outcomes.
                        try self.persist(record); self.changed()
                    }
                    record.after = CleanupVolume.mounted()
                    self.volumes = record.after ?? []
                    record.finished = true
                    try self.persist(record)
                    self.scan = nil; self.selected = []
                } else {
                    try self.persistPreview(report)
                    self.scan = report; self.selected = []
                    self.volumes = CleanupVolume.mounted()
                }
            } catch {
                let message = error is CancellationError ? "Cleanup stopped. Completed moves and pending receipts remain recoverable; review history." : error.localizedDescription
                record.notes.append(message)
                self.error = message
                if deleting {
                    record.after = CleanupVolume.mounted()
                    do { try self.persist(record) }
                    catch { self.error = message + " History could not be saved: " + error.localizedDescription }
                }
            }
            self.busy = false; self.running = false; self.currentPath = nil; self.activeRecordID = nil; self.task = nil
            if deleting { self.completed() }
            self.changed()
        }
    }
}
