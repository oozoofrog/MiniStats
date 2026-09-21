import SwiftUI

/// A quick readout; detailed actions open the persistent dashboard window.
struct MenuPopoverView: View {
    @ObservedObject var model: DashboardModel
    var renderOnly = false
    let openDashboard: (DashboardPage, ProcessOrder?) -> Void
    @Environment(\.colorScheme) private var scheme
    private var palette: RetroPalette { RetroPalette(finish: model.finish, scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            RetroTitleBar()
            if renderOnly {
                content.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { content }
            }
            HStack {
                Text("APPLE SILICON")
                Spacer(minLength: 0)
                Text("3 SEC / SAMPLE")
            }
            .font(.bitmap(9, scaled: false)).foregroundStyle(palette.muted)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(palette.base)
            .overlay(alignment: .top) { RetroRule() }
        }
        .font(.bitmap(11))
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
        .foregroundStyle(palette.ink)
        .background(palette.paper)
        .overlay(Rectangle().strokeBorder(palette.ink, lineWidth: 1))
        .environment(\.retroPalette, palette)
        .padding(.trailing, 4).padding(.bottom, 4)
        .background(alignment: .bottomTrailing) { palette.ink.padding(.top, 4).padding(.leading, 4) }
        .frame(width: RetroLayout.popoverSize.width, height: RetroLayout.popoverSize.height)
    }

    private var content: some View {
        VStack(spacing: 14) {
            RetroSectionHeading(title: "YOUR MAC, IN MINIATURE.")
            Button { openDashboard(.processes, .cpu) } label: {
                RetroProcessorPanel(model: model, compact: true)
            }.buttonStyle(.plain).accessibilityLabel("Open processor details")
            VStack(spacing: 0) {
                row("Memory", value: model.memory.map { "\(bytes($0.used)) / \(bytes(totalMemory))" } ?? "—", page: .processes, order: .memory)
                row("Download", value: model.download, page: .network)
                row("Disk free", value: model.storage?.disk.map { bytes($0.free) } ?? "—", page: .storage)
            }
            HStack(spacing: 10) {
                Button { openDashboard(.overview, nil) } label: {
                    Text("Open dashboard ↗").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Button { openDashboard(.settings, nil) } label: {
                    PixelSliders(size: 16, color: palette.ink)
                }.buttonStyle(.pixel).help("Settings").accessibilityLabel("Open settings")
            }
        }.padding(16)
    }

    private func row(_ title: String, value: String, page: DashboardPage, order: ProcessOrder? = nil) -> some View {
        Button { openDashboard(page, order) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer(minLength: 0)
                    Text(value).foregroundStyle(palette.muted)
                }
                .font(.bitmap(11)).padding(.vertical, 11)
                RetroRule()
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
