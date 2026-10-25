import AppKit
import UserNotifications

/// All state changes hop to the main queue, so captures from cleaner callbacks are safe.
final class StorageController: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private(set) var notificationPermission: UNAuthorizationStatus?
    private(set) var notificationAlertsEnabled = false
    private(set) var permissionRequestRunning = false
    private(set) var permissionError: String?
    var notificationPermissionLabel: String {
        Self.notificationPermissionLabel(notificationPermission, alertsEnabled: notificationAlertsEnabled)
    }
    static func notificationPermissionLabel(_ status: UNAuthorizationStatus?, alertsEnabled: Bool) -> String {
        guard let status else { return "Not checked" }
        switch status {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .authorized: return alertsEnabled ? "Allowed" : "Allowed · alerts disabled"
        case .provisional: return "Quiet delivery"
        case .ephemeral: return "Temporary permission"
        @unknown default: return "Unknown"
        }
    }
    private(set) var disk: DiskUsage?
    private(set) var volumes: [StorageVolume] = []
    private(set) var refreshingVolumes = false
    private(set) var volumesMeasuredAt: Date?
    private let volumeQueue = DispatchQueue(label: "RetroStats.volumes", qos: .utility)
    private var volumeGeneration = 0
    private var volumeRefreshPending = false
    private var mountObservers: [NSObjectProtocol] = []
    private(set) var cleaning = false
    private(set) var report: CacheReport?
    private var storageBusy = false
    var busy: Bool { storageBusy || autoCleanup.busy }
    let autoCleanup: AutoCleanupController
    private var task: Task<Void, Never>?
    #if DEBUG
    private var previewLocked = false
    #endif
    private(set) var lastError: String?
    private(set) var cleanProgress: CleanProgress?
    private(set) var scanPath: String?
    private var timer: Timer?
    private var stopped = false
    private var lastScan = Date.distantPast
    private var sendingNotification = false
    private let defaults = UserDefaults.standard
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RetroStats")
    private let servicesEnabled: Bool
    private let changed: () -> Void
    private let openMenu: () -> Void
    private let preview = CommandLine.arguments.contains("--preview-storage-warning")
    private var previewNotified = false
    var includeShared: Bool { defaults.bool(forKey: "includeShared") }
    private var notificationID: String { preview ? "storage-warning-preview" : "storage-warning" }

    init(changed: @escaping () -> Void, openMenu: @escaping () -> Void, startServices: Bool = true,
         autoCleanup: AutoCleanupController? = nil, volumeSnapshot: [StorageVolume] = []) {
        self.volumes = StorageVolumeCatalog.normalized(volumeSnapshot)
        self.volumesMeasuredAt = volumeSnapshot.map(\.measuredAt).max()
        self.servicesEnabled = startServices
        self.changed = changed
        self.openMenu = openMenu
        self.autoCleanup = autoCleanup ?? AutoCleanupController(
            support: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RetroStats"),
            allowOperations: startServices, changed: changed)
        super.init()
        self.autoCleanup.canRun = { [weak self] in
            guard let self else { return false }
            return !self.storageBusy && self.cleanProgress?.phase != .confirming
        }
        self.autoCleanup.completed = { [weak self] in
            guard let self, !self.stopped else { return }
            self.report = nil
            self.checkDisk()
        }
        if let data = try? Data(contentsOf: support.appendingPathComponent("report.json")) {
            report = try? CacheReport.decode(data)
        }
        if !startServices { disk = DiskUsage.read(); return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, !self.stopped else { return }
                if name == NSWorkspace.didUnmountNotification,
                   let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self.volumes.removeAll { $0.path == url.path }
                    self.changed()
                }
                self.refreshVolumes(invalidate: true)
            })
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if !preview {
            center.removeDeliveredNotifications(withIdentifiers: ["storage-warning-preview"])
            center.removePendingNotificationRequests(withIdentifiers: ["storage-warning-preview"])
        }
        let action = UNNotificationAction(identifier: "open-storage", title: "Storage Cleanup", options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "storage", actions: [action], intentIdentifiers: [], options: [])])
        refreshNotificationPermission()
        checkDisk()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkDisk()
            self.autoCleanup.tick()

        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkDisk() {
        if servicesEnabled { refreshVolumes() }
        disk = preview ? DiskUsage(total: 100_000_000_000, free: 45_000_000_000) : DiskUsage.read()
        guard servicesEnabled else { changed(); return }
        if let disk {
            if !disk.warning {
                if !preview { defaults.set(false, forKey: "storageAlertSent") }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
            } else if !(preview ? previewNotified : defaults.bool(forKey: "storageAlertSent")) {
                sendWarning(disk)
            }
        }
        changed()
    }

    /// Refreshes only capacity/identity. It never enumerates user files or changes mounts.
    func refreshVolumes(invalidate: Bool = false) {
        guard !stopped else { return }
        if invalidate { volumeGeneration += 1 }
        if refreshingVolumes {
            volumeRefreshPending = volumeRefreshPending || invalidate
            return
        }
        refreshingVolumes = true
        let generation = volumeGeneration
        changed()
        volumeQueue.async { [weak self] in
            let snapshot = StorageVolumeCatalog.read()
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.refreshingVolumes = false
                if generation == self.volumeGeneration {
                    self.volumes = snapshot
                    self.volumesMeasuredAt = Date()
                }
                self.changed()
                if self.volumeRefreshPending {
                    self.volumeRefreshPending = false
                    self.refreshVolumes()
                }
            }
        }
    }

    private func sendWarning(_ disk: DiskUsage) {
        guard !sendingNotification else { return }
        sendingNotification = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    self.sendingNotification = false
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = self.preview ? "Test · Storage cleanup alert" : "Storage usage at or above 50%"
                content.body = String(format: "Currently using %.1f%%. Open RetroStats' \"Storage Cleanup\" to review verified idle caches and recovery history.", disk.percent)
                content.categoryIdentifier = "storage"
                center.add(UNNotificationRequest(identifier: self.notificationID, content: content, trigger: nil)) { error in
                    DispatchQueue.main.async {
                        self.sendingNotification = false
                        if error == nil {
                            if self.preview { self.previewNotified = true }
                            else { self.defaults.set(true, forKey: "storageAlertSent") }
                        }
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.openMenu() }
        completionHandler()
    }

    func refreshNotificationPermission() {
        guard servicesEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.notificationPermission = settings.authorizationStatus
                self.notificationAlertsEnabled = settings.alertSetting == .enabled
                self.changed()
            }
        }
    }

    func requestNotificationPermission() {
        guard servicesEnabled, !permissionRequestRunning else { return }
        permissionRequestRunning = true
        permissionError = nil
        changed()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionRequestRunning = false
                self.permissionError = error?.localizedDescription
                self.refreshNotificationPermission()
                self.checkDisk()
                self.changed()
            }
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func revealRunningApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.jay.RetroStats")!)
    }

    func refresh() {
        autoCleanup.preview()
        return
        /* Legacy reporting is retained only for test fixtures.
        guard !busy, !stopped else { return }
        lastScan = Date()
        run(clean: false)
        */
    }

    func toggleShared() {
        guard !busy else { return }
        defaults.set(!includeShared, forKey: "includeShared")
        report = nil
        refresh()
    }

    func openFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
    }

    // Compatibility entry points are inert. All product cleanup uses the recoverable engine.
    func beginClean(paths: Set<String>) { }
    func confirmCleanRun() { }

    func cancelClean() {
        if cleanProgress?.phase == .confirming {
            cleanProgress = nil
            changed()
        } else if cleanProgress?.phase == .running {
            task?.cancel()
        }
    }

    func dismissCleanProgress() {
        cleanProgress = nil
        changed()
    }

    private func run(clean: Bool, paths: [String] = []) {
        guard !clean || !paths.isEmpty else { return }
        #if DEBUG
        guard !previewLocked else { return }
        #endif
        storageBusy = true
        cleaning = clean
        lastError = nil
        if clean, var progress = cleanProgress {
            progress.phase = .running
            progress.freedBytes = 0
            progress.error = nil
            for i in progress.items.indices { progress.items[i].state = .pending }
            if let firstIdx = progress.items.firstIndex(where: { $0.state == .pending }) {
                progress.items[firstIdx].state = .deleting
                progress.currentPath = progress.items[firstIdx].path
            }
            cleanProgress = progress
        }
        changed()
        let cleaner = DerivedDataCleaner()
        let includeShared = self.includeShared
        let support = self.support
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if clean {
                    try await cleaner.clean(paths: paths, hours: 8, includeShared: includeShared) { [weak self] event in
                        DispatchQueue.main.async { self?.applyCleanEvent(event) }
                    }
                } else {
                    let report = try await cleaner.scan(roots: cleaner.defaultRoots(), hours: 8, includeShared: includeShared) { path in
                        DispatchQueue.main.async { self.scanPath = path }
                    }
                    let data = try CacheReport.encode(report)
                    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                    try data.write(to: support.appendingPathComponent("report.json"), options: .atomic)
                    DispatchQueue.main.async {
                        self.report = report
                        self.finish()
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async { self.handleCleanCancelled() }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.handleRunError(message, clean: clean) }
            }
        }
    }

    private func applyCleanEvent(_ event: CleanEvent) {
        guard var progress = cleanProgress else { return }
        switch event {
        case .deleted(let path, let size):
            if let idx = progress.items.firstIndex(where: { $0.path == path }),
               progress.items[idx].state == .pending || progress.items[idx].state == .deleting {
                progress.items[idx].state = .deleted
                progress.freedBytes += size
            }
        case .kept(let path):
            if let idx = progress.items.firstIndex(where: { $0.path == path }),
               progress.items[idx].state == .pending || progress.items[idx].state == .deleting {
                progress.items[idx].state = .kept
            }
        case .done(let removed, let freedBytes):
            progress.phase = .done
            progress.currentPath = nil
            let log = progress.items.map { item -> String in
                switch item.state {
                case .deleted: return "Deleted: \(item.path)"
                case .kept: return "Kept (changed after scan): \(item.path)"
                default: return "\(item.path)"
                }
            }.joined(separator: "\n") + "\nCleanup complete: \(removed) items, allocated space freed \(bytes(UInt64(freedBytes)))"
            try? log.write(to: support.appendingPathComponent("last-cleanup.txt"), atomically: true, encoding: .utf8)
            cleanProgress = progress
            report = nil
            finish()
            checkDisk()
            refresh()
            return
        }
        if progress.phase == .running {
            if let nextIdx = progress.items.firstIndex(where: { $0.state == .pending }) {
                progress.items[nextIdx].state = .deleting
                progress.currentPath = progress.items[nextIdx].path
            } else {
                progress.currentPath = nil
            }
        }
        cleanProgress = progress
        changed()
    }

    private func handleCleanCancelled() {
        if var progress = cleanProgress {
            progress.phase = .cancelled
            progress.currentPath = nil
            cleanProgress = progress
        }
        finish()
        checkDisk()
        refresh()
    }

    private func handleRunError(_ message: String, clean: Bool) {
        lastError = message
        if clean, var progress = cleanProgress {
            progress.phase = .failed
            progress.error = message
            progress.currentPath = nil
            cleanProgress = progress
        }
        finish()
    }

    private func finish() {
        storageBusy = false
        cleaning = false
        scanPath = nil
        task = nil
        changed()
    }

    func stop() {
        stopped = true
        volumeGeneration += 1
        mountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        mountObservers.removeAll()
        timer?.invalidate()
        task?.cancel()
        autoCleanup.stop()
    }
}

