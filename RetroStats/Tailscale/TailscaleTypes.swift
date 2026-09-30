import Foundation

enum TailscaleFailure: Error, LocalizedError, Equatable {
    case unavailable(String), command(Int32), timeout, cancelled, outputLimit, busy, invalid(String)
    case api(Int), conflict, credential
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .invalid(let reason): return reason
        case .command(let code): return "Tailscale command failed (\(code)). Check health, permissions and the official client."
        case .timeout: return "The operation timed out. Check the official client and try again."
        case .cancelled: return "Operation cancelled. Read current status before retrying a change."
        case .outputLimit: return "Command output exceeded the safety limit."
        case .busy: return "Another operation is in progress."
        case .api(401): return "API credential expired or invalid. Reconnect the administrator API."
        case .api(403): return "API permission denied. Use a credential with the required scope."
        case .api(let status): return "Tailscale API returned HTTP \(status)."
        case .conflict: return "The policy changed on the server. Reload and review the changes again."
        case .credential: return "Keychain access failed. The credential was not saved."
        }
    }
}

enum TailscaleConnection: String { case notInstalled = "Not installed", signedOut = "Sign in required", extensionApproval = "Extension / VPN approval required", deviceApproval = "Device approval required", connecting = "Connecting", disconnected = "Disconnected", connected = "Connected", uncontrollable = "Control unavailable", error = "Error" }
enum TailscaleVariant: String { case standalone = "Standalone", appStore = "App Store", cli = "CLI only", unknown = "Unknown" }

