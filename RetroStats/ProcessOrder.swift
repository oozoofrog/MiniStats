import Foundation

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
