import Foundation

func dashboardSelfTest() {
    precondition(LCDResponse.opacity(after: 0) == LCDResponse.strength)
    precondition(LCDResponse.opacity(after: 0.1) > LCDResponse.opacity(after: 0.3))
    precondition(LCDResponse.opacity(after: LCDResponse.duration) == 0)
    precondition(LCDResponse.opacity(after: 3) == 0)
    precondition(LCDResponse.opacity(after: .infinity) == 0 && LCDResponse.opacity(after: .nan) == 0)
    print("PASS: LCD afterimage decay strength, monotonic fade and finite lifetime")
    let old = ProcessSample(name: "old", start: 1, cpuTime: 1_000_000_000, memory: 10)
    let current = ProcessSample(name: "busy", start: 1, cpuTime: 5_000_000_000, memory: 20)
    let reused = ProcessSample(name: "reused", start: 2, cpuTime: 9_000_000_000, memory: 40)
    let reset = ProcessSample(name: "reset", start: 1, cpuTime: 0, memory: 30)
    let rows = rankedProcesses(before: [1: old, 2: old, 3: old], after: [1: current, 2: reused, 3: reset], seconds: 2)
    precondition(ProcessOrder.cpu.sorted(rows).map(\.pid) == [1])
    precondition(ProcessOrder.cpu.sorted(rows).first?.cpu == 200)
    precondition(ProcessOrder.memory.sorted(rows).map(\.pid) == [2, 3, 1])
    for seconds in [0, -1, Double.infinity, Double.nan] {
        let initial = rankedProcesses(before: [1: old], after: [1: current], seconds: seconds)
        precondition(initial.count == 1 && initial[0].cpu == nil && initial[0].memory == 20)
    }
    for seconds in [0.1, 0.5, 1, 3] {
        let sampled = rankedProcesses(before: [1: old], after: [1: current], seconds: seconds)
        precondition(abs((sampled[0].cpu ?? -1) - 400 / seconds) < 0.0001, "Subsecond CPU interval was lost")
    }
    let suite = "RetroStats.updateInterval.selftest.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let network = MainActor.assumeIsolated { TailscaleController.preview() }
    let configured = DashboardModel(readProcesses: { [:] }, defaults: preferences, tailscale: network)
    precondition(configured.updateInterval == 3)
    var changes: [Double] = []
    configured.updateIntervalChanged = { changes.append($0) }
    configured.setUpdateInterval(0.1)
    configured.setUpdateInterval(0.1)
    precondition(changes == [0.1], "Identical settings restarted the timer")
    precondition(DashboardModel(defaults: preferences, tailscale: network).updateInterval == 0.1, "Interval did not persist")
    configured.setUpdateInterval(1.26)
    precondition(configured.updateInterval == 1.3)
    configured.setUpdateInterval(5)
    precondition(configured.updateInterval == 3)
    configured.setUpdateInterval(-1)
    precondition(configured.updateInterval == 0.1)
    configured.setUpdateInterval(.nan)
    precondition(configured.updateInterval == 3 && changes.last == 3)
    preferences.set("invalid", forKey: UpdateInterval.key)
    precondition(DashboardModel(defaults: preferences, tailscale: network).updateInterval == 3)
    print("PASS: 0.1–3.0s interval persistence, step/range validation, change delivery and subsecond process CPU")
    let ties = rankedProcesses(before: [:], after: [8: current, 4: current], seconds: 0)
    precondition(ProcessOrder.memory.sorted(ties).map(\.pid) == [4, 8])
    precondition(rows.first(where: { $0.pid == 2 })?.id == "2:2")
    let background = DispatchQueue(label: "RetroStats.selftest").sync { processSamples() }
    precondition((background[getpid()]?.memory ?? 0) > 0, "Background libproc sampling failed")
    let model = DashboardModel(readProcesses: { [1: current] }, defaults: preferences, tailscale: network)
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
    model.setPresented(true)
    let presentationDeadline = Date(timeIntervalSinceNow: 5)
    while !model.sampled && Date() < presentationDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    precondition(model.sampled && model.processes.first?.memory == 20)
    model.page = .network
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    MainActor.assumeIsolated {
        precondition(model.tailscale === network && network.isFixture && network.access.enabled)
        precondition(network.refreshedAt == nil && !network.mobile.active, "Dashboard fixture started real network work")
    }
    print("PASS: enabled My Mac dashboard lifecycle uses the injected inert network fixture")
    model.page = .storage
    model.setPresented(true)
    precondition(model.sampled && model.processes.first?.memory == 20, "Re-presenting the same surface reset sampling")
    precondition(model.page == .storage, "Re-presenting reset navigation")
    model.setPresented(false)
    precondition(model.processes.isEmpty && !model.sampled, "Closing the surface did not stop sampling")
    model.setPresented(false)
    model.resumeIfPresented()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(model.processes.isEmpty && !model.sampled, "Wake restarted a hidden dashboard")
    print("PASS: single-surface presentation, navigation preservation, close and hidden-wake handling")
    print("PASS: dashboard async delivery and close/reopen cancellation, live background sampling")
    print("PASS: dashboard process PID identity, reuse/reset rejection, first-sample memory, finite intervals, multicore CPU, deterministic ranking")
}
