import AppKit
import SwiftUI

struct TailscalePanel: View {
    @ObservedObject var controller: TailscaleController
    @ObservedObject private var access: MacAccessCoordinator
    var renderOnly = false
    @State private var helper = false
    @State private var management = false
    @Environment(\.retroPalette) private var palette
    init(controller: TailscaleController, renderOnly: Bool = false) { self.controller = controller; self.access = controller.access; self.renderOnly = renderOnly }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RetroSectionHeading(title: "MY MAC", detail: access.phase.rawValue.uppercased())
            MacAccessDotArt(scene: access.mobileName.isEmpty ? .macGuide : .ready).frame(height: 86).accessibilityHidden(true)
            Text(access.phase == .ready ? "Your Mac is ready. Open it on your phone or iPad." : "Reach your Mac from your phone or iPad.").fixedSize(horizontal: false, vertical: true)
            if !access.mobileName.isEmpty { Text("Connected: " + access.mobileName).fixedSize(horizontal: false, vertical: true) }
            Button(access.enabled ? "Continue setup" : "Start access") { controller.beginAccess(); controller.startMobile(); helper = true }.disabled(controller.busy)
            Button("Advanced management") { management = true }
            Text("TUNNEL  ↓ \(controller.traffic.inbound.map(speed) ?? "—")  ↑ \(controller.traffic.outbound.map(speed) ?? "—")").foregroundStyle(palette.muted)
        }.font(.bitmap(12)).buttonStyle(.pixel)
        .sheet(isPresented: $helper, onDismiss: { controller.mobile.end() }) { MobileSetupView(controller: controller, session: controller.mobile) }
        .sheet(isPresented: $management) { TailscaleAdvancedView(controller: controller) }
    }
}

