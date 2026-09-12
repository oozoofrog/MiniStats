import AppKit
import SwiftUI
import ServiceManagement

struct RankedProcess: Identifiable {
    let pid: pid_t
    let start: UInt64
    let name: String
    let cpu: Double?
    let memory: UInt64
    var id: String { "\(pid):\(start)" }
}

func rankedProcesses(before: [pid_t: ProcessSample], after: [pid_t: ProcessSample], seconds: Double) -> [RankedProcess] {
    after.map { pid, sample in
        var cpu: Double?
        if seconds.isFinite, seconds >= 1, let old = before[pid], old.start == sample.start, sample.cpuTime >= old.cpuTime {
            cpu = 100 * Double(sample.cpuTime - old.cpuTime) / 1e9 / seconds
        }
        return RankedProcess(pid: pid, start: sample.start, name: sample.name, cpu: cpu, memory: sample.memory)
    }
}

enum ProcessOrder: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "메모리"
    var id: String { rawValue }
    func sorted(_ processes: [RankedProcess]) -> [RankedProcess] {
        let eligible = self == .cpu ? processes.filter { $0.cpu != nil } : processes
        return eligible.sorted {
            let lhs = self == .cpu ? ($0.cpu ?? 0) : Double($0.memory)
            let rhs = self == .cpu ? ($1.cpu ?? 0) : Double($1.memory)
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }
    }
}

enum DashboardPage { case overview, processes, storage, settings }

final class DashboardModel: ObservableObject {
    @Published var page: DashboardPage = .overview
    @Published var order: ProcessOrder = .cpu
    @Published var cpu: CPULoad?
    @Published var memory: MemoryUsage?
    @Published var download = "—"
    @Published var upload = "—"
    @Published var battery = ""
    @Published var pressure = ""
    @Published var swap = ""
    @Published var load = ""
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var processes: [RankedProcess] = []
    @Published var sampled = false
    @Published var loginEnabled = false
    @Published var loginApproval = false
    var storage: StorageController?
    var toggleLogin: (() -> Void)?
    var quit: (() -> Void)?
    private let readProcesses: () -> [pid_t: ProcessSample]
    init(readProcesses: @escaping () -> [pid_t: ProcessSample] = processSamples) { self.readProcesses = readProcesses }
    private let queue = DispatchQueue(label: "MiniStats.processes", qos: .utility)
    private var previous: [pid_t: ProcessSample] = [:]
    private var previousTime: Double?
    private var generation = 0
    private var active = false
    private var pendingGeneration: Int?

    func begin() {
        generation += 1
        active = true
        previous = [:]
        previousTime = nil
        processes = []
        sampled = false
        refreshContext()
        sampleProcesses()
    }
    func end() {
        active = false
        generation += 1
        previous = [:]
        previousTime = nil
        processes = []
        sampled = false
    }
    func refreshContext() {
        battery = batteryText()
        pressure = memoryPressureText()
        swap = swapText()
        load = loadAverageText()
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func update(cpu: CPULoad?, memory: MemoryUsage?, rates: (Double, Double)?) {
        self.cpu = cpu
        self.memory = memory
        download = rates.map { speed($0.0) } ?? "—"
        upload = rates.map { speed($0.1) } ?? "—"
        if let cpu { cpuHistory = Array((cpuHistory + [cpu.total]).suffix(40)) }
        if let memory { memoryHistory = Array((memoryHistory + [memory.percent]).suffix(40)) }
        if active { refreshContext(); sampleProcesses() }
    }
    func sampleProcesses() {
        guard active, pendingGeneration != generation else { return }
        let token = generation
        pendingGeneration = token
        let readProcesses = self.readProcesses
        queue.async { [weak self] in
            let samples = readProcesses()
            diagnostic("Process generation \(token): \(samples.count) entries")
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pendingGeneration == token { self.pendingGeneration = nil }
                guard self.active, self.generation == token else { return }
                let seconds = self.previousTime.map { now - $0 } ?? 0
                self.processes = rankedProcesses(before: self.previous, after: samples, seconds: seconds)
                self.previous = samples
                self.previousTime = now
                self.sampled = true
            }
        }
    }
}

