import Foundation

struct CleanProgress {
    enum Phase { case confirming, running, done, failed, cancelled }
    enum ItemState { case pending, deleting, deleted, kept, failed }
    struct Item {
        let path: String
        let size: Int64
        var state: ItemState = .pending
    }
    var phase: Phase
    var items: [Item]
    var freedBytes: Int64
    var cancelled: Bool
    var currentPath: String?
    var summary: String?
    var error: String?
    var totalCount: Int { items.count }
    var resolvedCount: Int { items.filter { $0.state == .deleted || $0.state == .kept || $0.state == .failed }.count }
    var deletedCount: Int { items.filter { $0.state == .deleted }.count }
    var keptCount: Int { items.filter { $0.state == .kept }.count }
}
