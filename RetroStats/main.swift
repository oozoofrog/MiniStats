import AppKit

if CommandLine.arguments.contains("--self-test") {
    selfTest()
    try storageSelfTest()
    dashboardSelfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--render-dashboard"), CommandLine.arguments.count > index + 1 {
    registerEmbeddedFonts()
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
