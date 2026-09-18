#if DEBUG
import SwiftUI

/// Transition-only preview. Replaces the real dashboard with lightweight sample
/// pages so transitions can be inspected in Xcode previews without live metrics,
/// storage, or login-item side effects. Auto-cycles between two pages so the
/// animation repeats; the style/speed pickers let you compare each transition.
struct TransitionPreview: View {
    var style: TransitionStyle = .flip
    var speed: TransitionSpeed = .normal
    var autoCycle: Bool = true

    @State private var page: DashboardPage = .overview
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            TransitionContainer(
                transition: style.makeTransition(seed: 0, color: .primary, duration: speed.duration),
                currentPage: page
            ) { p in
                PreviewSamplePage(page: p)
            }
            .frame(width: 400, height: 600)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            TransitionPreviewControls(style: style, speed: speed, page: $page, autoCycle: autoCycle)
                .padding(.top, 12)
        }
        .padding(16)
        .background(Color(.windowBackgroundColor))
        .onAppear { startTimerIfNeeded() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: autoCycle) { _, _ in startTimerIfNeeded() }
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
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
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
                Spacer()
                Text(isA ? "이전 화면" : "다음 화면")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isA ? .black.opacity(0.6) : .white.opacity(0.7))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct TransitionPreviewControls: View {
    var style: TransitionStyle
    var speed: TransitionSpeed
    @Binding var page: DashboardPage
    var autoCycle: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("스타일").font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(style.label).foregroundStyle(.secondary)
            }
            Picker("스타일", selection: .constant(style)) {
                ForEach(TransitionStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(true)

            HStack {
                Text("속도").font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(speed.label).foregroundStyle(.secondary)
            }
            Picker("속도", selection: .constant(speed)) {
                ForEach(TransitionSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(true)

            HStack(spacing: 10) {
                Button("A → B 전환") { page = (page == .overview) ? .settings : .overview }
                    .buttonStyle(.borderedProminent)
                Button("A로") { page = .overview }
                    .buttonStyle(.bordered)
                Button("B로") { page = .settings }
                    .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
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

#Preview("Wave · 보통") {
    TransitionPreview(style: .wave, speed: .normal)
}

#Preview("Fade · 보통") {
    TransitionPreview(style: .fade, speed: .normal)
}
#endif
