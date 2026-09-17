import AppKit
import UserNotifications

final class StorageController: NSObject, UNUserNotificationCenterDelegate {
    let menuItem = NSMenuItem(title: "Storage Cleanup", action: nil, keyEquivalent: "")
    private(set) var disk: DiskUsage?
    private(set) var cleaning = false
    private(set) var report: CacheReport?
    private(set) var busy = false
    private var task: Task<Void, Never>?
    #if DEBUG
    private var previewLocked = false
    #endif
    private(set) var lastError: String?
    private(set) var cleanProgress: CleanProgress?
    @Published private(set) var scanPath: String?
    private var timer: Timer?
    private var lastScan = Date.distantPast
    private var sendingNotification = false
    private var notificationsAllowed = false
    private var notificationError: String?
    private let defaults = UserDefaults.standard
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RetroStats")
    private let changed: () -> Void
    private let openMenu: () -> Void
    private let preview = CommandLine.arguments.contains("--preview-storage-warning")
    private var previewNotified = false
    var includeShared: Bool { defaults.bool(forKey: "includeShared") }
    private var notificationID: String { preview ? "storage-warning-preview" : "storage-warning" }

    init(changed: @escaping () -> Void, openMenu: @escaping () -> Void, startServices: Bool = true) {
        self.changed = changed
        self.openMenu = openMenu
        super.init()
        if startServices, defaults.object(forKey: "includeShared") == nil {
            defaults.set(UserDefaults(suiteName: "local.jaychoi.deriveddata-menu")?.bool(forKey: "includeShared") ?? false, forKey: "includeShared")
        }
        if let data = try? Data(contentsOf: support.appendingPathComponent("report.json")) {
            report = try? CacheReport.decode(data)
        }
        if !startServices { disk = DiskUsage.read(); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if !preview {
            center.removeDeliveredNotifications(withIdentifiers: ["storage-warning-preview"])
            center.removePendingNotificationRequests(withIdentifiers: ["storage-warning-preview"])
        }
        let action = UNNotificationAction(identifier: "open-storage", title: "Storage Cleanup", options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "storage", actions: [action], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert]) { allowed, error in
            DispatchQueue.main.async {
                self.notificationsAllowed = allowed
                self.notificationError = error?.localizedDescription
                self.checkDisk()
            }
        }
        checkDisk()
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkDisk()
            if Date().timeIntervalSince(self.lastScan) >= 3600 { self.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkDisk() {
        disk = preview ? DiskUsage(total: 100_000_000_000, free: 45_000_000_000) : DiskUsage.read()
        if let disk {
            if !disk.warning {
                if !preview { defaults.set(false, forKey: "storageAlertSent") }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
            } else if !(preview ? previewNotified : defaults.bool(forKey: "storageAlertSent")) {
                sendWarning(disk)
            }
        }
        rebuildMenu()
        changed()
    }

    private func sendWarning(_ disk: DiskUsage) {
        guard !sendingNotification else { return }
        sendingNotification = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                guard self.notificationsAllowed else {
                    self.sendingNotification = false
                    self.rebuildMenu()
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = self.preview ? "Test · Storage cleanup alert" : "Storage usage at or above 50%"
                content.body = String(format: "Currently using %.1f%%. Open RetroStats' \"Storage Cleanup\" to review and remove old DerivedData.", disk.percent)
                content.categoryIdentifier = "storage"
                center.add(UNNotificationRequest(identifier: self.notificationID, content: content, trigger: nil)) { error in
                    DispatchQueue.main.async {
                        self.sendingNotification = false
                        self.notificationError = error?.localizedDescription
                        if error == nil {
                            if self.preview { self.previewNotified = true }
                            else { self.defaults.set(true, forKey: "storageAlertSent") }
                        }
                        self.rebuildMenu()
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

    private func rebuildMenu() {
        menuItem.title = disk?.warning == true ? "⚠︎ Storage Cleanup · 50%+ used" : "Storage Cleanup"
        let menu = menuItem.submenu ?? NSMenu()
        menu.removeAllItems()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
            return item
        }
        _ = add(disk?.description ?? "Storage: read failed")
        if preview { _ = add("Test: show disk usage as 55% only") }
        if disk?.warning == true { _ = add("⚠︎ 50%+ used — review cleanup candidates") }
        menu.addItem(.separator())
        _ = add("DerivedData")
        if busy { _ = add(cleaning ? "Cleaning…" : "Checking capacity…") }
        if let report {
            _ = add("\(report.items.count) total items · \(bytes(UInt64(report.totalBytes)))")
            _ = add("\(report.candidates.count) cleanup candidates older than 8 hours · \(bytes(UInt64(report.candidateBytes)))")
            _ = add("Last checked: " + englishDateTime(Date(timeIntervalSince1970: report.generatedAt)))
            let projects = add("Project sizes · Reveal in Finder")
            projects.isEnabled = true
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for entry in report.items {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                let item = NSMenuItem(title: "\(entry.candidate ? "● " : "")\(bytes(UInt64(entry.size)))  \(name)", action: #selector(revealCache(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.path
                item.toolTip = entry.path + (entry.workspace.isEmpty ? "" : "\nProject: " + entry.workspace)
                submenu.addItem(item)
            }
            projects.submenu = submenu
        }
        if let lastError { _ = add("Scan/cleanup error — Show details…", #selector(showError)).toolTip = lastError }
        menu.addItem(.separator())
        _ = add("Check now", #selector(refresh), enabled: !busy)
        _ = add("Clean DerivedData older than 8 hours…", #selector(confirmAllClean), enabled: !busy && lastError == nil && !(report?.candidates.isEmpty ?? true))
        let shared = add("Include shared caches", #selector(toggleShared), enabled: !busy)
        shared.state = includeShared ? .on : .off
        _ = add("Open DerivedData folder", #selector(openFolder))
        menu.addItem(.separator())
        _ = add("Disk check: 1 min · DerivedData scan: 1 hour")
        _ = add("Cleanup is manual · Quit Xcode first")
        _ = add(notificationsAllowed ? "Cleanup alerts…" : "Cleanup alerts off — Enable…", #selector(openNotificationSettings))
        if let notificationError { _ = add("Notification error: " + notificationError) }
        menuItem.submenu = menu
    }

    @objc func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.jay.RetroStats")!)
    }

    @objc func refresh() {
        guard !busy else { return }
        lastScan = Date()
        run(clean: false)
    }

    @objc func toggleShared() {
        guard !busy else { return }
        defaults.set(!includeShared, forKey: "includeShared")
        report = nil
        refresh()
    }

    @objc private func revealCache(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
    }

    @objc private func showError() { alert("DerivedData operation failed", lastError ?? "No error details are available.") }

    @objc private func confirmAllClean() {
        guard beginClean(paths: Set(report?.candidates.map(\.path) ?? [])) else { return }
        openMenu()
    }

    @discardableResult
    func beginClean(paths: Set<String>) -> Bool {
        guard !busy, lastError == nil, let report, !paths.isEmpty else { return false }
        let entries = report.candidates.filter { paths.contains($0.path) }
        guard Set(entries.map(\.path)) == paths else { return false }
        cleanProgress = CleanProgress(
            phase: .confirming,
            items: entries.map { CleanProgress.Item(path: $0.path, size: $0.size) },
            freedBytes: 0, cancelled: false, currentPath: nil, summary: nil, error: nil
        )
        changed()
        return true
    }

    func confirmCleanRun() {
        guard let progress = cleanProgress, progress.phase == .confirming else { return }
        run(clean: true, paths: progress.items.map(\.path))
    }

    func cancelClean() {
        if cleanProgress?.phase == .confirming {
            cleanProgress = nil
            changed()
        } else if cleanProgress?.phase == .running {
            cleanProgress?.cancelled = true
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
        busy = true
        cleaning = clean
        lastError = nil
        if clean, var progress = cleanProgress {
            progress.phase = .running
            progress.cancelled = false
            progress.freedBytes = 0
            progress.summary = nil
            progress.error = nil
            for i in progress.items.indices { progress.items[i].state = .pending }
            if let firstIdx = progress.items.firstIndex(where: { $0.state == .pending }) {
                progress.items[firstIdx].state = .deleting
                progress.currentPath = progress.items[firstIdx].path
            }
            cleanProgress = progress
        }
        rebuildMenu()
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
                    let report = try await cleaner.scanReport(hours: 8, includeShared: includeShared) { path in
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
            progress.summary = "Cleanup complete: \(removed) items, allocated space freed \(bytes(UInt64(freedBytes)))"
            progress.phase = .done
            progress.currentPath = nil
            let log = progress.items.map { item -> String in
                switch item.state {
                case .deleted: return "Deleted: \(item.path)"
                case .kept: return "Kept (changed after scan): \(item.path)"
                default: return "\(item.path)"
                }
            }.joined(separator: "\n") + "\n" + (progress.summary ?? "")
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
        busy = false
        cleaning = false
        scanPath = nil
        task = nil
        rebuildMenu()
        changed()
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = message
        dialog.addButton(withTitle: "OK")
        dialog.runModal()
    }

    func stop() {
        timer?.invalidate()
        task?.cancel()
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
        controller.report = report
        controller.busy = busy
        controller.cleaning = cleaning
        controller.lastError = lastError
        controller.cleanProgress = cleanProgress
        controller.scanPath = scanPath
        return controller
    }
}
#endif
