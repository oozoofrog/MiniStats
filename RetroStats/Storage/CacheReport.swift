import Foundation

struct CacheReport: Codable {
    let generatedAt: Double
    let hours: Int
    let totalBytes: Int64
    let candidateBytes: Int64
    let items: [CacheEntry]
    var candidates: [CacheEntry] { items.filter(\.candidate) }

    static func decode(_ data: Data) throws -> CacheReport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let report = try decoder.decode(CacheReport.self, from: data)
        guard report.hours == 8, report.generatedAt.isFinite,
              report.totalBytes >= 0, report.candidateBytes >= 0,
              report.items.allSatisfy({ $0.size >= 0 && $0.path.hasPrefix("/") }) else {
            throw NSError(domain: "RetroStats", code: 1, userInfo: [NSLocalizedDescriptionKey: "The DerivedData report is invalid."])
        }
        return report
    }

    static func encode(_ report: CacheReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }
}

struct CacheEntry: Codable {
    let path: String
    let size: Int64
    let workspace: String
    let candidate: Bool
}

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
    var freedBytes: Int64 = 0
    var currentPath: String?
    var error: String?
    var totalCount: Int { items.count }
    var resolvedCount: Int { items.filter { $0.state == .deleted || $0.state == .kept || $0.state == .failed }.count }
    var deletedCount: Int { items.filter { $0.state == .deleted }.count }
    var keptCount: Int { items.filter { $0.state == .kept }.count }
}
