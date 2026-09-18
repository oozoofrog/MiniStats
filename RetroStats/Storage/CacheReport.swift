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
