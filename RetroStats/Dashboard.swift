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
    private let queue = DispatchQueue(label: "RetroStats.processes", qos: .utility)
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

extension Font {
    static func pixel(_ size: CGFloat) -> Font { .custom("NeoDunggeunmo", size: size) }
}

/// Column histogram rendered as 1-bit pixel bars; replaces the stroked line.
struct HistoryLine: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let h = max(2, min(100, value) / 100 * geometry.size.height)
                    Rectangle().fill(color).frame(height: h)
                }
            }
        }.frame(height: 34).accessibilityHidden(true)
    }
}

/// Segmented 1-bit usage meter; filled cells use the ink color, and warning cells use a dither pattern instead of an accent color.
struct UsageBar: View {
    let percent: Double
    let color: Color
    var warning = false
    private let cells = 24
    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 1) {
                ForEach(0..<cells, id: \.self) { i in
                    let on = Double(i) < percent / 100 * Double(cells)
                    if on && warning { DitherCell() }
                    else { RoundedRectangle(cornerRadius: 1, style: .continuous).fill(on ? color : color.opacity(0.08)) }
                }
            }
        }.frame(height: 10).accessibilityLabel("사용률").accessibilityValue(String(format: "%.0f%%", percent))
    }
}

/// 2x2 checkerboard cell so a "filled" warning segment stays black-and-white.
struct DitherCell: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width / 2, h = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.primary))
            ctx.fill(Path(CGRect(x: w, y: h, width: w, height: h)), with: .color(.primary))
        }
    }
}

/// Pixel-art gear drawn as 1x1 cells on a 16x16 grid, replacing the vector SF Symbol.
struct PixelGear: View {
    var size: CGFloat = 16
    var body: some View {
        Canvas { ctx, sz in
            let N = 16.0
            let scale = sz.width / N
            let cx = (N - 1) / 2, cy = (N - 1) / 2
            let Rout = 7.2, Rring = 4.6, Rhole = 1.9
            let teeth = 8, half = 16.0 * .pi / 180
            var path = Path()
            for j in 0..<Int(N) {
                for i in 0..<Int(N) {
                    let dx = Double(i) - cx, dy = Double(j) - cy
                    let r = (dx * dx + dy * dy).squareRoot()
                    let ang = atan2(dy, dx)
                    var onTooth = false
                    for k in 0..<teeth {
                        let a = Double(k) * 2 * .pi / Double(teeth)
                        let d = abs((ang - a + .pi).truncatingRemainder(dividingBy: 2 * .pi) - .pi)
                        if d < half { onTooth = true; break }
                    }
                    let filled = (r > Rhole && r <= Rout) && (r <= Rring || onTooth)
                    if filled { path.addRect(CGRect(x: Double(i) * scale, y: Double(j) * scale, width: scale, height: scale)) }
                }
            }
            ctx.fill(path, with: .color(.primary))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Fine pixel grid that mimics the subpixel matrix of an LCD panel.
struct LCDPixelGrid: View {
    var opacity: Double = 0.06
    var pitch: CGFloat = 3
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.white.opacity(opacity)
            var x = pitch
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(ink))
                x += pitch
            }
            var y = pitch
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(ink))
                y += pitch
            }
        }
    }
}

/// Horizontal scanlines that mimic the row gaps of an LCD panel.
struct LCDScanlines: View {
    var opacity: Double = 0.05
    var spacing: CGFloat = 3
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.white.opacity(opacity)
            var y = 0.0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(ink))
                y += spacing
            }
        }
    }
}

/// Diagonal glare suggesting the glass cover of a real LCD.
//struct LCDGlare: View {
//    var body: some View {
//        LinearGradient(
//            colors: [Color.white.opacity(0.07), .clear, Color.white.opacity(0.02)],
//            startPoint: .topLeading,
//            endPoint: .bottomTrailing
//        )
//    }
//}

/// Translucent liquid-glass substrate for the main popover background: a faint tint over the window glass, with a pixel grid, scanlines and glare so the whole surface reads as one LCD panel.
//struct LCDGlassBackground: View {
//    var body: some View {
//        ZStack {
////            Color.primary.opacity(0.04)
//            LCDPixelGrid(opacity: 0.03, pitch: 4)
//            LCDScanlines(opacity: 0.018, spacing: 4)
//            LCDGlare()
//        }
//        .allowsHitTesting(false)
//    }
//}

