import Foundation

func cpuTicks() -> [UInt32]? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
}

struct CPULoad {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

func cpuLoad(_ before: [UInt32], _ after: [UInt32]) -> CPULoad? {
    guard before.count == 4, after.count == 4 else { return nil }
    let delta = zip(after, before).map { Double($0 &- $1) }
    let total = delta.reduce(0, +)
    guard total > 0 else { return nil }
    return CPULoad(user: 100 * (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total,
                   system: 100 * delta[Int(CPU_STATE_SYSTEM)] / total)
}

func loadAverageText() -> String {
    var load = [Double](repeating: 0, count: 3)
    guard getloadavg(&load, 3) == 3 else { return "Load average: read failed" }
    return String(format: "Load average: %.1f · %.1f · %.1f (1·5·15 min, %d cores)", load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount)
}
