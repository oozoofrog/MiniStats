import AppKit
import UserNotifications

struct DiskUsage {
    let total: UInt64
    let free: UInt64
    let name: String
    /// Finder's "available" figure: free space plus purgeable data. The 50% warning stays on `free`.
    let available: UInt64?
    var percent: Double { 100 * Double(total - free) / Double(total) }
    var warning: Bool { percent >= 50 }
    var purgeable: UInt64 { available.map { $0 > free ? $0 - free : 0 } ?? 0 }
    var description: String { String(format: "%@ %.1f%% 사용 · 여유 %@ / %@", name, percent, bytes(free), bytes(total)) }
    var detail: String? { available.map { "Finder 기준 사용 가능 \(bytes($0)) · 정리 가능 \(bytes(purgeable))" } }

    init?(total: UInt64, free: UInt64, name: String = "스토리지", available: UInt64? = nil) {
        guard total > 0, free <= total else { return nil }
        self.total = total
        self.free = free
        self.name = name
        self.available = available
    }

    static func read() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0, free >= 0 else { return nil }
        return DiskUsage(total: UInt64(total), free: UInt64(free), name: values.volumeName ?? "스토리지",
                         available: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) })
    }
}

struct CacheEntry: Decodable {
    let path: String
    let size: Int64
    let workspace: String
    let candidate: Bool
}

struct CacheReport: Decodable {
    let generatedAt: Double
    let hours: Int
    let totalBytes: Int64
    let candidateBytes: Int64
    let items: [CacheEntry]
    var candidates: [CacheEntry] { items.filter(\.candidate) }

    static func decode(_ data: Data) throws -> CacheReport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let report = try decoder.decode(CacheReport.self, from: data)
        guard report.hours == 8, report.generatedAt.isFinite,
              report.totalBytes >= 0, report.candidateBytes >= 0,
              report.items.allSatisfy({ $0.size >= 0 && $0.path.hasPrefix("/") }) else {
            throw NSError(domain: "RetroStats", code: 1, userInfo: [NSLocalizedDescriptionKey: "DerivedData 조회 결과가 올바르지 않습니다."])
        }
        return report
    }
}

struct CleanProgress {
    enum Phase { case confirming, running, done, failed, cancelled }
    enum ItemState { case pending, deleting, deleted, kept, failed }
    struct Item {
        let path: String
        let size: Int64
        var state: ItemState = .pending
    }
    var phase: Phase
    var items: [Item]
    var freedBytes: Int64
    var cancelled: Bool
    var currentPath: String?
    var summary: String?
    var error: String?
    var totalCount: Int { items.count }
    var resolvedCount: Int { items.filter { $0.state == .deleted || $0.state == .kept || $0.state == .failed }.count }
    var deletedCount: Int { items.filter { $0.state == .deleted }.count }
    var keptCount: Int { items.filter { $0.state == .kept }.count }
}

