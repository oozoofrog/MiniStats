import AppKit

/// Owned by StorageController. UI and published state use the main run loop;
/// filesystem work runs on utility tasks and receives cancellation explicitly.
final class AutoCleanupController: @unchecked Sendable {
    private(set) var settings: AutoCleanupSettings
    private(set) var scan: CleanupScan?
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
    static let settingsKey = "storageAutoCleanup.v1"

    init(defaults: UserDefaults = .standard, support: URL, allowOperations: Bool,
         engine: AutoCleanupEngine = AutoCleanupEngine(), roots: (@MainActor () -> [CleanupRoot])? = nil,
         processes: @escaping @Sendable () async throws -> [String] = { try await AutoCleanupEngine.processes() },
         now: @escaping @Sendable () -> Date = { Date() }, changed: @escaping () -> Void) {
        self.defaults = defaults; self.support = support
        self.allowOperations = allowOperations; self.changed = changed
        self.engine = engine; self.roots = roots ?? { engine.roots() }
        self.processes = processes; self.now = now
        var settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AutoCleanupSettings.self, from: $0) } ?? AutoCleanupSettings()
        settings.intervalDays = settings.intervalDays == 7 ? 7 : 1
        settings.exclusions = Set(settings.exclusions.compactMap(AutoCleanupEngine.exclusionPath))
        self.settings = settings
        if let data = try? Data(contentsOf: historyURL), let records = try? JSONDecoder().decode([CleanupRecord].self, from: data) {
            history = Array(records.prefix(20))
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

    func tick(now: Date = Date()) {
        guard settings.isDue(at: now), !busy, canRun(), allowOperations, !stopped else { return }
        settings.lastAttempt = now
        saveSettings()
        start(automatic: true, deleting: true)
    }

    func preview() { start(automatic: false, deleting: false) }
    func confirmDeletion() {
        guard hasReview, candidateCount > 0 else { return }
        start(automatic: false, deleting: true)
    }
    func cancel() { task?.cancel() }
    func stop() { stopped = true; task?.cancel() }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func persist(_ record: CleanupRecord) throws {
        var records = history.filter { $0.id != record.id }
        records.insert(record, at: 0)
        records = Array(records.prefix(20))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
        history = records
    }

    private func persistPreview(_ report: CleanupScan) throws {
        let lines = ["Cleanup preview · \(now())", "Candidates: \(report.candidates.count); estimated allocated bytes: \(report.bytes)"] +
            report.candidates.map { "\($0.root.category.label)\t\($0.size) bytes\t\($0.path)" } +
            ["", "Kept / skipped:"] + report.skipped
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: previewURL, atomically: true, encoding: .utf8)
    }

    private func start(automatic: Bool, deleting: Bool) {
        guard allowOperations, !stopped, !busy, canRun(), !settings.categories.isEmpty else { return }
        busy = true; running = deleting; error = nil; currentPath = nil
        let settings = self.settings
        let reviewed = automatic ? nil : scan
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
                    // A durable start marker must succeed before the first deletion.
                    try self.persist(record)
                    for candidate in report.candidates {
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
                            let worker = Task.detached(priority: .utility) { try engine.delete(candidate, settings: settings, processes: currentProcesses, now: deletionTime) }
                            do {
                                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                                result = .init(path: candidate.path, deleted: true, bytes: candidate.size, reason: "Deleted")
                            } catch is CancellationError { throw CancellationError() }
                            catch { result = .init(path: candidate.path, deleted: false, bytes: 0, reason: error.localizedDescription + "; a failed deletion may be partial") }
                        }
                        record.items.append(result)
                        // Persist each result so interruption does not erase earlier outcomes.
                        try self.persist(record); self.changed()
                    }
                    record.finished = true
                    try self.persist(record)
                    self.scan = nil
                } else {
                    try self.persistPreview(report)
                    self.scan = report
                }
            } catch {
                let message = error is CancellationError ? "Cleanup stopped. A current item may have been partially removed; review the history." : error.localizedDescription
                record.notes.append(message)
                self.error = message
                if deleting {
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
