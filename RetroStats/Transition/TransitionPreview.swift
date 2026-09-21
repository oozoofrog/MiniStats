#if DEBUG
import SwiftUI

/// Transition-only preview. Replaces the real dashboard with lightweight sample
/// pages so transitions can be inspected in Xcode previews without live metrics,
/// storage, or login-item side effects. Auto-cycles between two pages so the
/// animation repeats; the style/speed pickers let you compare each transition.
struct TransitionPreview: View {
    @State private var style: TransitionStyle
    @State private var speed: TransitionSpeed
    let autoCycle: Bool
    let panelSize: CGSize

    init(style: TransitionStyle = .flip, speed: TransitionSpeed = .normal, autoCycle: Bool = true,
         panelSize: CGSize = CGSize(width: 400, height: 600)) {
        _style = State(initialValue: style)
        _speed = State(initialValue: speed)
        self.autoCycle = autoCycle
        self.panelSize = panelSize
    }

    @State private var page: DashboardPage = .overview
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            TransitionContainer(
                transition: style.makeTransition(color: .primary, duration: speed.duration),
                currentPage: page
            ) { p in
                PreviewSamplePage(page: p)
            }
            .frame(width: panelSize.width, height: panelSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            TransitionPreviewControls(style: $style, speed: $speed, page: $page)
                .padding(.top, 12)
        }
        .padding(16)
        .background(Color(.windowBackgroundColor))
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
        .onAppear { startTimerIfNeeded() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: speed) { _, _ in startTimerIfNeeded() }
    }

    private func startTimerIfNeeded() {
        timer?.invalidate()
        timer = nil
        guard autoCycle else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(speed.duration + 0.6, 1.0), repeats: true) { _ in
            page = (page == .overview) ? .settings : .overview
        }
    }
}

private struct PreviewSamplePage: View {
    let page: DashboardPage

    private var isA: Bool { page == .overview }

    var body: some View {
        ZStack {
            (isA ? Color(red: 0.96, green: 0.97, blue: 0.98) : Color(red: 0.10, green: 0.12, blue: 0.16))
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text(isA ? "PAGE A" : "PAGE B")
                    .font(.bitmap(34))
                    .foregroundStyle(isA ? .black : .white)
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { col in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((isA ? Color.black : Color.white).opacity(0.12 + Double(row * 3 + col) * 0.05))
                                .frame(height: 44)
                        }
                    }
                }
                PixelSegmentedControl(title: "Sample mode", options: [(0, "One"), (1, "Two")],
                                      selection: .constant(0))
                Spacer()
                Text(isA ? "이전 화면" : "다음 화면")
                    .font(.bitmap(13))
                    .foregroundStyle(isA ? .black.opacity(0.6) : .white.opacity(0.7))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct TransitionPreviewControls: View {
    @Binding var style: TransitionStyle
    @Binding var speed: TransitionSpeed
    @Binding var page: DashboardPage

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("스타일").font(.bitmap(12))
                Spacer()
                Text(style.label).foregroundStyle(.secondary)
            }
            PixelSegmentedControl(title: "스타일",
                                  options: TransitionStyle.allCases.map { ($0, $0.label) },
                                  selection: $style)

            HStack {
                Text("속도").font(.bitmap(12))
                Spacer()
                Text(speed.label).foregroundStyle(.secondary)
            }
            PixelSegmentedControl(title: "속도",
                                  options: TransitionSpeed.allCases.map { ($0, $0.label) },
                                  selection: $speed)

            HStack(spacing: 10) {
                Button("A → B 전환") { page = (page == .overview) ? .settings : .overview }
                    .buttonStyle(.borderedProminent)
                Button("A로") { page = .overview }
                    .buttonStyle(.bordered)
                Button("B로") { page = .settings }
                    .buttonStyle(.bordered)
            }
            .font(.bitmap(12))
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Previews

#Preview("Flip · 보통") {
    TransitionPreview(style: .flip, speed: .normal)
}

#Preview("Flip · 느림") {
    TransitionPreview(style: .flip, speed: .slow)
}

#Preview("Flip · 310×430") {
    TransitionPreview(style: .flip, speed: .slow, panelSize: CGSize(width: 310, height: 430))
}

#Preview("Wave · 보통") {
    TransitionPreview(style: .wave, speed: .normal)
}

#Preview("Dissolve · 보통") {
    TransitionPreview(style: .fade, speed: .normal)
}
#endif
