import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var renderOnly = false

    var body: some View {
        GeometryReader { geometry in
            DashboardContentView(model: model, renderOnly: renderOnly)
                .environment(\.retroCompact, geometry.size.width < RetroLayout.sidebarBreakpoint)
        }
        .frame(minWidth: RetroLayout.dashboardMinimum.width, minHeight: RetroLayout.dashboardMinimum.height)
    }
}

/// One stable view identity owns selection at every width.
struct DashboardContentView: View {
    @Environment(\.openWindow) var openPermissionWindow
    @ObservedObject var model: DashboardModel
    var renderOnly = false
    @Environment(\.retroCompact) var compact
    @State var showsProcesses = false
    @StateObject var explorer = StorageExplorerModel()
    @State var explorerRowLimit = 30
    @State var selection: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    var palette: RetroPalette { RetroPalette(finish: model.finish, scheme: scheme) }
    var ink: Color { palette.ink }
    var storage: StorageController? { model.storage }
    var selectedEntries: [CacheEntry] { storage?.report?.candidates.filter { selection.contains($0.path) } ?? [] }
    var candidatePaths: [String] { storage?.report?.candidates.map(\.path) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            RetroTitleBar()
            if compact { compactNavigation }
            HStack(spacing: 0) {
                if !compact {
                    sidebar
                    Rectangle().fill(palette.line).frame(width: 1)
                }
                if renderOnly {
                    dashboardPanel(for: model.page)
                } else {
                    TransitionContainer(
                        transition: model.transitionStyle.makeTransition(color: ink, duration: model.transitionSpeed.duration),
                        currentPage: model.page
                    ) { page in dashboardPanel(for: page) }
                }
            }
            footer
        }
        .font(.bitmap(13))
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
        .foregroundStyle(ink)
        .background(palette.paper)
        .environment(\.retroPalette, palette)
        .tint(ink)
        .onChange(of: candidatePaths) { _, paths in selection.formIntersection(paths) }
        .onChange(of: model.page) { _, page in if page != .storage { explorer.reset() } }
        .onChange(of: model.selectedStorageVolumeID) { _, _ in explorer.reset() }
        .onChange(of: displayedVolumes) { _, _ in explorer.reconcile(selectedVolume) }
        .onChange(of: explorer.path) { _, _ in explorerRowLimit = 30 }
        .onDisappear { explorer.reset() }
        .onAppear { if !renderOnly { storage?.refreshVolumes() } }
    }

    private var compactNavigation: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            navigation("Home", icon: "square.grid.2x2", page: .overview)
            navigation("CPU", icon: "cpu", page: .cpu)
            navigation("Memory", icon: "memorychip", page: .memory)
            navigation("Network", icon: "network", page: .network)
            navigation("Storage", icon: "internaldrive", page: .storage)
            navigation("Settings", icon: "slider.horizontal.3", page: .settings)
        }
        .padding(6)
        .background(palette.base)
        .overlay(alignment: .bottom) { RetroRule() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarCaption("MONITOR")
            navigation("Overview", icon: "square.grid.2x2", page: .overview)
            navigation("CPU", icon: "cpu", page: .cpu)
            navigation("Memory", icon: "memorychip", page: .memory)
            navigation("Network", icon: "network", page: .network)
            sidebarCaption("MANAGE").padding(.top, 22)
            navigation("Storage", icon: "internaldrive", page: .storage)
            navigation("Settings", icon: "slider.horizontal.3", page: .settings)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 24)).accessibilityHidden(true)
                Text("THIS MAC")
                Text("Apple Silicon\n\(ProcessInfo.processInfo.activeProcessorCount) cores\n\(bytes(totalMemory))")
            }
            .font(.bitmap(11))
            .foregroundStyle(palette.muted)
            .padding(10)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 22)
        .frame(width: 156)
        .background(palette.base)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func sidebarCaption(_ text: String) -> some View {
        Text(text).font(.bitmap(11)).foregroundStyle(palette.muted).padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func navigation(_ title: String, icon: String, page: DashboardPage) -> some View {
        let selected = model.page == page
        return Button {
            if page == .settings { model.refreshContext() }
            model.page = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 16).accessibilityHidden(true)
                Text(title).font(.bitmap(11))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 5 : 9).padding(.vertical, compact ? 8 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? palette.paper : ink)
        .background(selected ? ink : .clear)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func dashboardPanel(for page: DashboardPage) -> some View {
        VStack(spacing: 0) {
            if renderOnly {
                // Render diagnostics expose the full page; the live window remains scrollable.
                pageContents(for: page).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView { pageContents(for: page) }
            }
            if page == .storage {
                RetroRule()
                storageActionBar.padding(compact ? 12 : 20).background(palette.base)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.paper)
    }

    private func pageContents(for page: DashboardPage) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch page {
            case .overview:
                RetroPageHeading(title: "Overview")
                overview
            case .cpu:
                RetroPageHeading(title: "CPU")
                processDetails(order: .cpu)
            case .memory:
                RetroPageHeading(title: "Memory")
                processDetails(order: .memory)
            case .network:
                RetroPageHeading(title: "Network")
                networkDetails
            case .storage:
                RetroPageHeading(title: "Storage")
                storageDetails
            case .settings:
                RetroPageHeading(title: "Settings")
                settings
            }
        }
        .padding(compact ? 16 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Rectangle().fill(ink).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("SYSTEM MONITOR")
            Spacer(minLength: 8)
            Text("UPDATE \(model.updateIntervalLabel) SEC")
        }
        .font(.bitmap(10, scaled: false))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { RetroRule() }
    }

    func processValue(_ process: RankedProcess, order: ProcessOrder) -> String {
        order == .cpu ? process.cpu.map { String(format: "%.1f%%", $0) } ?? "—" : bytes(process.memory)
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}
