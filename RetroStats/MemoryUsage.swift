import Foundation

struct MemoryUsage {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    var used: UInt64 { min(totalMemory, app + wired + compressed) }
    var percent: Double { 100 * Double(used) / Double(totalMemory) }
}

func memoryUsage() -> MemoryUsage? {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)
    let appPages = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
    return MemoryUsage(app: appPages * page, wired: UInt64(info.wire_count) * page, compressed: UInt64(info.compressor_page_count) * page)
}

func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let result = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
    guard result == 0, size == MemoryLayout<T>.size else { return nil }
    return value
}

func swapText() -> String {
    guard let swap = sysctlValue("vm.swapusage", xsw_usage()) else { return "스왑: 읽기 실패" }
    return swap.xsu_total == 0 ? "스왑: 사용 안 함" : "스왑: \(bytes(swap.xsu_used)) / \(bytes(swap.xsu_total))"
}

func memoryPressureText() -> String {
    switch sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) {
    case 1: return "메모리 압력: 정상"
    case 2: return "메모리 압력: 경고"
    case 4: return "메모리 압력: 위험"
    case let level?: return "메모리 압력: 알 수 없음 (\(level))"
    case nil: return "메모리 압력: 읽기 실패"
    }
}
