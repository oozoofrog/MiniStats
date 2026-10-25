import AppKit
import SwiftUI

if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1" {
    // Xcode previews: skip the single-instance guard so a stale preview agent
    // doesn't force a new one to exit(0). The preview host still needs the run
    // loop, so fall through to NSApplication.shared.run() below without the
    // accessory policy/delegate setup that starts timers and menu-bar work.
    NSApplication.shared.run()
} else if CommandLine.arguments.contains("--self-test") {
    selfTest()
    MainActor.assumeIsolated { bitmapTextSelfTest() }
    do {
        try MainActor.assumeIsolated { try statusReadoutSelfTest() }
        try storageSelfTest()
        try storageVolumeSelfTest()
        try storageExplorerSelfTest()
        try MainActor.assumeIsolated { try storageExplorerModelSelfTest() }
        try MainActor.assumeIsolated { try autoCleanupSettingsSelfTest() }
        try MainActor.assumeIsolated { try autoCleanupControllerSelfTest() }
        if let destination = ProcessInfo.processInfo.environment["RETROSTATS_ARCHIVE_TEST_DESTINATION"] {
            try MainActor.assumeIsolated { try cleanupExternalCopyControllerSelfTest(destination: destination) }
        }
        // derivedDataSelfTest is async; drive it with a Task + semaphore. It uses
        // only TaskGroup/async (no main run loop), so blocking the main thread is safe.
        let sem = DispatchSemaphore(value: 0)
        var ddError: Error?
        Task {
            do {
                try await derivedDataSelfTest()
                try await autoCleanupSelfTest()
                if let destination = ProcessInfo.processInfo.environment["RETROSTATS_ARCHIVE_TEST_DESTINATION"] {
                    try await cleanupArchiveSelfTest(destination: destination)
                }
            } catch let e { ddError = e }
            sem.signal()
        }
        sem.wait()
        if let ddError { throw ddError }
        try MainActor.assumeIsolated { try tailscaleSelfTest() }
        dashboardSelfTest()
        transitionSelfTest()
    } catch {
        print("SELF-TEST FAILED: " + String(describing: error))
        fflush(stdout)
        FileHandle.standardError.write(Data(("SELF-TEST FAILED: " + String(describing: error) + "\n").utf8))
        exit(1)
    }
    exit(0)
} else if let index = CommandLine.arguments.firstIndex(of: "--bench-cleanup") {
    let items = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Int.init) ?? 100_000
    let sem = DispatchSemaphore(value: 0)
    var benchError: Error?
    Task {
        do { try await derivedDataBenchmark(items: items) } catch { benchError = error }
        sem.signal()
    }
    sem.wait()
    if let benchError {
        FileHandle.standardError.write(Data(("BENCH FAILED: " + String(describing: benchError) + "\n").utf8))
        exit(1)
    }
    exit(0)
} else if let index = CommandLine.arguments.firstIndex(of: "--render-menu-summary"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try renderMenuSummary(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-auto-cleanup"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try renderAutoCleanup(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if let index = CommandLine.arguments.firstIndex(of: "--show-cleanup-fixture"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try showCleanupUIFixture(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if CommandLine.arguments.contains("--show-tailscale-fixture") {
    MainActor.assumeIsolated { showTailscaleUIFixture() }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-dashboard"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try renderDashboard(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if CommandLine.arguments.contains("--notification-status") {
    printNotificationStatus()
} else {
    let instanceID = Bundle.main.bundleIdentifier ?? appID
    guard NSRunningApplication.runningApplications(withBundleIdentifier: instanceID).filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else { exit(0) }
    RetroStatsApp.main()
}
