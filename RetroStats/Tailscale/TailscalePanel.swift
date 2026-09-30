import AppKit
import SwiftUI

struct TailscaleManagementPanel: View {
    @ObservedObject var controller: TailscaleController
    var renderOnly = false
    @State private var advanced = false
    @State private var mobile = false
    @State private var confirmLogout = false
    @Environment(\.retroPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RetroSectionHeading(title: "TAILSCALE", detail: controller.snapshot.state.rawValue.uppercased())
            Text(controller.installation.map { "\($0.variant.rawValue) · \(controller.snapshot.version)" } ?? "Official client required")
            if let date = controller.refreshedAt { Text("Last read " + "\(Int(max(0, Date().timeIntervalSince(date))))s ago" + (controller.busy ? " · Updating" : "")) }
            if !controller.snapshot.account.isEmpty { Text(controller.snapshot.account + " · " + controller.snapshot.tailnet).textSelection(.enabled) }
            if let local = controller.snapshot.local { Text(local.address + (local.dns.isEmpty ? "" : " · " + local.dns)).textSelection(.enabled) }
            ForEach(controller.snapshot.health, id: \.self) { Text($0).foregroundStyle(palette.muted) }
            if !controller.message.isEmpty { Text(controller.message).textSelection(.enabled).accessibilityLabel("Tailscale result: " + controller.message) }
            ViewThatFits(in: .horizontal) {
                HStack { primaryActions }
                VStack(alignment: .leading) { primaryActions }
            }
            Text("TUNNEL ONLY  ↓ \(controller.traffic.inbound.map(speed) ?? "—")  ↑ \(controller.traffic.outbound.map(speed) ?? "—")")
            Text("Online is device presence. Service access and internet routing require separate checks.").foregroundStyle(palette.muted)
            ForEach(controller.snapshot.peers.sorted { controller.isFavorite($0) && !controller.isFavorite($1) }) { peer in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Button { controller.toggleFavorite(peer) } label: { Image(systemName: controller.isFavorite(peer) ? "star.fill" : "star") }.accessibilityLabel("Favorite " + peer.name)
                        Text(peer.name).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Menu("Actions") { peerActions(peer) }
                    }
                    Text("\(peer.os) · \(peer.online ? "Online" : "Offline") · \(peer.route)")
                    Text("\(peer.address) · Local ↔ peer: ↓\(bytes(peer.rx)) ↑\(bytes(peer.tx))").textSelection(.enabled)
                }.padding(.vertical, 7)
            }
        }
        .font(.bitmap(12))
        .buttonStyle(.pixel)
        .sheet(isPresented: $advanced) { TailscaleAdvancedView(controller: controller) }
        .sheet(isPresented: $mobile, onDismiss: { controller.mobile.end() }) { AdvancedMobileSetupView(controller: controller, session: controller.mobile) }
        .confirmationDialog("Log out this Mac? Connecting again will require authentication.", isPresented: $confirmLogout) { Button("Log out", role: .destructive) { controller.logout() } }
    }
    @ViewBuilder private var primaryActions: some View {
        if controller.installation == nil { Button("Install / setup") { mobile = true; controller.startMobile() } }
        else if controller.snapshot.state == .signedOut || controller.snapshot.state == .extensionApproval {
            Button("Open Tailscale") { openClient() }
        } else {
            Button(controller.snapshot.state == .connected ? "Disconnect" : "Connect") { controller.connection(controller.snapshot.state != .connected) }.disabled(controller.busy)
        }
        Button("Connect iPhone or iPad") { controller.startMobile(); mobile = true }
        if controller.busy { Button("Cancel") { controller.cancel() } }
        Button("Refresh") { Task { await controller.refresh() } }.disabled(controller.busy)
    }
    private func openClient() { if let path = controller.installation?.appPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) } }
    @ViewBuilder private func peerActions(_ peer: TailscalePeer) -> some View {
        Button("Copy IP") { copy(peer.address) }
        Button("Copy DNS name") { copy(peer.dns) }
        Button("Ping / path diagnostic") { controller.diagnose(peer) }.disabled(controller.busy)
        ForEach(controller.services) { service in
            Button("Open " + service.name) { if let url = service.url(host: peer.address) { NSWorkspace.shared.open(url) } }
        }
        Button("Send Taildrop file…") {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
            if panel.runModal() == .OK { controller.sendFiles(to: peer, files: panel.urls) }
        }.disabled(!controller.snapshot.canTaildrop(to: peer) || controller.busy)
    }
}

