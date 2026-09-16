import SwiftUI

/// Manages page transition state and rendering. Encapsulates the progress
/// animation, previous-page tracking, and seed-based randomization so
/// `DashboardView` only calls `transitionTo(_:)` and provides page content.
struct TransitionContainer<Transition: PageTransition, Content: View>: View {
    let transition: Transition
    let currentPage: DashboardPage
    @ViewBuilder let content: (DashboardPage) -> Content

    @State private var progress: Double = 0
    @State private var transitionStart: Date?
    @State private var seed: Int = 0
    @State private var previousPage: DashboardPage?
    @State private var gen = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isTransitioning: Bool { previousPage != nil && !reduceMotion }

    var body: some View {
        ZStack(alignment: .top) {
            content(currentPage)
                .opacity(isTransitioning ? 0 : 1)
            if isTransitioning {
                content(previousPage!)
                    .mask {
                        transition.oldPageMask(progress: progress)
                    }
                content(currentPage)
                    .mask {
                        transition.newPageMask(progress: progress)
                    }
                transition.overlay(progress: progress, start: transitionStart)
            }
        }
        .onChange(of: currentPage) { old, new in
            guard !reduceMotion, old != new, previousPage == nil else { return }
            startTransition(from: old, to: new)
        }
    }

    func transitionTo(_ page: DashboardPage) {
        guard !reduceMotion, currentPage != page else { return }
        startTransition(from: currentPage, to: page)
    }

    private func startTransition(from old: DashboardPage, to new: DashboardPage) {
        gen += 1
        let myGen = gen
        previousPage = old
        seed = Int.random(in: 1...1_000_000)
        transitionStart = .now
        progress = 0
        withAnimation(.linear(duration: 0.5)) {
            progress = 1
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run {
                guard myGen == gen else { return }
                transitionStart = nil
                previousPage = nil
                progress = 0
            }
        }
    }
}