final class StorageController: NSObject, UNUserNotificationCenterDelegate {
    let menuItem = NSMenuItem(title: "스토리지 정리", action: nil, keyEquivalent: "")
    private(set) var disk: DiskUsage?
    private(set) var cleaning = false
    private(set) var report: CacheReport?
    private(set) var busy = false
    private var running: Process?
    private(set) var lastError: String?
    private(set) var cleanProgress: CleanProgress?
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
        let action = UNNotificationAction(identifier: "open-storage", title: "스토리지 정리", options: .foreground)
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
                content.title = self.preview ? "테스트 · 스토리지 정리 알림" : "스토리지 50% 이상 사용"
                content.body = String(format: "현재 %.1f%% 사용 중입니다. RetroStats의 ‘스토리지 정리’에서 오래된 DerivedData를 확인하고 정리하세요.", disk.percent)
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
        menuItem.title = disk?.warning == true ? "⚠︎ 스토리지 정리 · 50% 이상 사용" : "스토리지 정리"
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
        _ = add(disk?.description ?? "스토리지: 읽기 실패")
        if preview { _ = add("테스트: 디스크 사용률만 55%로 표시") }
        if disk?.warning == true { _ = add("⚠︎ 50% 이상 사용 — 정리 후보를 확인하세요") }
        menu.addItem(.separator())
        _ = add("DerivedData")
        if busy { _ = add(cleaning ? "정리 중…" : "용량 조회 중…") }
        if let report {
            _ = add("전체 \(report.items.count)개 · \(bytes(UInt64(report.totalBytes)))")
            _ = add("8시간 기준 정리 후보 \(report.candidates.count)개 · \(bytes(UInt64(report.candidateBytes)))")
            _ = add("최근 조회: " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: report.generatedAt), dateStyle: .short, timeStyle: .short))
            let projects = add("프로젝트별 용량 · Finder에서 보기")
            projects.isEnabled = true
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for entry in report.items {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                let item = NSMenuItem(title: "\(entry.candidate ? "● " : "")\(bytes(UInt64(entry.size)))  \(name)", action: #selector(revealCache(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.path
                item.toolTip = entry.path + (entry.workspace.isEmpty ? "" : "\n프로젝트: " + entry.workspace)
                submenu.addItem(item)
            }
            projects.submenu = submenu
        }
        if let lastError { _ = add("조회/정리 오류 — 자세히 보기…", #selector(showError)).toolTip = lastError }
        menu.addItem(.separator())
        _ = add("지금 다시 조회", #selector(refresh), enabled: !busy)
        _ = add("8시간 이상 된 DerivedData 정리…", #selector(confirmAllClean), enabled: !busy && lastError == nil && !(report?.candidates.isEmpty ?? true))
        let shared = add("공용 캐시 포함", #selector(toggleShared), enabled: !busy)
        shared.state = includeShared ? .on : .off
        _ = add("DerivedData 폴더 열기", #selector(openFolder))
        menu.addItem(.separator())
        _ = add("디스크 확인: 1분 · DerivedData 조회: 1시간")
        _ = add("정리는 직접 실행 · Xcode 종료 필요")
        _ = add(notificationsAllowed ? "정리 알림 설정…" : "정리 알림 꺼짐 — 허용하기…", #selector(openNotificationSettings))
        if let notificationError { _ = add("알림 오류: " + notificationError) }
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

    @objc private func showError() { alert("DerivedData 작업 오류", lastError ?? "오류 정보가 없습니다.") }

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
            running?.terminate()
        }
    }

    func dismissCleanProgress() {
        cleanProgress = nil
        changed()
    }

    private func run(clean: Bool, paths: [String] = []) {
        guard !clean || !paths.isEmpty else { return }
        guard let script = Bundle.main.url(forResource: "deriveddata", withExtension: "py") else {
            lastError = "앱에 DerivedData 정리 도구가 없습니다. RetroStats를 다시 빌드하세요."
            rebuildMenu()
            changed()
            return
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--hours", "8", "--jobs", "4", clean ? "--clean" : "--json"] + (includeShared ? ["--include-shared"] : []) + paths.flatMap { ["--only-path", $0] }
        running = process
        let support = self.support
        DispatchQueue.global(qos: .utility).async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: support, withIntermediateDirectories: true)
                let temporary = fm.temporaryDirectory.appendingPathComponent("ministats-" + UUID().uuidString)
                try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: temporary) }
                let errorURL = temporary.appendingPathComponent("stderr")
                fm.createFile(atPath: errorURL.path, contents: nil)
                let errors = try FileHandle(forWritingTo: errorURL)
                defer { try? errors.close() }
                let stdoutPipe: Pipe? = clean ? Pipe() : nil
                if let stdoutPipe {
                    process.standardOutput = stdoutPipe
                } else {
                    let outputURL = temporary.appendingPathComponent("stdout")
                    fm.createFile(atPath: outputURL.path, contents: nil)
                    let output = try FileHandle(forWritingTo: outputURL)
                    defer { try? output.close() }
                    // Files avoid pipe-buffer deadlocks during a long scan.
                    process.standardOutput = output
                }
                process.standardError = errors
                var collectedLines: [String] = []
                if let stdoutPipe {
                    let readHandle = stdoutPipe.fileHandleForReading
                    let readGroup = DispatchGroup()
                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        var lineBuffer = Data()
                        while true {
                            let chunk = readHandle.availableData
                            if chunk.isEmpty { break }
                            lineBuffer.append(chunk)
                            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                                let line = String(data: lineBuffer.subdata(in: 0..<nl), encoding: .utf8) ?? ""
                                lineBuffer.removeSubrange(0...nl)
                                collectedLines.append(line)
                                self.handleCleanLine(line)
                            }
                        }
                        if !lineBuffer.isEmpty {
                            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                            collectedLines.append(line)
                            self.handleCleanLine(line)
                        }
                        readGroup.leave()
                    }
                    try process.run()
                    process.waitUntilExit()
                    readGroup.wait()
                } else {
                    try process.run()
                    process.waitUntilExit()
                }
                let stderr = try String(contentsOf: errorURL, encoding: .utf8)
                if clean {
                    let stdout = collectedLines.joined(separator: "\n")
                    try (stdout + "\n" + stderr).write(to: support.appendingPathComponent("last-cleanup.txt"), atomically: true, encoding: .utf8)
                    if process.terminationStatus != 0 {
                        let message = String((stdout + "\n" + stderr).suffix(6000))
                        DispatchQueue.main.async {
                            if self.cleanProgress?.cancelled == true {
                                self.cleanProgress?.phase = .cancelled
                            } else {
                                self.cleanProgress?.phase = .failed
                                self.cleanProgress?.error = message
                                self.lastError = message
                            }
                            self.finish()
                            self.checkDisk()
                            self.refresh()
                        }
                    } else {
                        let summary = stdout.split(separator: "\n").last.map(String.init) ?? "정리가 완료되었습니다."
                        DispatchQueue.main.async {
                            if var progress = self.cleanProgress {
                                progress.phase = .done
                                progress.summary = summary
                                self.cleanProgress = progress
                            }
                            self.report = nil
                            self.finish()
                            self.checkDisk()
                            self.refresh()
                        }
                    }
                } else {
                    let outputURL = temporary.appendingPathComponent("stdout")
                    let data = try Data(contentsOf: outputURL)
                    if process.terminationStatus != 0 {
                        let stdout = String(decoding: data, as: UTF8.self)
                        throw NSError(domain: "DerivedData", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String((stdout + "\n" + stderr).suffix(6000))])
                    }
                    let report = try CacheReport.decode(data)
                    try data.write(to: support.appendingPathComponent("report.json"), options: .atomic)
                    DispatchQueue.main.async {
                        self.report = report
                        self.finish()
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.lastError = message
                    if clean, var progress = self.cleanProgress {
                        progress.phase = .failed
                        progress.error = message
                        self.cleanProgress = progress
                    }
                    self.finish()
                }
            }
        }
    }

    private func handleCleanLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { self.applyCleanLine(trimmed) }
    }

    private func applyCleanLine(_ line: String) {
        guard var progress = cleanProgress else { return }
        var didChange = false
        if line.hasPrefix("삭제: ") {
            let rest = String(line.dropFirst("삭제: ".count))
            if let parenRange = rest.range(of: " (", options: .backwards) {
                let path = String(rest[..<parenRange.lowerBound])
                if let idx = progress.items.firstIndex(where: { $0.path == path }), progress.items[idx].state == .pending || progress.items[idx].state == .deleting {
                    progress.items[idx].state = .deleted
                    progress.freedBytes += progress.items[idx].size
                    didChange = true
                }
            }
        } else if line.hasPrefix("유지 (조회 이후 변경됨): ") {
            let prefix = "유지 (조회 이후 변경됨): "
            let path = String(line.dropFirst(prefix.count))
            if let idx = progress.items.firstIndex(where: { $0.path == path }), progress.items[idx].state == .pending || progress.items[idx].state == .deleting {
                progress.items[idx].state = .kept
                didChange = true
            }
        } else if line.hasPrefix("정리 완료: ") {
            progress.summary = line
            didChange = true
        }
        if didChange, progress.phase == .running {
            if let nextIdx = progress.items.firstIndex(where: { $0.state == .pending }) {
                progress.items[nextIdx].state = .deleting
                progress.currentPath = progress.items[nextIdx].path
            } else {
                progress.currentPath = nil
            }
        }
        if didChange {
            cleanProgress = progress
            changed()
        }
    }

    private func finish() {
        busy = false
        cleaning = false
        running = nil
        rebuildMenu()
        changed()
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = message
        dialog.addButton(withTitle: "확인")
        dialog.runModal()
    }

    func stop() {
        timer?.invalidate()
        if running?.isRunning == true { running?.interrupt() }
    }
}

