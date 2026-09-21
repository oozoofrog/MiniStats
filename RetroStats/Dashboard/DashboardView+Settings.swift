import ServiceManagement
import SwiftUI

extension DashboardView {
    var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("APPEARANCE") {
                Text("Finish").font(.bitmap(12))
                PixelSegmentedControl(title: "Finish",
                                      options: RetroFinish.allCases.map { ($0, $0.label) },
                                      selection: $model.finish)
                Text("Text Size").font(.bitmap(12)).padding(.top, 4)
                PixelSegmentedControl(title: "Text Size",
                                      options: FontScale.allCases.map { ($0, $0.label) },
                                      selection: $model.fontScale)
            }
            settingsGroup("TRANSITIONS") {
                Text("Page Transition").font(.bitmap(12))
                PixelSegmentedControl(title: "Page Transition",
                                      options: TransitionStyle.allCases.map { ($0, $0.label) },
                                      selection: $model.transitionStyle)
                Text("Transition Speed").font(.bitmap(12)).padding(.top, 4)
                PixelSegmentedControl(title: "Transition Speed",
                                      options: TransitionSpeed.allCases.map { ($0, $0.label) },
                                      selection: $model.transitionSpeed)
            }
            settingsGroup("GENERAL") {
                Toggle("Launch at Login", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin?(); model.refreshContext() }))
                    .toggleStyle(.pixelToggle)
                if model.loginApproval {
                    Button("Approve in System Settings") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pixel)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { utilityButtons }
                    VStack(alignment: .leading, spacing: 10) { utilityButtons }
                }
            }
            Text("Disk is checked every minute; cache size every hour. Cleanup only runs when you start it.")
                .font(.bitmap(11)).foregroundStyle(palette.muted)
            Text("Follows macOS Light/Dark Mode. Pixel text and opaque panels stay enabled for every finish.")
                .font(.bitmap(11)).foregroundStyle(palette.muted)
            HStack {
                Button("Open Activity Monitor") { openActivityMonitor() }.buttonStyle(.pixelGhost)
                Spacer(minLength: 8)
                Button("Quit RetroStats") { model.quit?() }.buttonStyle(.pixel).disabled(storage?.cleaning == true)
            }.font(.bitmap(11))
        }
    }

    private var utilityButtons: some View {
        Group {
            Button("Storage Alerts…") { storage?.openNotificationSettings() }
            Button("DerivedData Folder") { storage?.openFolder() }
        }
        .font(.bitmap(11)).buttonStyle(.pixel)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RetroSectionHeading(title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))
    }
}
