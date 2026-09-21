import Foundation

struct ProcessSample {
    let name: String
    let start: UInt64
    let cpuTime: UInt64 // nanoseconds
    let memory: UInt64 // phys_footprint, Activity Monitor's "Memory" column
}

func processSamples() -> [pid_t: ProcessSample] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let listError = errno
    var usageErrors: [Int32: Int] = [:]
    var nameErrors: [Int32: Int] = [:]
    var name = [CChar](repeating: 0, count: 64)
    var result: [pid_t: ProcessSample] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
        var info = rusage_info_v4()
        // Processes of other users (root daemons, WindowServer, kernel_task) return EPERM and are left out.
        // libproc declares the buffer as `rusage_info_t *` (void **) even though it expects the struct itself.
        let usageResult = withUnsafeMutablePointer(to: &info, { proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) })
        guard usageResult == 0 else { usageErrors[errno, default: 0] += 1; continue }
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { nameErrors[errno, default: 0] += 1; continue }
        result[pid] = ProcessSample(name: String(cString: name), start: info.ri_proc_start_abstime,
                                    cpuTime: UInt64(Double(info.ri_user_time + info.ri_system_time) * machTimebase), memory: info.ri_phys_footprint)
    }
    diagnostic("Processes: uid=\(getuid()) listed=\(count) listErr=\(listError) readable=\(result.count) rusageErrors=\(usageErrors) nameErrors=\(nameErrors)")
    return result
}

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
    case cpu = "CPU", memory = "Memory"
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
