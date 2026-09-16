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
            transition: model.transitionStyle.makeTransition(seed: 0, color: ink),
            currentPage: model.page
        ) { page in
            dashboardPanel(for: page)
        }
        .font(.pixel(13))
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
                    Button { model.page = .overview } label: { Image(systemName: "chevron.left").font(.pixel(16)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("대시보드로 돌아가기").accessibilityLabel("대시보드로 돌아가기")
                } else {
                    Image(systemName: "waveform.path").foregroundStyle(ink).font(.system(size: 19, weight: .semibold))
                }
                Text(titleFor(page)).font(.pixel(18))
                Spacer()
                if page == .overview {
                    Text("실시간").font(.pixel(12)).foregroundStyle(.secondary)
                    PixelLED(size: 10, color: ink)
                }
                Button { model.refreshContext(); model.page = .settings } label: { PixelSliders(size: 18, color: ink).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("설정").accessibilityLabel("설정")
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
                Text("\(ProcessInfo.processInfo.activeProcessorCount)코어 · \(bytes(totalMemory))").font(.pixel(11)).lineLimit(1)
                Spacer()
                Text("3초마다 갱신").font(.pixel(11))
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
    }
    private func titleFor(_ page: DashboardPage) -> String {
        switch page {
        case .overview: return "RetroStats"
        case .processes: return "프로세스"
        case .storage: return "스토리지 정리"
        case .settings: return "설정"
        }
    }
    private var pageContents: some View {
        pageContents(for: model.page)
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
                metric(order: .cpu, value: model.cpu?.total, subtitle: "전체 코어 사용률", history: model.cpuHistory)
                Rectangle().fill(ink.opacity(0.08)).frame(width: 1)
                metric(order: .memory, value: model.memory?.percent, subtitle: model.memory.map { "\(bytes($0.used)) / \(bytes(totalMemory))" } ?? "측정 중…", history: model.memoryHistory)
            }.fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            HStack {
                Label("네트워크", systemImage: "network").font(.pixel(12))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("↓  \(model.download)").foregroundStyle(ink)
                    Text("↑  \(model.upload)").foregroundStyle(.secondary)
                }.font(.pixel(12))
            }
            Button { model.page = .storage } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("스토리지", systemImage: "internaldrive")
                        Spacer()
                        Text(storage?.disk.map { String(format: "%.0f%%", $0.percent) } ?? "—")
                        Image(systemName: "chevron.right").font(.pixel(10)).foregroundStyle(.secondary)
                    }.font(.pixel(12))
                    UsageBar(percent: storage?.disk?.percent ?? 0, color: ink, warning: storage?.disk?.warning == true)
                    HStack {
                        Text(storage?.disk.map { "여유 \(bytes($0.free))" } ?? "읽기 실패")
                        Spacer()
                        if let report = storage?.report { Text("정리 후보 \(bytes(UInt64(report.candidateBytes)))") }
                        else { Text(storage?.busy == true ? "조회 중…" : "후보 확인") }
                    }.font(.pixel(10)).foregroundStyle(.secondary)
                }.padding(14).lcdPanel(cornerRadius: 14)
            }.buttonStyle(.plain).accessibilityRepresentation { Button("스토리지 정리 열기") { model.page = .storage } }
            HStack {
                Text(model.battery).font(.pixel(11)).foregroundStyle(.secondary)
                Spacer()
                Button("활성 상태 보기") { openActivityMonitor() }.font(.pixel(11)).buttonStyle(.pixelGhost)
            }
        }
    }
    private func metric(order: ProcessOrder, value: Double?, subtitle: String, history: [Double]) -> some View {
        Button { model.order = order; model.page = .processes } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(order == .cpu ? "CPU" : "MEM").font(.pixel(12)).foregroundStyle(ink)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.pixel(10)).foregroundStyle(.secondary)
                }
                LCDScreen {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.pixel(40)).foregroundStyle(.white)
                            Text("%").font(.pixel(16)).foregroundStyle(.white.opacity(0.6))
                        }
                        HistoryLine(values: history, color: .white).frame(height: 30)
                    }
                }
                Text(subtitle).font(.pixel(10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("상위 프로세스").font(.pixel(10)).foregroundStyle(.secondary)
                let rows = Array(order.sorted(model.processes).prefix(3))
                if rows.isEmpty {
                    Text(model.sampled && model.processes.isEmpty ? "읽을 수 있는 프로세스 없음" : "측정 중…")
                        .font(.pixel(10)).foregroundStyle(.secondary).frame(height: 54, alignment: .top)
                } else {
                    ForEach(rows) { process in
                        HStack(spacing: 4) {
                            Text(process.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(processValue(process, order: order)).foregroundStyle(.secondary).fixedSize()
                        }.font(.pixel(10))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(order.rawValue) \(value.map { String(format: "%.0f%%", $0) } ?? "측정 중"), 상위 프로세스 자세히 보기")
    }
    private var processDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("정렬 기준", selection: $model.order) {
                ForEach(ProcessOrder.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(model.order == .cpu ? (model.cpu.map { String(format: "%.0f%%", $0.total) } ?? "—") : model.memory.map { bytes($0.used) } ?? "—")
                    .font(.pixel(32))
                Text(model.order == .cpu ? "전체 CPU" : "/ \(bytes(totalMemory))").font(.pixel(12)).foregroundStyle(.secondary)
            }
            if model.order == .cpu {
                Text(model.cpu.map { String(format: "사용자 %.1f%% · 시스템 %.1f%%", $0.user, $0.system) } ?? "측정 중…").font(.pixel(11)).foregroundStyle(.secondary)
                Text(model.load).font(.pixel(10)).foregroundStyle(.secondary)
            } else {
                if let memory = model.memory {
                    Text("앱 \(bytes(memory.app)) · Wired \(bytes(memory.wired)) · 압축 \(bytes(memory.compressed))").font(.pixel(10)).foregroundStyle(.secondary)
                }
                Text(model.pressure + "\n" + model.swap).font(.pixel(11)).foregroundStyle(.secondary)
            }
            HStack {
                Text("상위 5개").font(.pixel(12))
                Spacer()
                Text(model.order == .cpu ? "CPU %" : "메모리").font(.pixel(11)).foregroundStyle(.secondary)
            }.padding(.top, 4)
            let rows = Array(model.order.sorted(model.processes).prefix(5))
            if rows.isEmpty { Text(model.sampled && model.processes.isEmpty ? "프로세스 정보를 읽을 수 없습니다." : "CPU 사용량을 측정하고 있습니다…").font(.pixel(11)).foregroundStyle(.secondary).padding(.vertical, 20) }
            ForEach(rows) { process in
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary).font(.system(size: 19)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).font(.pixel(12)).lineLimit(1)
                        Text("PID \(String(process.pid))").font(.pixel(10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(processValue(process, order: model.order)).font(.pixel(12))
                }.padding(.vertical, 4)
            }
            Text(model.order == .cpu ? "접근 가능한 프로세스만 표시합니다. 프로세스 CPU 100%는 코어 1개 기준으로, 여러 코어를 사용하면 100%를 넘을 수 있습니다." : "접근 가능한 프로세스만 표시합니다. 메모리는 활성 상태 보기의 메모리 열과 같은 기준입니다.")
                .font(.pixel(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("활성 상태 보기 열기") { openActivityMonitor() }.buttonStyle(.pixelGhost).controlSize(.small)
        }
    }
    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = storage?.disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(disk.free)).font(.pixel(30))
                    Text("여유 공간").font(.pixel(12)).foregroundStyle(.secondary)
                }
                UsageBar(percent: disk.percent, color: ink, warning: disk.warning)
                Text(disk.description).font(.pixel(10)).foregroundStyle(.secondary)
                if let detail = disk.detail { Text(detail).font(.pixel(10)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DerivedData").font(.pixel(14))
                    Text("8시간 이상 사용하지 않은 캐시").font(.pixel(10)).foregroundStyle(.secondary)
                }
                Spacer()
                if storage?.busy == true && storage?.cleaning == true { PixelHourglass(size: 14, color: ink) }
                Button { storage?.refresh() } label: { PixelRefresh(size: 16, color: storage?.busy == true ? .secondary : ink, animating: storage?.busy == true) }.disabled(storage?.busy == true).help("다시 조회").accessibilityLabel("DerivedData 다시 조회")
            }
            if let progress = storage?.cleanProgress {
                cleanProgressSection(progress)
            } else {
                if storage?.busy == true { Text(storage?.cleaning == true ? "선택한 캐시 정리 중…" : (storage?.scanPath.map { "조회 중: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "캐시 용량을 조회하고 있습니다…")).font(.pixel(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let error = storage?.lastError { Text(error).font(.pixel(10)).foregroundStyle(.red).textSelection(.enabled) }
                if let report = storage?.report {
                    HStack {
                        Text("후보 \(report.candidates.count)개 · \(bytes(UInt64(report.candidateBytes)))")
                        Spacer()
                        Button(selection.count == candidatePaths.count && !selection.isEmpty ? "선택 해제" : "모두 선택") {
                            selection = selection.count == candidatePaths.count ? [] : Set(candidatePaths)
                        }.buttonStyle(.pixelGhost).disabled(storage?.busy == true || candidatePaths.isEmpty)
                    }.font(.pixel(11))
                    if report.candidates.isEmpty { Text("지금 정리할 오래된 캐시가 없습니다.").font(.pixel(11)).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(report.candidates, id: \.path) { entry in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { selection.contains(entry.path) }, set: { if $0 { selection.insert(entry.path) } else { selection.remove(entry.path) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.pixel(11))
                                    Text(bytes(UInt64(entry.size))).font(.pixel(10)).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.pixelToggle).disabled(storage?.busy == true).help(entry.path)
                            Spacer(minLength: 0)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).help("Finder에서 보기").accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) Finder에서 보기")
                        }.padding(.vertical, 3)
                    }
                    Text("전체 캐시 \(report.items.count)개 · \(bytes(UInt64(report.totalBytes)))").font(.pixel(10)).foregroundStyle(.secondary)
                    Text("최근 조회 \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: report.generatedAt), dateStyle: .short, timeStyle: .short))")
                        .font(.pixel(10)).foregroundStyle(.secondary)
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
            Text("선택한 \(progress.totalCount)개 · \(bytes(UInt64(progress.items.reduce(Int64(0)) { $0 + $1.size })))를 영구 삭제할까요?").font(.pixel(13))
            Text("8시간 기준으로 다시 검사한 뒤 삭제합니다. 사용 중인 항목은 자동으로 유지됩니다.").font(.pixel(11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(progress.items, id: \.path) { item in
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.pixel(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("정리 전 Xcode와 xcodebuild를 종료하고, 정리 중에는 새 빌드를 시작하지 마세요.").font(.pixel(10)).foregroundStyle(.secondary)
        }.padding(14).lcdPanel(cornerRadius: 12)
    }
    private func cleanRunningSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("정리 진행").font(.pixel(14))
                Spacer()
                ProgressView().controlSize(.small)
            }
            HStack {
                Text("\(progress.resolvedCount) / \(progress.totalCount) 항목").font(.pixel(13))
                Spacer()
                Text("확보 \(bytes(UInt64(progress.freedBytes)))").font(.pixel(12)).foregroundStyle(.secondary)
            }
            UsageBar(percent: Double(progress.resolvedCount) / Double(max(progress.totalCount, 1)) * 100, color: ink)
            if let path = progress.currentPath {
                Text("삭제 중: \(URL(fileURLWithPath: path).lastPathComponent)").font(.pixel(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(progress.items, id: \.path) { item in
                    HStack(spacing: 8) {
                        cleanItemIcon(item.state)
                        Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.pixel(11)).foregroundStyle(item.state == .pending || item.state == .kept ? .secondary : ink)
                        Spacer(minLength: 0)
                        Text(bytes(UInt64(item.size))).font(.pixel(10)).foregroundStyle(.secondary)
                        Text(cleanItemTag(item.state)).font(.pixel(10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }
    }
    private func cleanResultSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.phase == .cancelled ? "정리 취소" : "정리 완료").font(.pixel(14))
                Spacer()
                Image(systemName: progress.phase == .cancelled ? "minus.circle" : "checkmark.circle").foregroundStyle(progress.phase == .cancelled ? Color.secondary : Color.green)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(UInt64(progress.freedBytes))).font(.pixel(26))
                Text("확보된 공간").font(.pixel(12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("삭제 \(progress.deletedCount)").font(.pixel(11)).foregroundStyle(.secondary)
                Text("유지 \(progress.keptCount)").font(.pixel(11)).foregroundStyle(.secondary)
                Text("전체 \(progress.totalCount)").font(.pixel(11)).foregroundStyle(.secondary)
            }
            if progress.phase == .cancelled {
                Text("정리를 중단했습니다. 진행 중인 항목까지만 반영됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            }
        }
    }
    private func cleanFailedSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("정리 실패").font(.pixel(14))
                Spacer()
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let error = progress.error {
                Text(error).font(.pixel(10)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder
    private func cleanItemIcon(_ state: CleanProgress.ItemState) -> some View {
        switch state {
        case .deleted: Image(systemName: "checkmark").foregroundStyle(.green).font(.pixel(11))
        case .deleting: ProgressView().controlSize(.mini)
        case .kept: Image(systemName: "minus").foregroundStyle(.secondary).font(.pixel(11))
        case .failed: Image(systemName: "xmark").foregroundStyle(.red).font(.pixel(11))
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary).font(.pixel(11))
        }
    }
    private func cleanItemTag(_ state: CleanProgress.ItemState) -> String {
        switch state {
        case .deleted: return "삭제됨"
        case .deleting: return "삭제 중"
        case .kept: return "유지"
        case .failed: return "실패"
        case .pending: return "대기"
        }
    }
    private var storageActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if storage?.cleanProgress?.phase == .confirming {
                Button { storage?.confirmCleanRun() } label: {
                    Text("삭제 실행").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Button { storage?.cancelClean() } label: {
                    Text("취소").frame(maxWidth: .infinity)
                }
                Text("정리 전 Xcode와 xcodebuild를 종료하세요. 선택한 항목은 확인 후 영구 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            } else if storage?.cleanProgress?.phase == .running {
                Button { storage?.cancelClean() } label: {
                    Text("정리 취소").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Text("정리 중에는 새 빌드를 시작하지 마세요. 취소하면 진행 중인 항목까지만 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            } else if let phase = storage?.cleanProgress?.phase, phase == .done || phase == .cancelled || phase == .failed {
                Button { storage?.dismissCleanProgress(); storage?.refresh() } label: {
                    Text("다시 조회").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
            } else {
                Toggle("공용 캐시 포함", isOn: Binding(get: { storage?.includeShared == true }, set: { _ in selection = []; storage?.toggleShared() }))
                    .toggleStyle(.pixelToggle).font(.pixel(11)).disabled(storage?.busy == true)
                Button { storage?.beginClean(paths: Set(selectedEntries.map(\.path))) } label: {
                    Text("선택한 \(selectedEntries.count)개 정리 · \(bytes(UInt64(selectedEntries.reduce(Int64(0)) { $0 + $1.size })))").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary).disabled(selectedEntries.isEmpty || storage?.busy == true || storage?.lastError != nil)
                Text("정리하려면 Xcode와 xcodebuild를 종료하세요. 선택한 항목은 확인 후 영구 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.pixel)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin?(); model.refreshContext() }))
                .toggleStyle(.pixelToggle)
            if model.loginApproval { Button("시스템 설정에서 자동 실행 승인") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pixel) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("화면 전환 효과").font(.pixel(12))
                Picker("화면 전환 효과", selection: $model.transitionStyle) {
                    ForEach(TransitionStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            Button("스토리지 알림 설정…") { storage?.openNotificationSettings() }
            Button("DerivedData 폴더 열기") { storage?.openFolder() }
            Button("활성 상태 보기 열기") { openActivityMonitor() }
            Text("디스크는 1분마다, 캐시 용량은 1시간마다 확인합니다. 정리는 직접 실행할 때만 진행합니다.").font(.pixel(11)).foregroundStyle(.secondary)
            Text("화면 모양은 macOS의 밝은 모드·어두운 모드 및 손쉬운 사용 설정을 따릅니다.").font(.pixel(11)).foregroundStyle(.secondary)
            Divider()
            Button("RetroStats 종료") { model.quit?() }.disabled(storage?.cleaning == true)
        }.buttonStyle(.pixelGhost)
    }
    private func processValue(_ process: RankedProcess, order: ProcessOrder) -> String {
        order == .cpu ? process.cpu.map { String(format: "%.1f%%", $0) } ?? "—" : bytes(process.memory)
    }
    private func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
}