struct HistoryLine: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(values.count - 1),
                                        y: geometry.size.height * (1 - min(max(value, 0), 100) / 100))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }.frame(height: 38).accessibilityHidden(true)
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
            }
        }.frame(height: 5).accessibilityLabel("사용률").accessibilityValue(String(format: "%.0f%%", percent))
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var renderOnly = false
    @State private var selection: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color.accentColor
    private let purple = Color.purple
    private var storage: StorageController? { model.storage }
    private var selectedEntries: [CacheEntry] { storage?.report?.candidates.filter { selection.contains($0.path) } ?? [] }
    private var candidatePaths: [String] { storage?.report?.candidates.map(\.path) ?? [] }
    private var title: String {
        switch model.page {
        case .overview: return "MiniStats"
        case .processes: return "프로세스"
        case .storage: return "스토리지 정리"
        case .settings: return "설정"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.page != .overview {
                    Button { model.page = .overview } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("대시보드로 돌아가기").accessibilityLabel("대시보드로 돌아가기")
                } else {
                    Image(systemName: "waveform.path").foregroundStyle(blue).font(.system(size: 19, weight: .semibold))
                }
                Text(title).font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.page == .overview {
                    Text("실시간").font(.caption).foregroundStyle(.secondary)
                    Circle().fill(Color.green).frame(width: 5, height: 5).accessibilityHidden(true)
                }
                Button { model.refreshContext(); model.page = .settings } label: { Image(systemName: "gearshape").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("설정").accessibilityLabel("설정")
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            if renderOnly {
                GeometryReader { geometry in
                    pageContents.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                }
            } else {
                ScrollView { pageContents }
            }
            if model.page == .storage { storageActionBar.padding(.horizontal, 22).padding(.vertical, 12) }
            Divider().opacity(0.5)
            HStack {
                Text("\(ProcessInfo.processInfo.activeProcessorCount)코어 · \(bytes(totalMemory))").lineLimit(1)
                Spacer()
                Text("3초마다 갱신")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 400, height: 600)
        .onChange(of: candidatePaths) { selection.formIntersection($0) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.page)
    }
    private var pageContents: some View {
        VStack(alignment: .leading, spacing: 19) {
            switch model.page {
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
                metric(order: .cpu, value: model.cpu?.total, subtitle: "전체 코어 사용률", history: model.cpuHistory, color: blue)
                Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
                metric(order: .memory, value: model.memory?.percent, subtitle: model.memory.map { "\(bytes($0.used)) / \(bytes(totalMemory))" } ?? "측정 중…", history: model.memoryHistory, color: purple)
            }.fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            HStack {
                Label("네트워크", systemImage: "network").font(.system(size: 12, weight: .medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("↓  \(model.download)").foregroundStyle(blue)
                    Text("↑  \(model.upload)").foregroundStyle(.secondary)
                }.font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            Button { model.page = .storage } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("스토리지", systemImage: "internaldrive")
                        Spacer()
                        Text(storage?.disk.map { String(format: "%.0f%%", $0.percent) } ?? "—").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }.font(.system(size: 12, weight: .medium))
                    UsageBar(percent: storage?.disk?.percent ?? 0, color: storage?.disk?.warning == true ? .orange : blue)
                    HStack {
                        Text(storage?.disk.map { "여유 \(bytes($0.free))" } ?? "읽기 실패")
                        Spacer()
                        if let report = storage?.report { Text("정리 후보 \(bytes(UInt64(report.candidateBytes)))") }
                        else { Text(storage?.busy == true ? "조회 중…" : "후보 확인") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityRepresentation { Button("스토리지 정리 열기") { model.page = .storage } }
            HStack {
                Text(model.battery).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("활성 상태 보기") { openActivityMonitor() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(blue)
            }
        }
    }
    private func metric(order: ProcessOrder, value: Double?, subtitle: String, history: [Double], color: Color) -> some View {
        Button { model.order = order; model.page = .processes } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(order.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: 40, weight: .light, design: .rounded))
                    Text("%").font(.system(size: 17)).foregroundStyle(.secondary)
                }.monospacedDigit()
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                HistoryLine(values: history, color: color).padding(.vertical, 4)
                Text("상위 프로세스").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                let rows = Array(order.sorted(model.processes).prefix(3))
                if rows.isEmpty {
                    Text(model.sampled && model.processes.isEmpty ? "읽을 수 있는 프로세스 없음" : "측정 중…")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 54, alignment: .top)
                } else {
                    ForEach(rows) { process in
                        HStack(spacing: 4) {
                            Text(process.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(processValue(process, order: order)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        }.font(.system(size: 10))
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
                    .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                Text(model.order == .cpu ? "전체 CPU" : "/ \(bytes(totalMemory))").font(.caption).foregroundStyle(.secondary)
            }
            if model.order == .cpu {
                Text(model.cpu.map { String(format: "사용자 %.1f%% · 시스템 %.1f%%", $0.user, $0.system) } ?? "측정 중…").font(.caption).foregroundStyle(.secondary)
                Text(model.load).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                if let memory = model.memory {
                    Text("앱 \(bytes(memory.app)) · Wired \(bytes(memory.wired)) · 압축 \(bytes(memory.compressed))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(model.pressure + "\n" + model.swap).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("상위 5개").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.order == .cpu ? "CPU %" : "메모리").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 4)
            let rows = Array(model.order.sorted(model.processes).prefix(5))
            if rows.isEmpty { Text(model.sampled && model.processes.isEmpty ? "프로세스 정보를 읽을 수 없습니다." : "CPU 사용량을 측정하고 있습니다…").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20) }
            ForEach(rows) { process in
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary).font(.system(size: 19)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("PID \(String(process.pid))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(processValue(process, order: model.order)).font(.system(size: 12, weight: .medium, design: .monospaced))
                }.padding(.vertical, 4)
            }
            Text(model.order == .cpu ? "접근 가능한 프로세스만 표시합니다. 프로세스 CPU 100%는 코어 1개 기준으로, 여러 코어를 사용하면 100%를 넘을 수 있습니다." : "접근 가능한 프로세스만 표시합니다. 메모리는 활성 상태 보기의 메모리 열과 같은 기준입니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("활성 상태 보기 열기") { openActivityMonitor() }.controlSize(.small)
        }
    }
    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = storage?.disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(disk.free)).font(.system(size: 30, weight: .light, design: .rounded))
                    Text("여유 공간").font(.caption).foregroundStyle(.secondary)
                }
                UsageBar(percent: disk.percent, color: disk.warning ? .orange : blue)
                Text(disk.description).font(.system(size: 10)).foregroundStyle(.secondary)
                if let detail = disk.detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DerivedData").font(.system(size: 14, weight: .semibold))
                    Text("8시간 이상 사용하지 않은 캐시").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if storage?.busy == true { ProgressView().controlSize(.small) }
                Button { storage?.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(storage?.busy == true).help("다시 조회").accessibilityLabel("DerivedData 다시 조회")
            }
            if storage?.busy == true { Text(storage?.cleaning == true ? "선택한 캐시 정리 중…" : "캐시 용량을 조회하고 있습니다…").font(.caption).foregroundStyle(.secondary) }
            if let error = storage?.lastError { Text(error).font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled) }
            if let report = storage?.report {
                HStack {
                    Text("후보 \(report.candidates.count)개 · \(bytes(UInt64(report.candidateBytes)))")
                    Spacer()
                    Button(selection.count == candidatePaths.count && !selection.isEmpty ? "선택 해제" : "모두 선택") {
                        selection = selection.count == candidatePaths.count ? [] : Set(candidatePaths)
                    }.buttonStyle(.plain).foregroundStyle(blue).disabled(storage?.busy == true || candidatePaths.isEmpty)
                }.font(.system(size: 11))
                if report.candidates.isEmpty { Text("지금 정리할 오래된 캐시가 없습니다.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(report.candidates, id: \.path) { entry in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { selection.contains(entry.path) }, set: { if $0 { selection.insert(entry.path) } else { selection.remove(entry.path) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.system(size: 11, weight: .medium))
                                Text(bytes(UInt64(entry.size))).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(storage?.busy == true).help(entry.path)
                        Spacer(minLength: 0)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain).help("Finder에서 보기").accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) Finder에서 보기")
                    }.padding(.vertical, 3)
                }
                Text("전체 캐시 \(report.items.count)개 · \(bytes(UInt64(report.totalBytes)))").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("최근 조회 \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: report.generatedAt), dateStyle: .short, timeStyle: .short))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private var storageActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("공용 캐시 포함", isOn: Binding(get: { storage?.includeShared == true }, set: { _ in selection = []; storage?.toggleShared() }))
                .font(.system(size: 11)).disabled(storage?.busy == true)
            Button { storage?.confirmClean(paths: Set(selectedEntries.map(\.path))) } label: {
                Text("선택한 \(selectedEntries.count)개 정리 · \(bytes(UInt64(selectedEntries.reduce(Int64(0)) { $0 + $1.size })))").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(selectedEntries.isEmpty || storage?.busy == true || storage?.lastError != nil)
            Text("정리하려면 Xcode와 xcodebuild를 종료하세요. 선택한 항목은 확인 후 영구 삭제됩니다.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin?(); model.refreshContext() }))
                .toggleStyle(.switch).controlSize(.small)
            if model.loginApproval { Button("시스템 설정에서 자동 실행 승인") { SMAppService.openSystemSettingsLoginItems() } }
            Divider()
            Button("스토리지 알림 설정…") { storage?.openNotificationSettings() }
            Button("DerivedData 폴더 열기") { storage?.openFolder() }
            Button("활성 상태 보기 열기") { openActivityMonitor() }
            Text("디스크는 1분마다, 캐시 용량은 1시간마다 확인합니다. 정리는 직접 실행할 때만 진행합니다.").font(.caption).foregroundStyle(.secondary)
            Text("화면 모양은 macOS의 밝은 모드·어두운 모드 및 손쉬운 사용 설정을 따릅니다.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("MiniStats 종료") { model.quit?() }.disabled(storage?.cleaning == true)
        }.font(.system(size: 12)).buttonStyle(.borderless)
    }
    private func processValue(_ process: RankedProcess, order: ProcessOrder) -> String {
        order == .cpu ? process.cpu.map { String(format: "%.1f%%", $0) } ?? "—" : bytes(process.memory)
    }
    private func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
}

final class SolidDashboardSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The glass owns a single hosting content view. Older systems use the system material.
final class DashboardSurfaceController: NSViewController {
    private let model: DashboardModel
    private var observer: NSObjectProtocol?
    init(model: DashboardModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        installSurface()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.installSurface() }
    }
    private func installSurface() {
        view.subviews.forEach { $0.removeFromSuperview() }
        let host = NSHostingView(rootView: DashboardView(model: model))
        let surface: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            surface = SolidDashboardSurface()
            surface.addSubview(host)
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = host
            surface = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(host)
            surface = effect
        }
        view.addSubview(surface)
        surface.frame = view.bounds
        surface.autoresizingMask = [.width, .height]
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

func dashboardSelfTest() {
    let old = ProcessSample(name: "old", start: 1, cpuTime: 1_000_000_000, memory: 10)
    let current = ProcessSample(name: "busy", start: 1, cpuTime: 5_000_000_000, memory: 20)
    let reused = ProcessSample(name: "reused", start: 2, cpuTime: 9_000_000_000, memory: 40)
    let reset = ProcessSample(name: "reset", start: 1, cpuTime: 0, memory: 30)
    let rows = rankedProcesses(before: [1: old, 2: old, 3: old], after: [1: current, 2: reused, 3: reset], seconds: 2)
    precondition(ProcessOrder.cpu.sorted(rows).map(\.pid) == [1])
    precondition(ProcessOrder.cpu.sorted(rows).first?.cpu == 200)
    precondition(ProcessOrder.memory.sorted(rows).map(\.pid) == [2, 3, 1])
    for seconds in [0, 0.5, -1, Double.infinity, Double.nan] {
        let initial = rankedProcesses(before: [1: old], after: [1: current], seconds: seconds)
        precondition(initial.count == 1 && initial[0].cpu == nil && initial[0].memory == 20)
    }
    let ties = rankedProcesses(before: [:], after: [8: current, 4: current], seconds: 0)
    precondition(ProcessOrder.memory.sorted(ties).map(\.pid) == [4, 8])
    precondition(rows.first(where: { $0.pid == 2 })?.id == "2:2")
    let background = DispatchQueue(label: "MiniStats.selftest").sync { processSamples() }
    precondition((background[getpid()]?.memory ?? 0) > 0, "Background libproc sampling failed")
    let model = DashboardModel(readProcesses: { [1: current] })
    model.begin()
    let deadline = Date(timeIntervalSinceNow: 5)
    while !model.sampled && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    precondition(model.sampled && model.processes.first?.memory == 20)
    model.end()
    precondition(model.processes.isEmpty)
    model.begin()
    model.end()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(model.processes.isEmpty, "Late process result resurrected closed dashboard")
    print("PASS: dashboard async delivery and close/reopen cancellation, live background sampling")
    print("PASS: dashboard process PID identity, reuse/reset rejection, first-sample memory, finite intervals, multicore CPU, deterministic ranking")
}

/// Content rendering for layout inspection; does not test window-server glass compositing or mouse interaction.
/// Reads live metrics and the cached storage report without login registration, notifications, scans or deletion.
@MainActor func renderDashboard(to directory: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = DashboardModel()
    model.storage = StorageController(changed: {}, openMenu: {}, startServices: false)
    let previousCPU = cpuTicks()
    let previousProcesses = processSamples()
    let previousNetwork = networkCounters()
    let before = ProcessInfo.processInfo.systemUptime
    Thread.sleep(forTimeInterval: 3)
    let currentCPU = cpuTicks()
    let now = ProcessInfo.processInfo.systemUptime
    model.update(cpu: previousCPU.flatMap { old in currentCPU.flatMap { cpuLoad(old, $0) } }, memory: memoryUsage(),
                 rates: previousNetwork.flatMap { old in networkCounters().flatMap { networkRate(old, $0, seconds: now - before) } })
    model.processes = rankedProcesses(before: previousProcesses, after: processSamples(), seconds: now - before)
    model.sampled = true
    model.refreshContext()
    for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        for (page, order, suffix) in [(DashboardPage.overview, ProcessOrder.cpu, "overview"), (.processes, .cpu, "cpu"), (.processes, .memory, "memory"), (.storage, .cpu, "storage"), (.settings, .cpu, "settings")] {
            model.page = page
            model.order = order
            let content = DashboardView(model: model, renderOnly: true).environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.97, green: 0.98, blue: 0.99))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let target = directory.appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: target)
            print("Rendered content: \(target.path)")
        }
    }
}
