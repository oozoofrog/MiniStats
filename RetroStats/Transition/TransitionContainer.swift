import SwiftUI

/// Page routing is independent of the animation clock so rapid requests cannot
/// replace the page currently being revealed.
struct TransitionPages {
    private(set) var visible: DashboardPage
    private(set) var previous: DashboardPage?
    private(set) var requested: DashboardPage

    init(initial: DashboardPage) {
        visible = initial
        requested = initial
    }

    mutating func request(_ page: DashboardPage) -> Bool {
        requested = page
        return beginPending()
    }

    mutating func finish() { previous = nil }

    mutating func beginPending() -> Bool {
        guard previous == nil, visible != requested else { return false }
        previous = visible
        visible = requested
        return true
    }
}

/// Keeps the incoming page fixed until its transition finishes. Page changes
/// received during an animation are played afterward, with the latest winning.
struct TransitionContainer<Content: View>: View {
    let transition: any PageTransition
    let currentPage: DashboardPage
    @ViewBuilder let content: (DashboardPage) -> Content

    @State private var progress: Double = 0
    @State private var transitionStart: Date?
    @State private var activeTransition: (any PageTransition)?
    @State private var pages: TransitionPages?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTransitioning: Bool { pages?.previous != nil && !reduceMotion }
    private var visiblePage: DashboardPage { pages?.visible ?? currentPage }

    var body: some View {
        let effect = activeTransition ?? transition
        ZStack(alignment: .top) {
            content(visiblePage)
                .opacity(isTransitioning ? 0 : 1)
                .allowsHitTesting(!isTransitioning)
                .accessibilityHidden(isTransitioning)
            if isTransitioning, let previousPage = pages?.previous {
                content(previousPage)
                    .mask { effect.oldPageMask(progress: progress) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                content(visiblePage)
                    .mask { effect.newPageMask(progress: progress) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                effect.overlay(progress: progress, start: transitionStart)
            }
        }
        .onChange(of: currentPage) { old, new in
            guard !reduceMotion else {
                resetTransition()
                return
            }
            if pages == nil { pages = TransitionPages(initial: old) }
            if pages!.request(new) { startTransition() }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { resetTransition() }
        }
    }

    private func startTransition() {
        var effect = transition
        effect.seed = Int.random(in: 1...1_000_000)
        activeTransition = effect
        transitionStart = .now
        progress = 0
        withAnimation(.linear(duration: effect.duration), completionCriteria: .removed) {
            progress = 1
        } completion: {
            guard transitionStart != nil else { return }
            transitionStart = nil
            pages?.finish()
            activeTransition = nil
            progress = 0
            // Give the completed page a render pass before animating the
            // next request from progress zero.
            Task { @MainActor in
                await Task.yield()
                guard !reduceMotion else { return }
                if pages?.beginPending() == true { startTransition() }
            }
        }
    }

    private func resetTransition() {
        transitionStart = nil
        pages = TransitionPages(initial: currentPage)
        activeTransition = nil
        progress = 0
    }
}
