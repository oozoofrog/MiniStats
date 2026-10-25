import AppKit
import SwiftUI

/// main.swift retains the service-free diagnostic entry points.
struct RetroStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuSummaryView(model: delegate.dashboard) { page in
                delegate.requestDashboard(page: page)
            }
        } label: {
            MenuBarSceneLabel(delegate: delegate)
        }
        .menuBarExtraStyle(.window)


        Window(PermissionGuideView.title, id: "permission-guide") {
            PermissionGuideView()
        }
        .defaultSize(width: 88, height: 88)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("RetroStats", id: "dashboard") {
            DashboardWindowView(model: delegate.dashboard)
        }
        .defaultSize(width: RetroLayout.dashboardSize.width, height: RetroLayout.dashboardSize.height)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.requestDashboard(page: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Dashboard") { delegate.requestDashboard(page: delegate.dashboard.page) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// The label stays installed while the popover is closed. Window actions must
/// come from a view environment, and requests need an explicit observation owner.
private struct MenuBarSceneLabel: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarReadout(model: delegate.dashboard)
            .onChange(of: delegate.dashboardRequest, initial: true) { _, request in
                guard let request else { return }
                delegate.consumeDashboardRequest(request)
                diagnostic("SwiftUI opening dashboard")
                openWindow(id: "dashboard")
                // Accessory apps must activate explicitly when a menu/notification
                // requests a detail window. SwiftUI still owns its entire lifetime.
                NSApp.activate()
            }
    }
}

private struct DashboardWindowView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DashboardView(model: model)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onAppear {
                diagnostic("Dashboard appeared")
                model.setPresented(true)
                model.storage?.checkDisk()
            }
            .onChange(of: scenePhase) { _, phase in
                model.setPresented(phase != .background)
                if phase == .active { model.storage?.refreshNotificationPermission() }
            }
            .onDisappear { model.setPresented(false) }
            .alert("Could not configure automatic launch", isPresented: Binding(
                get: { model.loginError != nil }, set: { if !$0 { model.loginError = nil } })) {
                Button("OK") { model.loginError = nil }
            } message: { Text(model.loginError ?? "") }
    }
}

/// A template image lets macOS choose the menu-bar tint, including selection.
/// There is no custom NSView intercepting menu-bar events or animation timer.
struct MenuBarReadout: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = statusReadoutImage(size: CGSize(width: 30, height: 22), scale: displayScale,
                                             cpu: model.cpu?.total, memory: model.memory?.percent,
                                             storagePercent: model.storage?.disk?.percent) {
                Image(decorative: image, scale: displayScale)
                    .renderingMode(.template)
                    .interpolation(.none)
            } else {
                Image(systemName: "desktopcomputer")
            }
        }
        .accessibilityLabel("RetroStats system monitor")
        .accessibilityValue(summary)
        .help(summary)
    }

    private var summary: String {
        let cpu = model.cpu.map { String(format: "CPU %.0f%%", $0.total) } ?? "CPU measuring…"
        let memory = model.memory.map { "Memory \(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Memory unavailable"
        let storage = model.storage?.disk?.description ?? "Storage unavailable"
        return "\(cpu), \(memory), Download \(model.download), Upload \(model.upload), \(storage)"
    }
}
