import Foundation
import UserNotifications

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
    let data = Data(#"{"generated_at":0,"hours":8,"total_bytes":2048,"candidate_bytes":1024,"items":[{"path":"/tmp/test","size":1024,"workspace":"/tmp/App.xcodeproj","candidate":true},{"path":"/tmp/keep","size":1024,"workspace":"","candidate":false}]}"#.utf8)
    let report = try CacheReport.decode(data)
    precondition(report.candidates.count == 1 && report.totalBytes == 2048)
    precondition(report.candidates[0].path == "/tmp/test")
    let invalid = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "2048", with: "-1").utf8)
    precondition((try? CacheReport.decode(invalid)) == nil)
    guard let disk = DiskUsage.read() else { fatalError("Live storage read failed") }
    print("PASS: storage 49.99/50/50.01% threshold, capacity bounds, purgeable math, DerivedData report validation")
    print(disk.description + " · " + (disk.detail ?? "Available according to Finder: none"))
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
