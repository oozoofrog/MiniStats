import Foundation

struct CacheEntry: Codable {
    let path: String
    let size: Int64
    let workspace: String
    let candidate: Bool
}