struct MobileSetupView: View {
    @ObservedObject var controller: TailscaleController
    @ObservedObject var session: MobileSetupSession
    @ObservedObject private var access: MacAccessCoordinator
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: TailscaleService?
    @State private var advanced = false
    init(controller: TailscaleController, session: MobileSetupSession, onClose: (() -> Void)? = nil) { self.controller = controller; self.session = session; self.access = controller.access; self.onClose = onClose }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("My Mac").font(.bitmap(22)); Spacer(); Button("Done") { session.end(); if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MacAccessDotArt(scene: access.mobileName.isEmpty ? .macGuide : .ready).frame(height: 150).accessibilityHidden(true)
                    Text(statusTitle).font(.bitmap(14))
                    Text(statusDetail).fixedSize(horizontal: false, vertical: true)
                    if access.phase == .incomingBlocked { Button("Allow Mac access") { controller.allowAccessIncoming() }.disabled(controller.busy) }
                    if controller.busy { ProgressView().accessibilityLabel("Preparing Mac access") }
                    if access.phase == .install { Button("Install connection app") { controller.installAccessClient() }.disabled(controller.busy) }
                    else if [.login, .approval, .deviceApproval, .unavailable, .paused].contains(access.phase) { Button("Continue") { controller.beginAccess() }.disabled(controller.busy) }
                    if access.phase == .approval { Button("Allow in System Settings") { if !controller.isFixture { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!) } } }
                    if access.phase == .ready {
                        if access.mobileName.isEmpty {
                            Text("Sign-in account").font(.bitmap(11))
                            if !controller.snapshot.account.isEmpty { Text(controller.snapshot.account).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            if let guide = session.lanURL { linkQR(guide, title: "Mobile Guide") }
                            else if let url = access.url { linkQR(url, title: "Open My Mac") }
                            DisclosureGroup("Get the connection app") { linkQR(URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!, title: "Get Tailscale"); Text("Install, sign in, then allow VPN on your device.").fixedSize(horizontal: false, vertical: true) }
                        } else if let url = access.url { linkQR(url, title: "Save My Mac") }
                        Text("Keep My Mac on your Home Screen for next time.").fixedSize(horizontal: false, vertical: true)
                        if session.pathVerified { Text("Phone path confirmed.") }
                        if session.identificationNeeded || access.identificationNeeded {
                            Text("Your browser reached this Mac, but its device identity is unavailable.").fixedSize(horizontal: false, vertical: true)
                            Picker("Your device", selection: Binding(get: { session.selectedID ?? "" }, set: { session.selectMobile($0); access.selectMobile($0) })) {
                                Text("Choose your device").tag("")
                                ForEach(session.candidates.filter { controller.snapshot.canTaildrop(to: $0) }) { Text($0.name).tag($0.id) }
                            }
                            Text("An administrator may need to make your device visible. No device is approved automatically.").font(.bitmap(11)).fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup("Prepare a Mac service") {
                        ForEach(access.services) { result in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(result.service.name).font(.bitmap(14))
                                Text(result.reachable ? "Ready for your app. Sign in there." : result.localOnly ? "Available on this Mac. Share this web app to use it remotely." : "Choose this to prepare access on your Mac.").fixedSize(horizontal: false, vertical: true)
                                if !result.reachable {
                                    if result.localOnly { Button("Share this web app") { proxy = result.service }.disabled(controller.busy) }
                                    else if ["smb", "ssh", "vnc"].contains(result.service.scheme) { Button("Set up " + result.service.name) { access.selectPurpose(result.service.scheme) } }
                                    else { Text("Start your web app, then add it in Advanced management.").font(.bitmap(11)).fixedSize(horizontal: false, vertical: true) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                        }
                        Text("Keep your Mac awake and RetroStats running. Files uses Files; screen and terminal need a compatible app.").font(.bitmap(11)).fixedSize(horizontal: false, vertical: true)
                        Link("Automatic reconnect on iPhone / iPad", destination: URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!)
                    }
                    if !access.message.isEmpty { Text(access.message).fixedSize(horizontal: false, vertical: true) }
                    if !controller.message.isEmpty { Text(controller.message).font(.bitmap(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if access.enabled {
                        DisclosureGroup("Access link controls") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Reissuing invalidates the old link. Turning off removes this hub, without changing Mac services.").font(.bitmap(11)).fixedSize(horizontal: false, vertical: true)
                                Button("Reissue access link") { controller.reissueAccess() }
                                Button("Turn off Mac access", role: .destructive) { access.disable(); session.end() }
                            }.padding(.vertical, 8)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            Button("Advanced") { advanced = true }
        }.padding(20).frame(minWidth: 340, idealWidth: 620, minHeight: 500, idealHeight: 760)
        .buttonStyle(.pixel)
        .font(.bitmap(14)).textRenderer(TailscaleFormTextRenderer())
        .sheet(isPresented: $advanced) { TailscaleAdvancedView(controller: controller) }
        .confirmationDialog("Share only this web app with permitted devices?", isPresented: Binding(get: { proxy != nil }, set: { if !$0 { proxy = nil } })) {
            if let service = proxy { Button("Share this web app") { controller.proxyAccessWeb(service); proxy = nil } }
        }
    }
    private var statusTitle: String { !access.mobileName.isEmpty ? "Device connection checked" : access.phase == .ready ? "Set Up a Device" : access.phase.rawValue }
    private var statusDetail: String {
        switch access.phase {
        case .off: return "Start access once to prepare your Mac."
        case .install: return "Approve the verified installer when it opens."
        case .login: return "Sign in in the connection app. We continue automatically."
        case .approval: return "Allow the connection app in the macOS prompt."
        case .deviceApproval: return "Your administrator needs to approve this Mac."
        case .ready: return access.mobileName.isEmpty ? "Continue on your iPhone or iPad." : access.mobileName + " can reach My Mac."
        case .incomingBlocked: return "Allow this Mac to receive your device connection."
        case .paused: return "Continue to reconnect your Mac."
        case .accountChanged: return "Reissue the link to use this account."
        case .conflict: return "Check the saved link or reissue it below."
        default: return "We retry automatically. Keep the connection app open."
        }
    }
    private func linkQR(_ url: URL, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.bitmap(14))
            if let image = MobileSetupSession.qr(url) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 144, height: 144).padding(12).background(.white).accessibilityLabel(title + " QR") }
            Button("Copy link") { copy(url.absoluteString) }
            DisclosureGroup("Link address") { Text(url.absoluteString).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
