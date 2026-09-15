import Foundation

func bytes(_ value: UInt64) -> String {
    value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

func speed(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    if value >= 1_048_576 { return String(format: "%.1f MiB/s", value / 1_048_576) }
    return String(format: "%.0f KiB/s", value / 1024)
}