struct TailscaleInstallation: Equatable {
    var executable: String
    var appPath: String?
    var variant: TailscaleVariant
    static func detect(fileManager: FileManager = .default, appPaths: [String]? = nil, cliPaths: [String] = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/opt/local/bin/tailscale"]) -> TailscaleInstallation? {
        let apps = appPaths ?? ["/Applications/Tailscale.app", fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tailscale.app").path]
        for app in apps {
            let binary = app + "/Contents/MacOS/Tailscale"
            guard fileManager.isExecutableFile(atPath: binary) else { continue }
            let store = fileManager.fileExists(atPath: app + "/Contents/_MASReceipt/receipt")
            return Self(executable: binary, appPath: app, variant: store ? .appStore : .standalone)
        }
        for binary in cliPaths where fileManager.isExecutableFile(atPath: binary) {
            let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
            if let contents = resolved.range(of: "/Contents/MacOS/"), resolved[..<contents.lowerBound].hasSuffix(".app") {
                let app = String(resolved[..<contents.lowerBound])
                return Self(executable: binary, appPath: app, variant: fileManager.fileExists(atPath: app + "/Contents/_MASReceipt/receipt") ? .appStore : .standalone)
            }
            return Self(executable: binary, appPath: nil, variant: .cli)
        }
        return nil
    }
}

struct TailscaleCapabilities {
    var help: [String: String] = [:]
    var variant: TailscaleVariant = .unknown
    func supports(_ command: String) -> Bool { help[command] != nil }
    func flag(_ command: String, _ flag: String) -> Bool {
        guard let text = help[command] else { return false }
        return text.range(of: "--" + NSRegularExpression.escapedPattern(for: flag) + "(?=[=\\s,]|$)", options: .regularExpression) != nil
    }
    var sshServer: Bool { variant == .cli && flag("set", "ssh") }
    var fileSharing: Bool { variant == .cli && supports("serve") }
    var exitClient: Bool { variant != .cli && flag("set", "exit-node") }
    func reason(_ command: String) -> String { supports(command) ? "Command available; execution and tailnet policy still determine support." : "This installed CLI does not expose \(command). Update Tailscale or use its official client / admin console." }
}

struct TailscalePeer: Identifiable, Equatable {
    let id: String
    var name: String, dns: String, os: String, addresses: [String], userID: String, tags: [String]
    var online: Bool, active: Bool, exitOption: Bool
    var rx: UInt64, tx: UInt64
    var direct: String, relay: String, peerRelay: String
    var approvalPending = false
    var address: String { addresses.first(where: { !$0.contains(":") }) ?? addresses.first ?? dns }
    var route: String {
        guard active else { return "Idle · path unverified" }
        if !peerRelay.isEmpty { return "Peer Relay" }
        if !direct.isEmpty { return "Direct" }
        if !relay.isEmpty { return "DERP · \(relay)" }
        return "Path unverified"
    }
    var mobile: Bool { ["ios", "ipados"].contains(os.lowercased()) }
    static func parse(_ value: [String: Any], key: String = "") -> Self {
        Self(id: value["ID"] as? String ?? key, name: value["HostName"] as? String ?? "Unnamed device",
             dns: value["DNSName"] as? String ?? "", os: value["OS"] as? String ?? "Unknown",
             addresses: value["TailscaleIPs"] as? [String] ?? [], userID: (value["UserID"] as? NSNumber)?.stringValue ?? "",
             tags: value["Tags"] as? [String] ?? [], online: value["Online"] as? Bool ?? false,
             active: value["Active"] as? Bool ?? false, exitOption: value["ExitNodeOption"] as? Bool ?? false,
             rx: (value["RxBytes"] as? NSNumber)?.uint64Value ?? 0, tx: (value["TxBytes"] as? NSNumber)?.uint64Value ?? 0,
             direct: value["CurAddr"] as? String ?? "", relay: value["Relay"] as? String ?? "", peerRelay: value["PeerRelay"] as? String ?? "")
    }
}

struct TailscaleSnapshot {
    var state: TailscaleConnection = .notInstalled
    var account = "", tailnet = "", version = "", health: [String] = []
    var authURL: URL?
    var local: TailscalePeer?, peers: [TailscalePeer] = []
    var identity: String { tailnet + "|" + account + "|" + (local?.id ?? "") }
    static func parse(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TailscaleFailure.invalid("Invalid status JSON") }
        var result = Self()
        let backend = root["BackendState"] as? String ?? ""
        switch backend {
        case "Running": result.state = .connected
        case "Stopped": result.state = .disconnected
        case "NeedsLogin": result.state = .signedOut
        case "NeedsMachineAuth": result.state = .deviceApproval
        case "Starting": result.state = .connecting
        case "NoState": result.state = .connecting
        default: result.state = .error
        }
        if let raw = root["AuthURL"] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "login.tailscale.com" { result.authURL = url }
        result.version = root["Version"] as? String ?? "Unknown"
        result.health = root["Health"] as? [String] ?? []
        if result.state != .connected && result.health.contains(where: Self.requiresExtensionApproval) { result.state = .extensionApproval }
        result.tailnet = (root["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? root["MagicDNSSuffix"] as? String ?? ""
        if let local = root["Self"] as? [String: Any] { result.local = .parse(local) }
        let users = root["User"] as? [String: [String: Any]] ?? [:]
        result.account = users[result.local?.userID ?? ""]?["LoginName"] as? String ?? ""
        result.peers = (root["Peer"] as? [String: [String: Any]] ?? [:]).map { .parse($0.value, key: $0.key) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
    static func requiresExtensionApproval(_ message: String) -> Bool {
        let message = message.lowercased()
        return (message.contains("extension") || message.contains("vpn configuration")) && ["requires approval", "approval required", "not approved", "waiting for user", "needs approval"].contains(where: message.contains)
    }
    static func commandFailureState(_ message: String) -> TailscaleConnection {
        if requiresExtensionApproval(message) { return .extensionApproval }
        let message = message.lowercased()
        return message.contains("permission") || message.contains("denied") ? .uncontrollable : .error
    }
    func canTaildrop(to peer: TailscalePeer) -> Bool {
        guard let local, !local.userID.isEmpty else { return false }
        return local.tags.isEmpty && peer.tags.isEmpty && peer.userID == local.userID && !peer.address.isEmpty
    }
}

struct TailscalePreferences {
    var values: [String: Any] = [:]
    func bool(_ name: String) -> Bool? { values[name] as? Bool }
    func string(_ name: String) -> String? { values[name] as? String }
    static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TailscaleFailure.invalid("Invalid preference JSON") }
        return Self(values: object)
    }
    static let allowed = Set(["accept-dns", "accept-routes", "shields-up", "exit-node", "exit-node-allow-lan-access", "advertise-exit-node", "advertise-routes", "ssh"])
    static func arguments(_ name: String, _ value: String) throws -> [String] {
        guard allowed.contains(name), !value.contains("\n") else { throw TailscaleFailure.invalid("Invalid preference") }
        return ["set", "--\(name)=\(value)"]
    }
}

struct TailscaleTraffic {
    private var previous: (String, TimeInterval, [String: Double])?
    var rates: [String: Double] = [:]
    mutating func reset() { previous = nil; rates = [:] }
    mutating func sample(_ text: String?, identity: String, now: TimeInterval) {
        guard let text else { reset(); return }
        var counters: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("tailscaled_inbound_bytes_total") || line.hasPrefix("tailscaled_outbound_bytes_total"),
                  let last = line.split(separator: " ").last, let value = Double(last), value >= 0, value.isFinite else { continue }
            let name = String(line.prefix(while: { $0 != " " }))
            counters[name] = value
        }
        guard !counters.isEmpty else { reset(); return }
        defer { previous = (identity, now, counters) }
        guard let old = previous, old.0 == identity, now > old.1, Set(counters.keys) == Set(old.2.keys),
              counters.allSatisfy({ $0.value >= (old.2[$0.key] ?? .infinity) }) else { rates = [:]; return }
        rates = counters.mapValues { _ in 0 }
        for (key, value) in counters { rates[key] = (value - old.2[key]!) / (now - old.1) }
    }
    var inbound: Double? { sum("tailscaled_inbound") }
    var outbound: Double? { sum("tailscaled_outbound") }
    private func sum(_ prefix: String) -> Double? { let values = rates.filter { $0.key.hasPrefix(prefix) }.values; return values.isEmpty ? nil : values.reduce(0, +) }
}

struct TailscaleAccount: Decodable, Identifiable { var id: String; var account: String?; var tailnet: String?; var nickname: String?; var selected: Bool? }

struct TailscaleService: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String, scheme: String, port: Int, path: String
    func url(host: String) -> URL? {
        guard ["ssh", "smb", "http", "https", "vnc"].contains(scheme), (1...65535).contains(port), !host.isEmpty else { return nil }
        var parts = URLComponents(); parts.scheme = scheme; parts.host = host; parts.port = port
        parts.path = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/" + path)
        return parts.url
    }
    static let defaults = [Self(name: "SSH", scheme: "ssh", port: 22, path: ""), Self(name: "Files / SMB", scheme: "smb", port: 445, path: ""), Self(name: "Web", scheme: "http", port: 8080, path: ""), Self(name: "Screen Sharing", scheme: "vnc", port: 5900, path: "")]
}

