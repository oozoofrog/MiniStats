import Foundation

struct CacheEntry: Decodable {
    let path: String
    let size: Int64
    let workspace: String
    let candidate: Bool
}
