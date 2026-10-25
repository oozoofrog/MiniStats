import SwiftUI

/// A quick look shares metrics, but never owns the detail page or its sampling.
struct MenuSummaryView: View {
    @ObservedObject var model: DashboardModel
    var openDetail: (DashboardPage) -> Void
    var renderOnly = false
    @State var selectedPage: DashboardPage? = nil
    @State var showsVolumes = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    private var palette: RetroPalette { RetroPalette(finish: model.finish, scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            RetroTitleBar()
            VStack(spacing: 0) {
                metric("CPU", icon: "cpu", value: model.cpu.map { String(format: "%.0f%%", $0.total) } ?? "—",
                       detail: model.cpu == nil ? "Measuring…" : "Processor usage", page: .cpu)
                RetroRule()
                metric("Memory", icon: "memorychip", value: model.memory.map { String(format: "%.0f%%", $0.percent) } ?? "—",
                       detail: model.memory.map { "\(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Unavailable", page: .memory)
                RetroRule()
                metric("Network", icon: "network", value: "↓ \(model.download)",
                       detail: "↑ \(model.upload)", page: .network)
                RetroRule()
                metric("Storage", icon: "internaldrive", value: model.storage?.disk.map { "\(bytes($0.free)) free" } ?? "—",
                       detail: model.storage?.disk.map { String(format: "%.0f%% used", $0.percent) } ?? "Unavailable", page: .storage)
            }
            .padding(.horizontal, 14)
            DisclosureGroup("All Volumes (\(model.storage?.volumes.count ?? 0))", isExpanded: $showsVolumes) {
                if renderOnly {
                    // Match the live viewport while ImageRenderer draws its contents.
                    volumeList.fixedSize(horizontal: false, vertical: true)
                        .frame(height: volumeListHeight, alignment: .top).clipped()
                } else {
                    ScrollView { volumeList }.frame(height: volumeListHeight)
                }
            }
            .font(.bitmap(11)).padding(.horizontal, 14).padding(.top, 8)
            Button { show(selectedPage ?? model.page) } label: {
                HStack {
                    Text("Open Dashboard")
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                }
            }
            .buttonStyle(.pixel)
            .padding(14)
            RetroRule()
            HStack {
                Button("Settings…") { show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { model.quit?() }
                    .disabled(model.storage?.cleaning == true || model.storage?.autoCleanup.running == true)
            }
            .buttonStyle(.pixelGhost)
            .font(.bitmap(11))
            .padding(6)
            .background(palette.base)

        }
        .font(.bitmap(12))
        .textRenderer(BitmapTextRenderer())
        .foregroundStyle(palette.ink)
        .background(palette.paper)
        .environment(\.retroPalette, palette)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { diagnostic("Summary appeared"); model.setSummaryPresented(true); if !renderOnly { model.storage?.refreshVolumes() } }
        .onChange(of: scenePhase) { _, phase in model.setSummaryPresented(phase != .background) }
        .onDisappear { model.setSummaryPresented(false) }
        .onExitCommand { dismiss() }
    }

    private var volumeListHeight: CGFloat { min(240, CGFloat(max(1, model.storage?.volumes.count ?? 0)) * 85) }

    private var volumeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.storage?.volumes.isEmpty != false {
                Text(model.storage?.refreshingVolumes == true ? "Reading volumes…" : "Capacity unavailable")
                    .font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            ForEach(model.storage?.volumes ?? []) { volume in
                Button {
                    model.selectedStorageVolumeID = volume.id
                    show(.storage)
                } label: {
                    StorageVolumeRow(volume: volume).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Open this volume in Storage")
            }
        }.padding(.vertical, 8)
    }

    private func metric(_ title: String, icon: String, value: String, detail: String, page: DashboardPage) -> some View {
        let selected = selectedPage == page
        return Button { toggle(page) } label: {
            // The summary always defines layout. Its replacement is an overlay,
            // so neither animation nor dashboard content can resize this row.
            summaryRow(title, icon: icon, value: value, detail: detail)
                .hidden()
                .overlay {
                    TransitionContainer(
                        transition: model.transitionStyle.makeTransition(color: palette.ink, duration: model.transitionSpeed.duration),
                        currentPage: selected ? page : .overview
                    ) { visible in
                        if visible == .overview {
                            summaryRow(title, icon: icon, value: value, detail: detail)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            miniDashboard(title, value: value, page: page)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value), \(detail)")
        .accessibilityValue(selected ? "Dashboard" : "Summary")
        .accessibilityHint("Switches this row between summary and dashboard")
        .help("Switch \(title) view")
    }

    private func summaryRow(_ title: String, icon: String, value: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(value).multilineTextAlignment(.trailing)
                }
                Text(detail).font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(palette.muted)
        }
        .padding(.vertical, 14)
        .accessibilityHidden(true)
    }

    private func miniDashboard(_ title: String, value: String, page: DashboardPage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.bitmap(11))
                Spacer(minLength: 4)
                Text(value).font(.bitmap(12))
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
            }
            switch page {
            case .cpu:
                HistoryLine(values: model.cpuHistory, color: palette.phosphor, height: 18)
                Text(model.cpu.map { "User \(percent($0.user)) · System \(percent($0.system))" } ?? "Measuring…")
                    .font(.bitmap(9))
            case .memory:
                HistoryLine(values: model.memoryHistory, color: palette.phosphor, height: 18)
                Text(model.memory.map { "App \(bytes($0.app)) · Wired \(bytes($0.wired))" } ?? "Unavailable")
                    .font(.bitmap(9))
            case .network:
                HStack {
                    Text("↓ \(model.download)")
                    Spacer(minLength: 4)
                    Text("↑ \(model.upload)")
                }.font(.bitmap(12))
                Text("Physical interfaces · \(model.updateIntervalLabel) s").font(.bitmap(9))
            case .storage:
                if let disk = model.storage?.disk {
                    UsageBar(percent: disk.percent, color: palette.phosphor).frame(height: 10)
                    Text("\(percent(disk.percent)) used · \(bytes(disk.total)) total").font(.bitmap(9))
                } else {
                    Text("Unavailable").font(.bitmap(11))
                }
            default: EmptyView()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.base)
        .accessibilityHidden(true)
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }

    private func toggle(_ page: DashboardPage) {
        selectedPage = selectedPage == page ? nil : page
        diagnostic("Menu row replacement: \(String(describing: selectedPage))")
    }

    private func show(_ page: DashboardPage) {
        dismiss()
        openDetail(page)
    }
}