enum TailscaleShareMode: String, CaseIterable { case https, http, tcp; case tlsTCP = "tls-terminated-tcp"
    var web: Bool { self == .https || self == .http }
}

struct TailscaleShare: Identifiable, Equatable {
    var host: String, port: Int, path: String, target: String, publicAccess: Bool
    var mode: TailscaleShareMode = .https
    var id: String { "\(host):\(port)\(path)" }
    static func parse(_ data: Data) throws -> [Self] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TailscaleFailure.invalid("Invalid sharing JSON") }
        let publicPorts = object["AllowFunnel"] as? [String: Bool] ?? [:]
        let ports = object["TCP"] as? [String: [String: Any]] ?? [:]
        var entries: [Self] = []
        for (hostPort, web) in object["Web"] as? [String: [String: Any]] ?? [:] {
            guard let colon = hostPort.lastIndex(of: ":"), let port = Int(hostPort[hostPort.index(after: colon)...]) else { continue }
            let host = String(hostPort[..<colon])
            let mode: TailscaleShareMode = ports[String(port)]?["HTTP"] as? Bool == true ? .http : .https
            for (path, handler) in web["Handlers"] as? [String: [String: Any]] ?? [:] {
                entries.append(Self(host: host, port: port, path: path, target: handler["Proxy"] as? String ?? handler["Path"] as? String ?? "Text content", publicAccess: publicPorts[hostPort] == true, mode: mode))
            }
        }
        for (portText, handler) in ports {
            guard let port = Int(portText), let forward = handler["TCPForward"] as? String, !forward.isEmpty else { continue }
            let tls = handler["TerminateTLS"] as? String ?? ""
            let publicHost = publicPorts.first { $0.key.hasSuffix(":" + portText) && $0.value }?.key
            let host = publicHost.map { String($0.dropLast(portText.count + 1)) } ?? tls
            entries.append(Self(host: host, port: port, path: "", target: forward, publicAccess: publicHost != nil, mode: tls.isEmpty ? .tcp : .tlsTCP))
        }
        return entries.sorted { $0.id < $1.id }
    }
    func offArguments() -> [String] {
        var result = [publicAccess ? "funnel" : "serve", "--\(mode.rawValue)=\(port)"]
        if mode.web { result.append("--set-path=\(path)") }
        return result + ["off"]
    }
    /// Compare every unrelated top-level entry, including unknown future schema fields.
    static func preservesUnrelated(before: Data, after: Data, port: Int, path: String, mode: TailscaleShareMode) -> Bool {
        func scrub(_ data: Data) -> NSDictionary? {
            guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var tcp = object["TCP"] as? [String: Any] ?? [:]; tcp[String(port)] = nil
            object["TCP"] = tcp.isEmpty ? nil : tcp
            var web = object["Web"] as? [String: [String: Any]] ?? [:]
            for key in Array(web.keys) where key.hasSuffix(":" + String(port)) {
                if mode.web {
                    var server = web[key] ?? [:]
                    var handlers = server["Handlers"] as? [String: Any] ?? [:]; handlers[path] = nil
                    if handlers.isEmpty { web[key] = nil } else { server["Handlers"] = handlers; web[key] = server }
                } else { web[key] = nil }
            }
            object["Web"] = web.isEmpty ? nil : web
            var funnel = object["AllowFunnel"] as? [String: Bool] ?? [:]
            for key in Array(funnel.keys) where key.hasSuffix(":" + String(port)) { funnel[key] = nil }
            object["AllowFunnel"] = funnel.isEmpty ? nil : funnel
            object["ETag"] = nil
            return object as NSDictionary
        }
        guard let a = scrub(before), let b = scrub(after),
              let oldShares = try? parse(before), let newShares = try? parse(after) else { return false }
        let unrelated: (TailscaleShare) -> Bool = { $0.port != port || (mode.web && $0.path != path) }
        return a == b && oldShares.filter(unrelated) == newShares.filter(unrelated)
    }
}
