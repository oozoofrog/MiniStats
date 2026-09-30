import SwiftUI

struct TailscaleAdminView: View {
    @ObservedObject var controller: TailscaleController
    @State private var tailnet = ""
    @State private var credential = ""
    @State private var deviceID = ""
    @State private var dnsResource = "nameservers"
    @State private var dnsDraft = ""
    @State private var dnsBaseline = ""
    @State private var policyDraft = ""
    @State private var policyBaseline: TailscalePolicy?
    @State private var enabledRoutes = Set<String>()
    @State private var advertisedRoutes: [String] = []
    @State private var routeBaseline = Data()
    @State private var confirmation: String?
    private var confirming: Binding<Bool> { Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }) }
    var body: some View {
        GroupBox("Optional administrator API") {
            VStack(alignment: .leading, spacing: 12) {
                if controller.api == nil {
                    Text("Local features work without an API credential. Connect only the tailnet you administer; required API scopes depend on the operation.")
                    TextField("Tailnet name", text: $tailnet)
                    SecureField("API key (stored in Keychain)", text: $credential)
                    HStack {
                        Button("Connect") { let value = credential; credential = ""; controller.connectAPI(tailnet: tailnet, credential: value) }.disabled(credential.isEmpty || tailnet.isEmpty || controller.busy)
                        Button("Reconnect saved Keychain credential") { controller.restoreAPI() }.disabled(controller.busy)
                    }
                } else {
                    HStack {
                        Text("Connected: " + (controller.api?.tailnet ?? ""))
                        Button("Disconnect / remove credential") { controller.disconnectAPI() }.disabled(controller.busy)
                    }
                    Button("Reload devices") { controller.admin { api in controller.adminDevices = try await api.devices() } }.disabled(controller.busy)
                    Picker("Device", selection: $deviceID) {
                        Text("Select a device").tag("")
                        ForEach(controller.adminDevices) { device in Text("\(device.name) · \(device.authorized == true ? "Approved" : device.authorized == false ? "Needs approval" : "Approval unknown")").tag(device.id) }
                    }.onChange(of: deviceID) { _, _ in advertisedRoutes = []; enabledRoutes = []; routeBaseline = Data(); controller.routesJSON = "" }
                    if let device = controller.adminDevices.first(where: { $0.id == deviceID }) {
                        Text(device.addresses.joined(separator: " · ")).textSelection(.enabled)
                        Button("Approve selected device…") { confirmation = "device" }.disabled(controller.busy || device.authorized == true)
                        Button("Read route approval status") { loadRoutes() }.disabled(controller.busy)
                        Text(controller.routesJSON).textSelection(.enabled)
                        ForEach(advertisedRoutes, id: \.self) { route in
                            Toggle(route, isOn: Binding(get: { enabledRoutes.contains(route) }, set: { if $0 { enabledRoutes.insert(route) } else { enabledRoutes.remove(route) } }))
                        }
                        Button("Apply selected route approvals…") { confirmation = "routes" }.disabled(controller.busy || routeBaseline.isEmpty)
                    }
                    Divider()
                    Picker("Tailnet DNS resource", selection: $dnsResource) {
                        ForEach(["nameservers", "searchpaths", "preferences"], id: \.self) { Text($0).tag($0) }
                    }.onChange(of: dnsResource) { _, _ in dnsBaseline = ""; dnsDraft = "" }
                    Button("Read DNS") {
                        controller.admin { api in
                            let result = try await api.dns(dnsResource)
                            dnsDraft = String(decoding: result, as: UTF8.self); dnsBaseline = dnsDraft; controller.dnsJSON = dnsDraft
                        }
                    }.disabled(controller.busy)
                    TextEditor(text: $dnsDraft).frame(minHeight: 120).accessibilityLabel("Tailnet DNS JSON")
                    if !dnsBaseline.isEmpty, dnsDraft != dnsBaseline { DisclosureGroup("Compare DNS before applying") { Text("BEFORE\n" + dnsBaseline + "\nAFTER\n" + dnsDraft).textSelection(.enabled) } }
                    Button("Apply DNS change…") { confirmation = "dns" }.disabled(controller.busy || dnsBaseline.isEmpty || dnsBaseline == dnsDraft)
                    Divider()
                    Button("Read access policy") {
                        controller.admin { api in let result = try await api.policy(); controller.policy = result; policyBaseline = result; policyDraft = result.text }
                    }.disabled(controller.busy)
                    TextEditor(text: $policyDraft).frame(minHeight: 180).accessibilityLabel("Tailnet access policy")
                    if let baseline = policyBaseline, baseline.text != policyDraft {
                        DisclosureGroup("Compare access policy before saving") { Text("BEFORE\n" + baseline.text + "\nAFTER\n" + policyDraft).textSelection(.enabled) }
                    }
                    HStack {
                        Button("Validate on server") { controller.admin { api in try await api.validatePolicy(policyDraft) } }
                        Button("Validate and save policy…") { confirmation = "policy" }
                    }.disabled(controller.busy || policyBaseline == nil || policyDraft == policyBaseline?.text)
                    Text("Save uses the loaded ETag. A conflict reloads the server policy; review it before retrying.")
                    if let current = controller.policy, let baseline = policyBaseline, current.etag != baseline.etag {
                        Text("SERVER POLICY CHANGED")
                        Text(current.text).textSelection(.enabled)
                        Button("Use reloaded server version") { policyBaseline = current; policyDraft = current.text }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .confirmationDialog("Apply this \(confirmation ?? "") change to tailnet \(controller.api?.tailnet ?? "")? Review the selected device, routes, and before/after values.", isPresented: confirming) {
            Button("Apply") { apply(confirmation ?? ""); confirmation = nil }
        }
    }
    private func loadRoutes() {
        let id = deviceID
        controller.admin { api in
            let data = try await api.routes(id)
            guard deviceID == id else { return }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            advertisedRoutes = root["advertisedRoutes"] as? [String] ?? []
            enabledRoutes = Set(root["enabledRoutes"] as? [String] ?? [])
            routeBaseline = data; controller.routesJSON = String(decoding: data, as: UTF8.self)
        }
    }
    private func apply(_ kind: String) {
        switch kind {
        case "device": let id = deviceID; controller.admin { api in try await api.approveDevice(id); controller.adminDevices = try await api.devices(); guard controller.adminDevices.first(where: { $0.id == id })?.authorized == true else { throw TailscaleFailure.invalid("Device approval was not confirmed by read-back") } }
        case "routes":
            let id = deviceID, selected = Array(enabledRoutes).sorted(), baseline = routeBaseline
            controller.admin { api in
                let current = try await api.routes(id)
                guard try JSONSerialization.jsonObject(with: current) as? NSDictionary == JSONSerialization.jsonObject(with: baseline) as? NSDictionary else { throw TailscaleFailure.conflict }
                try await api.approveRoutes(id, enabled: selected)
                let after = try await api.routes(id)
                controller.routesJSON = String(decoding: after, as: UTF8.self)
                let object = try JSONSerialization.jsonObject(with: after) as? [String: Any]
                guard Set(object?["enabledRoutes"] as? [String] ?? []) == Set(selected) else { throw TailscaleFailure.invalid("Route approvals were not confirmed by read-back") }
            }
        case "dns":
            let resource = dnsResource, text = dnsDraft, baseline = dnsBaseline
            controller.admin { api in
                let current = String(decoding: try await api.dns(resource), as: UTF8.self)
                guard current == baseline else { dnsBaseline = current; controller.dnsJSON = current; throw TailscaleFailure.conflict }
                try await api.updateDNS(resource, body: Data(text.utf8))
                let currentAfter = String(decoding: try await api.dns(resource), as: UTF8.self)
                controller.dnsJSON = currentAfter; dnsBaseline = currentAfter; dnsDraft = currentAfter
            }
        case "policy": if let baseline = policyBaseline { controller.savePolicy(policyDraft, baseline: baseline) }
        default: break
        }
    }
}
