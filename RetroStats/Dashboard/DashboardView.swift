import AppKit
import SwiftUI
import ServiceManagement

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var renderOnly = false
    @State private var selection: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ink = Color.primary
    private var storage: StorageController? { model.storage }
    private var selectedEntries: [CacheEntry] { storage?.report?.candidates.filter { selection.contains($0.path) } ?? [] }
    private var candidatePaths: [String] { storage?.report?.candidates.map(\.path) ?? [] }
    var body: some View {
        TransitionContainer(
            transition: model.transitionStyle.makeTransition(color: ink, duration: model.transitionSpeed.duration),
            currentPage: model.page
        ) { page in
            dashboardPanel(for: page)
        }
        .font(.bitmap(13))
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
        .frame(width: 400, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: candidatePaths) { _, newPaths in
            selection.formIntersection(newPaths)
        }
    }
    private func dashboardPanel(for page: DashboardPage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if page != .overview {
                    Button { model.page = .overview } label: { Image(systemName: "chevron.left").font(.system(size: 16)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Back to dashboard").accessibilityLabel("Back to dashboard")
                } else {
                    Image(systemName: "waveform.path").foregroundStyle(ink).font(.system(size: 19, weight: .semibold))
                }
                Text(titleFor(page)).font(.bitmap(18))
                Spacer()
                if page == .overview {
                    Text("Live").font(.bitmap(12)).foregroundStyle(.secondary)
                    PixelLED(size: 10, color: ink)
                }
                if page != .settings {
                    Button { model.refreshContext(); model.page = .settings } label: { PixelSliders(size: 18, color: ink).frame(width: 26, height: 26) }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            if renderOnly {
                GeometryReader { geometry in
                    pageContents(for: page).frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                }
            } else {
                ScrollView { pageContents(for: page) }
            }
            if page == .storage { storageActionBar.padding(.horizontal, 22).padding(.vertical, 12) }
            Divider().opacity(0.5)
            HStack {
                Text("\(ProcessInfo.processInfo.activeProcessorCount) cores · \(bytes(totalMemory))").font(.bitmap(11)).lineLimit(1)
                Spacer()
                Text("Refreshes every 3 seconds").font(.bitmap(11))
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
    }
    private func titleFor(_ page: DashboardPage) -> String {
        switch page {
        case .overview: return "RetroStats"
        case .processes: return "Processes"
        case .storage: return "Storage Cleanup"
        case .settings: return "Settings"
        }
    }
    private func pageContents(for page: DashboardPage) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            switch page {
            case .overview: overview
            case .processes: processDetails
            case .storage: storageDetails
            case .settings: settings
            }
        }.padding(.horizontal, 22).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                metric(order: .cpu, value: model.cpu?.total, subtitle: "All-core usage", history: model.cpuHistory)
                Rectangle().fill(ink.opacity(0.08)).frame(width: 1)
                metric(order: .memory, value: model.memory?.percent, subtitle: model.memory.map { "\(bytes($0.used)) / \(bytes(totalMemory))" } ?? "Measuring…", history: model.memoryHistory)
            }.fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            HStack {
                Label("Network", systemImage: "network").font(.bitmap(12))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("↓  \(model.download)").foregroundStyle(ink)
                    Text("↑  \(model.upload)").foregroundStyle(.secondary)
                }.font(.bitmap(12))
            }
            Button { model.page = .storage } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Storage", systemImage: "internaldrive")
                        Spacer()
                        Text(storage?.disk.map { String(format: "%.0f%%", $0.percent) } ?? "—")
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.font(.bitmap(12))
                    UsageBar(percent: storage?.disk?.percent ?? 0, color: ink, warning: storage?.disk?.warning == true)
                    HStack {
                        Text(storage?.disk.map { "Free \(bytes($0.free))" } ?? "Read failed")
                        Spacer()
                        if let report = storage?.report { Text("Cleanup candidates \(bytes(UInt64(report.candidateBytes)))") }
                        else { Text(storage?.busy == true ? "Checking…" : "Review candidates") }
                    }.font(.bitmap(10)).foregroundStyle(.secondary)
                }.padding(14).lcdPanel(cornerRadius: 14)
            }.buttonStyle(.plain).accessibilityRepresentation { Button("Open Storage Cleanup") { model.page = .storage } }
            HStack {
                Text(model.battery).font(.bitmap(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Activity Monitor") { openActivityMonitor() }.font(.bitmap(11)).buttonStyle(.pixelGhost)
            }
        }
    }
    private func metric(order: ProcessOrder, value: Double?, subtitle: String, history: [Double]) -> some View {
        Button { model.order = order; model.page = .processes } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(order == .cpu ? "CPU" : "MEM").font(.bitmap(12)).foregroundStyle(ink)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                LCDScreen {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.bitmap(40)).foregroundStyle(.white)
                            Text("%").font(.bitmap(16)).foregroundStyle(.white.opacity(0.6))
                        }
                        HistoryLine(values: history, color: .white).frame(height: 30)
                    }
                }
                Text(subtitle).font(.bitmap(10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("Top Processes").font(.bitmap(10)).foregroundStyle(.secondary)
                let rows = Array(order.sorted(model.processes).prefix(3))
                if rows.isEmpty {
                    Text(model.sampled && model.processes.isEmpty ? "No readable processes" : "Measuring…")
                        .font(.bitmap(10)).foregroundStyle(.secondary).frame(height: 54, alignment: .top)
                } else {
                    ForEach(rows) { process in
                        HStack(spacing: 4) {
                            Text(process.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(processValue(process, order: order)).foregroundStyle(.secondary).fixedSize()
                        }.font(.bitmap(10))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(order.rawValue) \(value.map { String(format: "%.0f%%", $0) } ?? "Measuring"), view top processes in detail")
    }
    private var processDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            PixelSegmentedControl(title: "Sort by",
                                  options: ProcessOrder.allCases.map { ($0, $0.rawValue) },
                                  selection: $model.order)
            HStack(alignment: .firstTextBaseline) {
                Text(model.order == .cpu ? (model.cpu.map { String(format: "%.0f%%", $0.total) } ?? "—") : model.memory.map { bytes($0.used) } ?? "—")
                    .font(.bitmap(32))
                Text(model.order == .cpu ? "All CPU" : "/ \(bytes(totalMemory))").font(.bitmap(12)).foregroundStyle(.secondary)
            }
            if model.order == .cpu {
                Text(model.cpu.map { String(format: "User %.1f%% · System %.1f%%", $0.user, $0.system) } ?? "Measuring…").font(.bitmap(11)).foregroundStyle(.secondary)
                Text(model.load).font(.bitmap(10)).foregroundStyle(.secondary)
            } else {
                if let memory = model.memory {
                    Text("App \(bytes(memory.app)) · Wired \(bytes(memory.wired)) · Compressed \(bytes(memory.compressed))").font(.bitmap(10)).foregroundStyle(.secondary)
                }
                Text(model.pressure + "\n" + model.swap).font(.bitmap(11)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Top 5").font(.bitmap(12))
                Spacer()
                Text(model.order == .cpu ? "CPU %" : "Memory").font(.bitmap(11)).foregroundStyle(.secondary)
            }.padding(.top, 4)
            let rows = Array(model.order.sorted(model.processes).prefix(5))
            if rows.isEmpty { Text(model.sampled && model.processes.isEmpty ? "No process information is available." : "Measuring CPU usage…").font(.bitmap(11)).foregroundStyle(.secondary).padding(.vertical, 20) }
            ForEach(rows) { process in
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary).font(.system(size: 19)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).font(.bitmap(12)).lineLimit(1)
                        Text("PID \(String(process.pid))").font(.bitmap(10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(processValue(process, order: model.order)).font(.bitmap(12))
                }.padding(.vertical, 4)
            }
            Text(model.order == .cpu ? "Only processes accessible to RetroStats are shown. Process CPU 100% represents one core; using multiple cores can exceed 100%." : "Only processes accessible to RetroStats are shown. Memory uses the same basis as the Memory column in Activity Monitor.")
                .font(.bitmap(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Activity Monitor") { openActivityMonitor() }.buttonStyle(.pixelGhost).controlSize(.small)
        }
    }
    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = storage?.disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(disk.free)).font(.bitmap(30))
                    Text("Free Space").font(.bitmap(12)).foregroundStyle(.secondary)
                }
                UsageBar(percent: disk.percent, color: ink, warning: disk.warning)
                Text(disk.description).font(.bitmap(10)).foregroundStyle(.secondary)
                if let detail = disk.detail { Text(detail).font(.bitmap(10)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DerivedData").font(.bitmap(14))
                    Text("Caches unused for more than 8 hours").font(.bitmap(10)).foregroundStyle(.secondary)
                }
                Spacer()
                if storage?.busy == true && storage?.cleaning == true { PixelHourglass(size: 14, color: ink) }
                Button { storage?.refresh() } label: { PixelRefresh(size: 16, color: storage?.busy == true ? .secondary : ink, animating: storage?.busy == true) }.disabled(storage?.busy == true).help("Check again").accessibilityLabel("Check DerivedData again")
            }
            if let progress = storage?.cleanProgress {
                cleanProgressSection(progress)
            } else {
                if storage?.busy == true { Text(storage?.cleaning == true ? "Cleaning selected caches…" : (storage?.scanPath.map { "Checking: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Checking cache size…")).font(.bitmap(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let error = storage?.lastError { Text(error).font(.bitmap(10)).foregroundStyle(.red).textSelection(.enabled) }
                if let report = storage?.report {
                    HStack {
                        Text("\(report.candidates.count) candidates · \(bytes(UInt64(report.candidateBytes)))")
                        Spacer()
                        Button(selection.count == candidatePaths.count && !selection.isEmpty ? "Deselect All" : "Select All") {
                            selection = selection.count == candidatePaths.count ? [] : Set(candidatePaths)
                        }.buttonStyle(.pixelGhost).disabled(storage?.busy == true || candidatePaths.isEmpty)
                    }.font(.bitmap(11))
                    if report.candidates.isEmpty { Text("No old caches need cleanup right now.").font(.bitmap(11)).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(report.candidates, id: \.path) { entry in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { selection.contains(entry.path) }, set: { if $0 { selection.insert(entry.path) } else { selection.remove(entry.path) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.bitmap(11))
                                    Text(bytes(UInt64(entry.size))).font(.bitmap(10)).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.pixelToggle).disabled(storage?.busy == true).help(entry.path)
                            Spacer(minLength: 0)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).help("Show in Finder").accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) Show in Finder")
                        }.padding(.vertical, 3)
                    }
                    Text("\(report.items.count) total caches · \(bytes(UInt64(report.totalBytes)))").font(.bitmap(10)).foregroundStyle(.secondary)
                    Text("Last checked \(englishDateTime(Date(timeIntervalSince1970: report.generatedAt)))")
                        .font(.bitmap(10)).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder
    private func cleanProgressSection(_ progress: CleanProgress) -> some View {
        switch progress.phase {
        case .confirming: cleanConfirmCard(progress)
        case .running: cleanRunningSection(progress)
        case .done, .cancelled: cleanResultSection(progress)
        case .failed: cleanFailedSection(progress)
        }
    }
    private func cleanConfirmCard(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permanently delete \(progress.totalCount) selected items totaling \(bytes(UInt64(progress.items.reduce(Int64(0)) { $0 + $1.size })))?").font(.bitmap(13))
            Text("Each item will be rechecked against the 8-hour threshold. Items in use are kept automatically.").font(.bitmap(11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(progress.items, id: \.path) { item in
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.bitmap(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("Quit Xcode and xcodebuild before cleanup, and do not start a new build while cleanup is running.").font(.bitmap(10)).foregroundStyle(.secondary)
        }.padding(14).lcdPanel(cornerRadius: 12)
    }
    private func cleanRunningSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanup Progress").font(.bitmap(14))
                Spacer()
                PixelHourglass(size: 14, color: ink)
            }
            HStack {
                Text("\(progress.resolvedCount) / \(progress.totalCount) items").font(.bitmap(13))
                Spacer()
                Text("Freed \(bytes(UInt64(progress.freedBytes)))").font(.bitmap(12)).foregroundStyle(.secondary)
            }
            UsageBar(percent: Double(progress.resolvedCount) / Double(max(progress.totalCount, 1)) * 100, color: ink)
            if let path = progress.currentPath {
                Text("Deleting: \(URL(fileURLWithPath: path).lastPathComponent)").font(.bitmap(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(progress.items, id: \.path) { item in
                    HStack(spacing: 8) {
                        cleanItemIcon(item.state)
                        Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.bitmap(11)).foregroundStyle(item.state == .pending || item.state == .kept ? .secondary : ink)
                        Spacer(minLength: 0)
                        Text(bytes(UInt64(item.size))).font(.bitmap(10)).foregroundStyle(.secondary)
                        Text(cleanItemTag(item.state)).font(.bitmap(10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }
    }
    private func cleanResultSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.phase == .cancelled ? "Cleanup Cancelled" : "Cleanup Complete").font(.bitmap(14))
                Spacer()
                Image(systemName: progress.phase == .cancelled ? "minus.circle" : "checkmark.circle").foregroundStyle(progress.phase == .cancelled ? Color.secondary : Color.green)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(UInt64(progress.freedBytes))).font(.bitmap(26))
                Text("Space Freed").font(.bitmap(12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("Deleted \(progress.deletedCount)").font(.bitmap(11)).foregroundStyle(.secondary)
                Text("Kept \(progress.keptCount)").font(.bitmap(11)).foregroundStyle(.secondary)
                Text("Total \(progress.totalCount)").font(.bitmap(11)).foregroundStyle(.secondary)
            }
            if progress.phase == .cancelled {
                Text("Cleanup was stopped. Only items processed before cancellation were applied.").font(.bitmap(10)).foregroundStyle(.secondary)
            }
        }
    }
    private func cleanFailedSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanup Failed").font(.bitmap(14))
                Spacer()
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let error = progress.error {
                Text(error).font(.bitmap(10)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder
    private func cleanItemIcon(_ state: CleanProgress.ItemState) -> some View {
        switch state {
        case .deleted: Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 11))
        case .deleting: PixelHourglass(size: 11, color: ink)
        case .kept: Image(systemName: "minus").foregroundStyle(.secondary).font(.system(size: 11))
        case .failed: Image(systemName: "xmark").foregroundStyle(.red).font(.system(size: 11))
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary).font(.system(size: 11))
        }
    }
    private func cleanItemTag(_ state: CleanProgress.ItemState) -> String {
        switch state {
        case .deleted: return "Deleted"
        case .deleting: return "Deleting"
        case .kept: return "Kept"
        case .failed: return "Failed"
        case .pending: return "Pending"
        }
    }
    private var storageActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if storage?.cleanProgress?.phase == .confirming {
                Button { storage?.confirmCleanRun() } label: {
                    Text("Run Deletion").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Button { storage?.cancelClean() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                Text("Quit Xcode and xcodebuild before cleanup. Selected items are permanently deleted after confirmation.").font(.bitmap(10)).foregroundStyle(.secondary)
            } else if storage?.cleanProgress?.phase == .running {
                Button { storage?.cancelClean() } label: {
                    Text("Cancel Cleanup").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Text("Do not start a new build while cleanup is running. Cancelling only applies items processed so far.").font(.bitmap(10)).foregroundStyle(.secondary)
            } else if let phase = storage?.cleanProgress?.phase, phase == .done || phase == .cancelled || phase == .failed {
                Button { storage?.dismissCleanProgress(); storage?.refresh() } label: {
                    Text("Check Again").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
            } else {
                Toggle("Include Shared Caches", isOn: Binding(get: { storage?.includeShared == true }, set: { _ in selection = []; storage?.toggleShared() }))
                    .toggleStyle(.pixelToggle).font(.bitmap(11)).disabled(storage?.busy == true)
                Button { storage?.beginClean(paths: Set(selectedEntries.map(\.path))) } label: {
                    Text("Clean \(selectedEntries.count) selected · \(bytes(UInt64(selectedEntries.reduce(Int64(0)) { $0 + $1.size })))").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary).disabled(selectedEntries.isEmpty || storage?.busy == true || storage?.lastError != nil)
                Text("Quit Xcode and xcodebuild before cleanup. Selected items are permanently deleted after confirmation.").font(.bitmap(10)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.pixel)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at Login", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin?(); model.refreshContext() }))
                .toggleStyle(.pixelToggle)
            if model.loginApproval { Button("Approve automatic launch in System Settings") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pixel) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Page Transition").font(.bitmap(12))
                PixelSegmentedControl(title: "Page Transition",
                                      options: TransitionStyle.allCases.map { ($0, $0.label) },
                                      selection: $model.transitionStyle)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Transition Speed").font(.bitmap(12))
                PixelSegmentedControl(title: "Transition Speed",
                                      options: TransitionSpeed.allCases.map { ($0, $0.label) },
                                      selection: $model.transitionSpeed)
            }
            Divider()
            Button("Configure Storage Alerts…") { storage?.openNotificationSettings() }
            Button("Open DerivedData Folder") { storage?.openFolder() }
            Button("Open Activity Monitor") { openActivityMonitor() }
            Text("Disk is checked every minute; cache size is checked every hour. Cleanup only runs when you start it.").font(.bitmap(11)).foregroundStyle(.secondary)
            Text("The appearance follows macOS Light/Dark Mode and accessibility settings.").font(.bitmap(11)).foregroundStyle(.secondary)
            Divider()
            Button("Quit RetroStats") { model.quit?() }.disabled(storage?.cleaning == true)
        }.buttonStyle(.pixelGhost)
    }
    private func processValue(_ process: RankedProcess, order: ProcessOrder) -> String {
        order == .cpu ? process.cpu.map { String(format: "%.1f%%", $0) } ?? "—" : bytes(process.memory)
    }
    private func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
}
