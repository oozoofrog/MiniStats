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

func topCPU(_ before: [pid_t: ProcessSample], _ after: [pid_t: ProcessSample], seconds: Double) -> [(name: String, percent: Double)] {
    guard seconds > 0 else { return [] }
    return after.compactMap { pid, current -> (name: String, percent: Double)? in
        guard let old = before[pid], old.start == current.start, current.cpuTime >= old.cpuTime else { return nil }
        return (current.name, 100 * Double(current.cpuTime - old.cpuTime) / 1e9 / seconds)
    }.sorted { $0.percent > $1.percent }.prefix(5).map { $0 }
}

func topMemory(_ samples: [pid_t: ProcessSample]) -> [(name: String, memory: UInt64)] {
    samples.values.sorted { $0.memory > $1.memory }.prefix(5).map { ($0.name, $0.memory) }
}