#if DEBUG
extension StorageController {
    /// Preview-only factory. Builds a controller with injected state and no
    /// services, and locks `run` so preview interactions never scan or delete
    /// real DerivedData.
    static func preview(
        disk: DiskUsage? = DiskUsage(total: 500_000_000_000, free: 230_000_000_000, name: "Macintosh HD", available: 265_000_000_000),
        report: CacheReport? = nil,
        busy: Bool = false,
        cleaning: Bool = false,
        lastError: String? = nil,
        cleanProgress: CleanProgress? = nil,
        scanPath: String? = nil
    ) -> StorageController {
        let controller = StorageController(changed: {}, openMenu: {}, startServices: false)
        controller.previewLocked = true
        controller.disk = disk
        controller.volumes = disk.map { value in
            [StorageVolume(id: "preview-main", name: value.name, path: "/", location: .internalDrive, isMain: true,
                capacity: .init(total: Int64(clamping: value.total), free: Int64(clamping: value.free), available: value.available.map { Int64(clamping: $0) }),
                sharedContainerID: nil, measuredAt: Date())]
        } ?? []
        controller.report = report
        controller.storageBusy = busy
        controller.cleaning = cleaning
        controller.lastError = lastError
        controller.cleanProgress = cleanProgress
        controller.scanPath = scanPath
        return controller
    }
}
#endif