/// Translucent LCD sub-panel background for cards: a faint tint plus a pixel grid and a hairline border.
struct LCDPanelBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Double
    var grid: Double
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                Color.primary.opacity(tint)
                LCDPixelGrid(opacity: grid, pitch: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    /// Translucent LCD-style panel background for cards and surfaces.
    func lcdPanel(cornerRadius: CGFloat = 14, tint: Double = 0.05, grid: Double = 0.03) -> some View {
        modifier(LCDPanelBackground(cornerRadius: cornerRadius, tint: tint, grid: grid))
    }
}

/// Translucent LCD panel: a dark substrate that lets the window glass bleed through, with a pixel grid, scanlines and glare framing hero numerals.
struct LCDScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(10)
            .background(
                ZStack {
                    Color.black.opacity(0.55)
                    LCDPixelGrid(opacity: 0.07)
                    LCDScanlines(opacity: 0.05)
//                    LCDGlare()
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var renderOnly = false
    @State private var selection: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ink = Color.primary
    private var storage: StorageController? { model.storage }
    private var selectedEntries: [CacheEntry] { storage?.report?.candidates.filter { selection.contains($0.path) } ?? [] }
    private var candidatePaths: [String] { storage?.report?.candidates.map(\.path) ?? [] }
    private var title: String {
        switch model.page {
        case .overview: return "RetroStats"
        case .processes: return "프로세스"
        case .storage: return "스토리지 정리"
        case .settings: return "설정"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.page != .overview {
                    Button { model.page = .overview } label: { Image(systemName: "chevron.left").font(.pixel(16)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("대시보드로 돌아가기").accessibilityLabel("대시보드로 돌아가기")
                } else {
                    Image(systemName: "waveform.path").foregroundStyle(ink).font(.system(size: 19, weight: .semibold))
                }
                Text(title).font(.pixel(18))
                Spacer()
                if model.page == .overview {
                    Text("실시간").font(.pixel(12)).foregroundStyle(.secondary)
                    Circle().fill(ink).frame(width: 5, height: 5).accessibilityHidden(true)
                }
                Button { model.refreshContext(); model.page = .settings } label: { PixelGear(size: 18).foregroundStyle(ink).frame(width: 26, height: 26) }
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
                Text("\(ProcessInfo.processInfo.activeProcessorCount)코어 · \(bytes(totalMemory))").font(.pixel(11)).lineLimit(1)
                Spacer()
                Text("3초마다 갱신").font(.pixel(11))
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .font(.pixel(13))
        .frame(width: 400, height: 600)
//        .background(LCDGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: candidatePaths) { _, newPaths in
            selection.formIntersection(newPaths)
        }
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
                Button("활성 상태 보기") { openActivityMonitor() }.font(.pixel(11)).buttonStyle(.plain).foregroundStyle(ink)
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
            Button("활성 상태 보기 열기") { openActivityMonitor() }.controlSize(.small)
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
                if storage?.busy == true { ProgressView().controlSize(.small) }
                Button { storage?.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(storage?.busy == true).help("다시 조회").accessibilityLabel("DerivedData 다시 조회")
            }
            if let progress = storage?.cleanProgress {
                cleanProgressSection(progress)
            } else {
                if storage?.busy == true { Text(storage?.cleaning == true ? "선택한 캐시 정리 중…" : "캐시 용량을 조회하고 있습니다…").font(.pixel(11)).foregroundStyle(.secondary) }
                if let error = storage?.lastError { Text(error).font(.pixel(10)).foregroundStyle(.red).textSelection(.enabled) }
                if let report = storage?.report {
                    HStack {
                        Text("후보 \(report.candidates.count)개 · \(bytes(UInt64(report.candidateBytes)))")
                        Spacer()
                        Button(selection.count == candidatePaths.count && !selection.isEmpty ? "선택 해제" : "모두 선택") {
                            selection = selection.count == candidatePaths.count ? [] : Set(candidatePaths)
                        }.buttonStyle(.plain).foregroundStyle(ink).disabled(storage?.busy == true || candidatePaths.isEmpty)
                    }.font(.pixel(11))
                    if report.candidates.isEmpty { Text("지금 정리할 오래된 캐시가 없습니다.").font(.pixel(11)).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(report.candidates, id: \.path) { entry in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { selection.contains(entry.path) }, set: { if $0 { selection.insert(entry.path) } else { selection.remove(entry.path) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.pixel(11))
                                    Text(bytes(UInt64(entry.size))).font(.pixel(10)).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox).disabled(storage?.busy == true).help(entry.path)
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
                }.buttonStyle(.borderedProminent)
                Button { storage?.cancelClean() } label: {
                    Text("취소").frame(maxWidth: .infinity)
                }
                Text("정리 전 Xcode와 xcodebuild를 종료하세요. 선택한 항목은 확인 후 영구 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            } else if storage?.cleanProgress?.phase == .running {
                Button { storage?.cancelClean() } label: {
                    Text("정리 취소").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Text("정리 중에는 새 빌드를 시작하지 마세요. 취소하면 진행 중인 항목까지만 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            } else if let phase = storage?.cleanProgress?.phase, phase == .done || phase == .cancelled || phase == .failed {
                Button { storage?.dismissCleanProgress(); storage?.refresh() } label: {
                    Text("다시 조회").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            } else {
                Toggle("공용 캐시 포함", isOn: Binding(get: { storage?.includeShared == true }, set: { _ in selection = []; storage?.toggleShared() }))
                    .font(.pixel(11)).disabled(storage?.busy == true)
                Button { storage?.beginClean(paths: Set(selectedEntries.map(\.path))) } label: {
                    Text("선택한 \(selectedEntries.count)개 정리 · \(bytes(UInt64(selectedEntries.reduce(Int64(0)) { $0 + $1.size })))").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(selectedEntries.isEmpty || storage?.busy == true || storage?.lastError != nil)
                Text("정리하려면 Xcode와 xcodebuild를 종료하세요. 선택한 항목은 확인 후 영구 삭제됩니다.").font(.pixel(10)).foregroundStyle(.secondary)
            }
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
            Text("디스크는 1분마다, 캐시 용량은 1시간마다 확인합니다. 정리는 직접 실행할 때만 진행합니다.").font(.pixel(11)).foregroundStyle(.secondary)
            Text("화면 모양은 macOS의 밝은 모드·어두운 모드 및 손쉬운 사용 설정을 따릅니다.").font(.pixel(11)).foregroundStyle(.secondary)
            Divider()
            Button("RetroStats 종료") { model.quit?() }.disabled(storage?.cleaning == true)
        }.buttonStyle(.borderless)
    }
    private func processValue(_ process: RankedProcess, order: ProcessOrder) -> String {
        order == .cpu ? process.cpu.map { String(format: "%.1f%%", $0) } ?? "—" : bytes(process.memory)
    }
    private func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
}

final class SolidDashboardSurface: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: 20,
            yRadius: 20
        ).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The Liquid Glass surface owns a single hosting content view; reduced transparency uses a solid surface.
final class DashboardSurfaceController: NSViewController {
    private let model: DashboardModel
    private lazy var host = NSHostingView(rootView: DashboardView(model: model))
    private var observer: NSObjectProtocol?

    init(model: DashboardModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = 20
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        installSurface()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.installSurface()
        }
    }

    private func installSurface() {
        // Preserve the NSHostingView so SwiftUI local @State survives a runtime
        // Reduce Transparency toggle; only the AppKit surface is replaced.
        host.removeFromSuperview()
        view.subviews.forEach { $0.removeFromSuperview() }

        let surface: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = SolidDashboardSurface()
            solid.addSubview(host)
            surface = solid
        } else {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.clipsToBounds = true
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            glass.contentView = host
            surface = glass
        }

        view.addSubview(surface)
        surface.frame = view.bounds
        surface.autoresizingMask = [.width, .height]
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
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
    let background = DispatchQueue(label: "RetroStats.selftest").sync { processSamples() }
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
                .background(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(red: 0.11, green: 0.12, blue: 0.14), Color(red: 0.09, green: 0.10, blue: 0.12)]
                            : [Color(red: 0.96, green: 0.97, blue: 0.98), Color(red: 0.93, green: 0.94, blue: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
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