func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
func openSharingSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!) }

struct TailscaleAdvancedView: View {
    @ObservedObject var controller: TailscaleController
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var routes = ""
    @State private var target = "http://127.0.0.1:8080"
    @State private var sharePath = "/"
    @State private var sharePort = "443"
    @State private var publicly = false
    @State private var shareMode: TailscaleShareMode = .https
    @State private var serviceName = "Web"
    @State private var scheme = "http"
    @State private var servicePort = "8080"
    @State private var servicePath = ""
    @State private var confirm = false
    @State private var confirmLogout = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Tailscale management").font(.bitmap(18)); Spacer(); Button("Done") { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TailscaleManagementPanel(controller: controller)
                    preferences
                    diagnostics
                    sharing
                    serviceEditor
                    TailscaleAdminView(controller: controller)
                }.padding(12)
            }
            Text(controller.message).textSelection(.enabled)
        }.padding(20).frame(minWidth: 340, idealWidth: 680, minHeight: 500, idealHeight: 760)
        .font(.bitmap(12)).textRenderer(TailscaleFormTextRenderer())
        .confirmationDialog(publicly ? "Publish this service to the internet? Anyone with its URL may access it." : "Share this service with permitted tailnet devices?", isPresented: $confirm) {
            Button(publicly ? "Publish with Funnel" : "Share with Serve") { controller.share(target: target, port: Int(sharePort) ?? 0, path: sharePath, publicly: publicly, mode: shareMode) }
        }
        .confirmationDialog("Log out this Mac?", isPresented: $confirmLogout) { Button("Log out", role: .destructive) { controller.logout() } }
    }
    private var preferences: some View {
        GroupBox("Connection and preferences") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(["accept-dns", "shields-up", "accept-routes", "exit-node-allow-lan-access"], id: \.self) { name in
                    if let current = controller.preferences.bool(name) {
                        Toggle(name, isOn: Binding(get: { controller.preferences.bool(name) ?? current }, set: { controller.set(name, $0 ? "true" : "false") }))
                            .disabled(controller.busy || !controller.capabilities.flag("set", name))
                    } else { Text(name + ": unreadable (update Tailscale / use official client)") }
                }
                Picker("Exit Node", selection: Binding(get: { controller.preferences.string("exit-node") ?? "" }, set: { controller.set("exit-node", $0) })) {
                    Text("None").tag("")
                    ForEach(controller.snapshot.peers.filter(\.exitOption)) { Text($0.name).tag($0.address) }
                }.disabled(!controller.capabilities.exitClient || controller.busy || controller.preferences.string("exit-node") == nil)
                Text("Exit Node: " + (controller.preferences.string("exit-node") ?? "Unreadable"))
                Button("Load accounts") { controller.loadAccounts() }.disabled(controller.busy || !controller.capabilities.supports("switch"))
                ForEach(controller.accounts) { account in
                    Button("\(account.selected == true ? "✓ " : "")\(account.account ?? account.id) · \(account.tailnet ?? "")") { controller.switchAccount(account.id) }.disabled(controller.busy || account.selected == true)
                }
                Button("Log out…", role: .destructive) { confirmLogout = true }.disabled(controller.busy)
                Divider()
                Text("THIS MAC AS A ROUTER · Advertising requires administrator approval.")
                Text("Exit advertisement: " + (controller.preferences.bool("advertise-exit-node").map { $0 ? "On" : "Off" } ?? "Unreadable"))
                VStack(alignment: .leading, spacing: 8) {
                    Button("Advertise Exit Node") { controller.set("advertise-exit-node", "true") }
                    Button("Stop advertising Exit Node") { controller.set("advertise-exit-node", "false") }
                }.disabled(controller.busy || !controller.capabilities.flag("set", "advertise-exit-node"))
                Text("Advertised subnets: " + (controller.preferences.string("advertise-routes") ?? "Unreadable"))
                TextField("Subnet CIDRs, comma separated", text: $routes)
                Button("Replace advertised subnet list") { controller.set("advertise-routes", routes) }.disabled(controller.busy || !controller.capabilities.flag("set", "advertise-routes"))
                Text("An empty subnet list withdraws subnets. Exit advertisement is a separate setting. Approval status is available in the administrator routes view.")
                Text(controller.capabilities.sshServer ? "Tailscale SSH server available in this CLI distribution." : "GUI distributions do not provide a Tailscale SSH server. Enable macOS Remote Login for ordinary SSH.")
                if controller.capabilities.sshServer {
                    Button("Enable Tailscale SSH server") { controller.set("ssh", "true") }
                    Button("Disable Tailscale SSH server") { controller.set("ssh", "false") }
                }
                Button("Open macOS Sharing settings") { openSharingSettings() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var diagnostics: some View {
        GroupBox("Diagnostics and tunnel counters") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Run netcheck") { controller.diagnose() }.disabled(controller.busy)
                Text(controller.diagnosticResult.isEmpty ? "Ping and netcheck run only on request." : controller.diagnosticResult).textSelection(.enabled)
                ForEach(controller.traffic.rates.keys.sorted(), id: \.self) { key in Text(key + " " + speed(controller.traffic.rates[key] ?? 0)) }
                Text("Missing or reset counters clear the baseline. Physical interface totals remain separate.")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var sharing: some View {
        GroupBox("Taildrop / Serve / Funnel") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Receive Taildrop files…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { controller.receiveFiles(at: url) }
                }.disabled(controller.busy || !controller.capabilities.supports("file"))
                Text("Taildrop: same owner, no tags. CLI-only file support may be incomplete; use the official client when unavailable.")
                Button("Read sharing configuration") { controller.loadShares() }.disabled(controller.busy || !controller.capabilities.supports("serve"))
                ForEach(controller.shares) { share in
                    VStack(alignment: .leading) {
                        Text("\(share.publicAccess ? "PUBLIC INTERNET" : "TAILNET POLICY") · \(share.mode.rawValue)://\(share.host):\(share.port)\(share.path) → \(share.target)").textSelection(.enabled)
                        Button("Remove this share", role: .destructive) { controller.removeShare(share) }.disabled(controller.busy)
                    }
                }
                if !controller.sharingJSON.isEmpty { DisclosureGroup("Full configuration (including unrecognized entries)") { Text(controller.sharingJSON).textSelection(.enabled) } }
                Picker("Sharing protocol", selection: $shareMode) { ForEach(TailscaleShareMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Local HTTP URL / TCP host:port", text: $target)
                HStack { TextField("HTTPS port", text: $sharePort); TextField("Path", text: $sharePath) }
                Toggle("Public internet (Funnel)", isOn: $publicly)
                Text(controller.capabilities.reason(publicly ? "funnel" : "serve"))
                Text("GUI variants: local HTTP port targets only. Funnel support is decided by the installed command and read-back, plus HTTPS / tailnet policy. Existing entries are preserved.")
                Button(publicly ? "Publish…" : "Share…") { confirm = true }.disabled(controller.busy || !controller.capabilities.supports(publicly ? "funnel" : "serve"))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var serviceEditor: some View {
        GroupBox("Device service shortcuts") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(controller.services) { service in
                    HStack {
                        Text("\(service.name) · \(service.scheme) · \(service.port)\(service.path)")
                        Spacer(); Button("Remove") { controller.services.removeAll { $0.id == service.id } }
                    }
                }
                TextField("Name", text: $serviceName)
                Picker("Service", selection: $scheme) { ForEach(["ssh", "smb", "http", "https", "vnc"], id: \.self) { Text($0).tag($0) } }
                HStack { TextField("Port", text: $servicePort); TextField("Path / shared folder", text: $servicePath) }
                Button("Add shortcut") {
                    guard let port = Int(servicePort), (1...65535).contains(port), !serviceName.isEmpty else { return }
                    controller.services.append(.init(name: serviceName, scheme: scheme, port: port, path: servicePath))
                }
                Text("Opening a shortcut does not confirm service availability or authentication.")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

/// Native form controls retain their native layout; bitmap font shapes need no layer shader.
struct TailscaleFormTextRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) { for line in layout { context.draw(line) } }
}
