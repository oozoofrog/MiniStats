import AppKit

if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1" {
    // Xcode previews: skip the single-instance guard so a stale preview agent
    // doesn't force a new one to exit(0). The preview host still needs the run
    // loop, so fall through to NSApplication.shared.run() below without the
    // accessory policy/delegate setup that starts timers and menu-bar work.
    NSApplication.shared.run()
} else if CommandLine.arguments.contains("--self-test") {
    selfTest()
    do {
        try storageSelfTest()
        // derivedDataSelfTest is async; drive it with a Task + semaphore. It uses
        // only TaskGroup/async (no main run loop), so blocking the main thread is safe.
        let sem = DispatchSemaphore(value: 0)
        var ddError: Error?
        Task {
            do { try await derivedDataSelfTest() } catch let e { ddError = e }
            sem.signal()
        }
        sem.wait()
        if let ddError { throw ddError }
        dashboardSelfTest()
        transitionSelfTest()
    } catch {
        FileHandle.standardError.write(Data(("SELF-TEST FAILED: " + String(describing: error) + "\n").utf8))
        exit(1)
    }
    exit(0)
} else if let index = CommandLine.arguments.firstIndex(of: "--render-dashboard"), CommandLine.arguments.count > index + 1 {
    try MainActor.assumeIsolated { try renderDashboard(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if CommandLine.arguments.contains("--notification-status") {
    printNotificationStatus()
} else {
    let app = NSApplication.shared
    guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else { exit(0) }
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
