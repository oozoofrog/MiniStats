import SwiftUI

enum LCDResponse {
    static let duration: TimeInterval = 0.42
    static let strength = 0.16

    static func opacity(after elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite else { return 0 }
        let remaining = 1 - min(1, max(0, elapsed / duration))
        return strength * remaining * remaining
    }
}

/// Keeps only the immediately preceding reading. The live reading stays sharp;
/// its fading predecessor never affects layout, hit testing or accessibility.
struct LCDPersistence<Value: Equatable, Content: View>: View {
    let value: Value
    @ViewBuilder var content: (Value) -> Content
    @State private var previous: Value?
    @State private var changedAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(value)
            .overlay(alignment: .topLeading) {
                if let previous, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        content(previous)
                            .opacity(LCDResponse.opacity(after: context.date.timeIntervalSince(changedAt)))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: value) { oldValue, _ in
                guard !reduceMotion else { previous = nil; return }
                previous = oldValue
                changedAt = .now
            }
            .task(id: changedAt) {
                guard previous != nil else { return }
                let startedAt = changedAt
                do { try await Task.sleep(for: .seconds(LCDResponse.duration)) }
                catch { return }
                guard !Task.isCancelled, changedAt == startedAt else { return }
                previous = nil
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { previous = nil }
            }
            .onDisappear { previous = nil }
    }
}

struct LCDValue: View {
    let text: String

    var body: some View {
        LCDPersistence(value: text) { Text($0).fixedSize() }
    }
}
