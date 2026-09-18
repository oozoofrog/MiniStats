import AppKit
import ServiceManagement

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
    @Published var transitionStyle: TransitionStyle {
        didSet { UserDefaults.standard.set(transitionStyle.rawValue, forKey: Self.transitionStyleKey) }
    }
    @Published var transitionSpeed: TransitionSpeed {
        didSet { UserDefaults.standard.set(transitionSpeed.rawValue, forKey: Self.transitionSpeedKey) }
    }
    var storage: StorageController?
    var toggleLogin: (() -> Void)?
    var quit: (() -> Void)?
    private let readProcesses: () -> [pid_t: ProcessSample]
    init(readProcesses: @escaping () -> [pid_t: ProcessSample] = processSamples) {
        self.readProcesses = readProcesses
        self.transitionStyle = TransitionStyle(rawValue: UserDefaults.standard.string(forKey: Self.transitionStyleKey) ?? "") ?? .wave
        self.transitionSpeed = TransitionSpeed(rawValue: UserDefaults.standard.string(forKey: Self.transitionSpeedKey) ?? "") ?? .normal
    }
    private static let transitionStyleKey = "transitionStyle"
    private static let transitionSpeedKey = "transitionSpeed"
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
