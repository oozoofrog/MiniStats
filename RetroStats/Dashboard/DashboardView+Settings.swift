import ServiceManagement
import SwiftUI

extension DashboardContentView {
    var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("MONITORING") {
                HStack {
                    Text("Update interval")
                    Spacer()
                    Text("\(model.updateIntervalLabel) s")
                }.font(.bitmap(12))
                Slider(value: Binding(get: { model.updateInterval }, set: { model.setUpdateInterval($0) }),
                       in: UpdateInterval.range, step: 0.1)
                    .accessibilityLabel("Update interval")
                    .accessibilityValue("\(model.updateIntervalLabel) seconds")
                HStack {
                    Text("0.1 s")
                    Spacer()
                    Text("3.0 s")
                }.font(.bitmap(11)).foregroundStyle(palette.muted)
                Text("CPU, memory, network and process sampling.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            let actions = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            actions {
                Button("Open Activity Monitor") { openActivityMonitor() }.buttonStyle(.pixelGhost)
                if !compact { Spacer(minLength: 8) }
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