func storageSelfTest() throws {
    precondition(DiskUsage(total: 0, free: 0) == nil)
    precondition(DiskUsage(total: 100, free: 101) == nil)
    precondition(DiskUsage(total: 10000, free: 5001)?.warning == false)
    precondition(DiskUsage(total: 10000, free: 5000)?.warning == true)
    precondition(DiskUsage(total: 10000, free: 4999)?.warning == true)
    precondition(DiskUsage(total: 100, free: 0)?.percent == 100)
    precondition(DiskUsage(total: 100, free: 100)?.percent == 0)
    precondition(DiskUsage(total: 100, free: 40, available: 55)?.purgeable == 15)
    precondition(DiskUsage(total: 100, free: 40, available: 30)?.purgeable == 0)
    precondition(DiskUsage(total: 100, free: 40)?.detail == nil)
    let data = Data(#"{"generated_at":0,"hours":8,"total_bytes":2048,"candidate_bytes":1024,"items":[{"path":"/tmp/테스트","size":1024,"workspace":"/tmp/App.xcodeproj","candidate":true},{"path":"/tmp/keep","size":1024,"workspace":"","candidate":false}]}"#.utf8)
    let report = try CacheReport.decode(data)
    precondition(report.candidates.count == 1 && report.totalBytes == 2048)
    precondition(report.candidates[0].path == "/tmp/테스트")
    let invalid = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "2048", with: "-1").utf8)
    precondition((try? CacheReport.decode(invalid)) == nil)
    precondition(Bundle.main.url(forResource: "deriveddata", withExtension: "py") != nil)
    guard let disk = DiskUsage.read() else { fatalError("Live storage read failed") }
    print("PASS: storage 49.99/50/50.01% threshold, capacity bounds, purgeable math, DerivedData report validation, bundled cleaner")
    print(disk.description + " · " + (disk.detail ?? "Finder 기준 사용 가능: 없음"))
}

func printNotificationStatus() {
    let finished = DispatchSemaphore(value: 0)
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        print("notifications authorized: \(settings.authorizationStatus == .authorized), alerts enabled: \(settings.alertSetting == .enabled)")
        center.getDeliveredNotifications { notifications in
            print("delivered: \(notifications.map { $0.request.identifier })")
            finished.signal()
        }
    }
    if finished.wait(timeout: .now() + 5) == .timedOut { fatalError("Notification status timed out") }
}
