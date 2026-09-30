import Foundation

enum UpdateInterval {
    static let key = "updateInterval"
    static let range = 0.1...3.0
    static let defaultValue = 3.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return (min(range.upperBound, max(range.lowerBound, value)) * 10).rounded() / 10
    }

    static func load(from defaults: UserDefaults) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return defaultValue }
        return normalized(number.doubleValue)
    }
}
