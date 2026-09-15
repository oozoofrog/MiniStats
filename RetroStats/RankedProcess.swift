import Foundation

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
