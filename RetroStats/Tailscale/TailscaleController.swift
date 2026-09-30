import AppKit
import Foundation

@MainActor final class TailscaleController: ObservableObject {
    @Published private(set) var installation: TailscaleInstallation?
    @Published private(set) var snapshot = TailscaleSnapshot()
    @Published private(set) var capabilities = TailscaleCapabilities()
    @Published private(set) var preferences = TailscalePreferences()
    @Published private(set) var traffic = TailscaleTraffic()
    @Published private(set) var busy = false
    @Published private(set) var refreshedAt: Date?
    @Published var message = ""
    @Published var diagnosticResult = ""
    @Published var accounts: [TailscaleAccount] = []
    @Published var shares: [TailscaleShare] = []
    @Published var sharingJSON = ""
    private var sharingData = Data()
    @Published var favorites: Set<String>
    @Published var services: [TailscaleService] { didSet { if let data = try? JSONEncoder().encode(services) { defaults.set(data, forKey: "tailscaleServices") } } }
    @Published private(set) var api: TailscaleAdminAPI?
    @Published var adminDevices: [TailscaleAdminDevice] = []
    @Published var policy: TailscalePolicy?
    @Published var dnsJSON = ""
    @Published var routesJSON = ""
    private(set) lazy var access = MacAccessCoordinator(defaults: defaults)
    let mobile: MobileSetupSession
    private let executor: any TailscaleExecuting
    private let detect: () -> TailscaleInstallation?
    private let store: any TailscaleCredentialStore
    private let makeAPI: (String, String) -> TailscaleAdminAPI
    var isFixture: Bool { fixture }
    private var openedClientPath = ""
    private var openedAccessState = ""
    private var lastAdminDiscovery = -Double.infinity
    private let defaults: UserDefaults
    private var generation = 0, networkActive = false, fixture: Bool
    private var polling: Task<Void, Never>?, operation: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    init(executor: any TailscaleExecuting = TailscaleCLI(), detect: @escaping () -> TailscaleInstallation? = { .detect() }, store: any TailscaleCredentialStore = TailscaleKeychain(), mobile: MobileSetupSession? = nil, defaults: UserDefaults = .standard, fixture: Bool = false, access: MacAccessCoordinator? = nil, makeAPI: @escaping (String, String) -> TailscaleAdminAPI = { TailscaleAdminAPI(tailnet: $0, credential: $1) }) {
        self.executor = executor; self.detect = detect; self.store = store; self.makeAPI = makeAPI; self.defaults = defaults; self.fixture = fixture
        self.mobile = mobile ?? MobileSetupSession()
        favorites = Set(defaults.stringArray(forKey: "tailscaleFavorites") ?? [])
        services = defaults.data(forKey: "tailscaleServices").flatMap { try? JSONDecoder().decode([TailscaleService].self, from: $0) } ?? TailscaleService.defaults
        if let access { self.access = access }
        self.mobile.changed = { [weak self] in self?.updatePolling() }
        self.mobile.onEnd = { [weak self] key in
            guard let self, let key else { return }
            if NSPasteboard.general.string(forType: .string) == key.secret { NSPasteboard.general.clearContents() }
            guard let api = self.api else { return }
            // Revoke even if the one-use key may already have been consumed; never retain its secret.
            Task { do { try await api.revokeKey(key.id) } catch { self.message = "Session ended. Auth-key revoke could not be confirmed; it expires after 10 minutes." } }
        }
        if !fixture {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.wake() }
            }
        }
    }
    deinit { polling?.cancel(); operation?.cancel(); if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) } }
    func setNetworkActive(_ active: Bool) {
        if active != networkActive { polling?.cancel(); polling = nil }
        networkActive = active; updatePolling()
    }
    private func updatePolling() {
        guard !fixture else { return }
        if networkActive || mobile.active || access.wantsConnection {
            guard polling == nil else { return }
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    try? await Task.sleep(for: .seconds(self.networkActive || self.mobile.active ? 3 : 15))
                }
            }
        } else {
            polling?.cancel(); polling = nil; generation += 1; traffic.reset()
        }
    }
    func wake() { traffic.reset(); access.wake(); if networkActive || mobile.active || access.wantsConnection { Task { await refresh() } } }
    private func cli(_ arguments: [String], timeout: TimeInterval = 12) async throws -> TailscaleCommandResult {
        guard let installation else { throw TailscaleFailure.unavailable("Install the official Tailscale client first.") }
        return try await executor.run(executable: installation.executable, arguments: arguments, timeout: timeout)
    }
    func refresh() async {
        guard !fixture, !busy else { return }
        busy = true; let token = generation
        defer {
            busy = false
            if !fixture, access.enabled, generation == token, !Task.isCancelled { Task { [weak self] in await self?.driveAccess() } }
        }
        let detected = detect()
        if installation != detected {
            installation = detected; capabilities = .init(); preferences = .init(); traffic.reset()
        }
        guard let detected else { snapshot = .init(); return }
        if access.wantsConnection, let path = detected.appPath, openedClientPath != path {
            openedClientPath = path
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in }
        }
        do {
            if capabilities.variant == .unknown {
                var capabilities = TailscaleCapabilities(); capabilities.variant = detected.variant
                for command in ["set", "get", "switch", "file", "serve", "funnel", "metrics", "ping", "netcheck"] {
                    try Task.checkCancellation()
                    let result = try await cli([command, "--help"], timeout: 4)
                    let help = result.text + String(decoding: result.stderr, as: UTF8.self)
                    if result.status == 0 && !help.lowercased().contains("unknown subcommand") { capabilities.help[command] = help }
                }
                guard generation == token else { return }; self.capabilities = capabilities
            }
            let result = try await cli(["status", "--json"])
            if result.status != 0 {
                guard generation == token, !Task.isCancelled else { return }
                let error = String(decoding: result.stderr, as: UTF8.self).lowercased()
                snapshot = .init(); snapshot.state = TailscaleSnapshot.commandFailureState(error)
                message = "Status unavailable. Open the official client and check extension approval / permissions."; traffic.reset(); return
            }
            let status = try TailscaleSnapshot.parse(result.stdout)
            var prefs = TailscalePreferences()
            if capabilities.supports("get") {
                let result = try await cli(["get", "--json"])
                if result.status == 0 { prefs = try .parse(result.stdout) }
            }
            var metrics: String?
            if capabilities.supports("metrics") {
                let result = try await cli(["metrics", "print"])
                if result.status == 0 { metrics = result.text }
            }
            let finalStatus = try TailscaleSnapshot.parse(try await cli(["status", "--json"]).checked().stdout)
            guard generation == token, !Task.isCancelled else { return }
            guard status.identity == finalStatus.identity else {
                traffic.reset(); preferences = .init(); accounts = []; shares = []; diagnosticResult = ""
                mobile.end(); snapshot = finalStatus
                message = "Account changed during collection. Discarded stale settings; refreshing on the next sample."
                return
            }
            if status.identity != snapshot.identity { traffic.reset(); accounts = []; shares = []; sharingJSON = ""; diagnosticResult = "" }
            snapshot = status; preferences = prefs; refreshedAt = Date()
            traffic.sample(metrics, identity: status.identity, now: ProcessInfo.processInfo.systemUptime)
            if mobile.active, let api, api.tailnet.caseInsensitiveCompare(status.tailnet) == .orderedSame,
               ProcessInfo.processInfo.systemUptime - lastAdminDiscovery >= 9 {
                lastAdminDiscovery = ProcessInfo.processInfo.systemUptime
                do { let devices = try await api.devices(); if generation == token && !Task.isCancelled { adminDevices = devices } }
                catch { message = error.localizedDescription }
            }
            guard generation == token, !Task.isCancelled else { return }
            mobile.update(snapshot: status, services: services, adminDevices: mobileAPIAvailable ? adminDevices : [])
        } catch is CancellationError { traffic.reset() }
        catch { if generation == token { message = error.localizedDescription; snapshot.state = .error; traffic.reset() } }
    }
    func action(_ work: @escaping () async throws -> Void) {
        guard !fixture, !busy else { return }
        busy = true; generation += 1; let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.operation = nil }
            do { try await work(); if self.generation == token { self.message = "Operation completed; read-back refreshed." } }
            catch { if self.generation == token { self.message = error.localizedDescription } }
            guard self.generation == token else { return }
            self.busy = false; await self.refresh()
        }
    }
    func cancel() { operation?.cancel() }
    func connection(_ connected: Bool) { if !connected { access.pause() }; action { _ = try await self.cli([connected ? "up" : "down"], timeout: 20).checked() } }
    func logout() { access.pause(); mobile.end(); action { _ = try await self.cli(["logout"]).checked() } }
    func set(_ name: String, _ value: String) {
        guard capabilities.flag("set", name), name != "exit-node" || capabilities.exitClient,
              name != "ssh" || capabilities.sshServer else { message = "Unsupported on this distribution. Use the official client / macOS Sharing settings."; return }
        action {
            _ = try await self.cli(TailscalePreferences.arguments(name, value)).checked()
            guard self.capabilities.supports("get") else { throw TailscaleFailure.invalid("Change sent; this CLI cannot read preferences. Verify in the official client.") }
            let result = try await self.cli(["get", "--json"]).checked()
            let preferences = try TailscalePreferences.parse(result.stdout)
            let actual = preferences.string(name) ?? preferences.bool(name).map { $0 ? "true" : "false" }
            guard actual == value else { throw TailscaleFailure.invalid("The requested preference was not confirmed by read-back.") }
        }
    }
    func toggleFavorite(_ peer: TailscalePeer) {
        let key = snapshot.identity + "|" + peer.id
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        defaults.set(Array(favorites), forKey: "tailscaleFavorites")
    }
    func isFavorite(_ peer: TailscalePeer) -> Bool { favorites.contains(snapshot.identity + "|" + peer.id) }
    func diagnose(_ peer: TailscalePeer? = nil) {
        action {
            let arguments = peer.map { ["ping", "--c=3", "--timeout=3s", $0.address] } ?? ["netcheck", "--format=json"]
            let result = try await self.cli(arguments, timeout: 15).checked()
            self.diagnosticResult = result.text
        }
    }
    func loadAccounts() { action { self.accounts = try JSONDecoder().decode([TailscaleAccount].self, from: await self.cli(["switch", "--list", "--json"]).checked().stdout) } }
    func switchAccount(_ id: String) { access.pause(); mobile.end(); action { self.traffic.reset(); self.snapshot = .init(); _ = try await self.cli(["switch", id]).checked() } }
    func loadShares() { action { try await self.readShares() } }
    private func readShares() async throws {
        let result = try await cli(["serve", "status", "--json"]).checked()
        sharingData = result.stdout; sharingJSON = result.text; shares = try TailscaleShare.parse(result.stdout)
    }
    func share(target: String, port: Int, path: String, publicly: Bool, mode: TailscaleShareMode = .https, didShare: (() -> Void)? = nil) {
        guard capabilities.supports(publicly ? "funnel" : "serve"), (1...65535).contains(port), (!mode.web || path.hasPrefix("/")), !path.contains("?"), !path.contains("#") else { message = "Invalid share or unsupported CLI"; return }
        if publicly && ![443, 8443, 10000].contains(port) { message = "Funnel uses port 443, 8443 or 10000."; return }
        if publicly && mode == .http { message = "Funnel requires HTTPS or TCP."; return }
        let file = target.hasPrefix("/")
        guard !file || capabilities.fileSharing else { message = "GUI distributions cannot serve files. Share a local HTTP port instead."; return }
        if !file && mode.web {
            guard let url = URLComponents(string: target), ["http", "https"].contains(url.scheme), ["127.0.0.1", "localhost", "::1"].contains(url.host), url.user == nil, url.password == nil else { message = "Choose a local HTTP target such as http://127.0.0.1:8080"; return }
        }
        if !mode.web {
            let pieces = target.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, ["127.0.0.1", "localhost"].contains(String(pieces[0])), let targetPort = Int(pieces[1]), (1...65535).contains(targetPort) else { message = "Choose a local TCP target such as 127.0.0.1:8080"; return }
        }
        action {
            try await self.readShares()
            let before = self.sharingData
            guard !self.shares.contains(where: { $0.port == port && (!mode.web || !$0.mode.web || $0.mode != mode || $0.path == path || $0.publicAccess != publicly) }) else { throw TailscaleFailure.invalid("This port/path already has a share. Remove the selected share before changing its scope.") }
            var args = [publicly ? "funnel" : "serve", "--bg", "--\(mode.rawValue)=\(port)"]
            if mode.web { args.append("--set-path=\(path)") }
            _ = try await self.cli(args + [target], timeout: 20).checked()
            try await self.readShares()
            guard TailscaleShare.preservesUnrelated(before: before, after: self.sharingData, port: port, path: path, mode: mode), self.shares.contains(where: { $0.port == port && (!mode.web || $0.path == path) && $0.publicAccess == publicly && $0.mode == mode && $0.target == target }) else { throw TailscaleFailure.invalid("Sharing was not confirmed. Check HTTPS, policy and the installed CLI.") }
            didShare?()
        }
    }
    func removeShare(_ share: TailscaleShare) {
        action {
            try await self.readShares()
            let before = self.sharingData
            guard self.shares.contains(share) else { throw TailscaleFailure.conflict }
            _ = try await self.cli(share.offArguments()).checked()
            try await self.readShares()
            guard TailscaleShare.preservesUnrelated(before: before, after: self.sharingData, port: share.port, path: share.path, mode: share.mode), !self.shares.contains(where: { $0.id == share.id }) else { throw TailscaleFailure.invalid("Share removal was not confirmed") }
        }
    }
    func sendFiles(to peer: TailscalePeer, files: [URL]) {
        guard snapshot.canTaildrop(to: peer), capabilities.supports("file"), !files.isEmpty else { message = "Taildrop requires your own untagged devices and a supported file command."; return }
        action { _ = try await self.cli(["file", "cp"] + files.map(\.path) + [peer.address + ":"], timeout: 120).checked() }
    }
    func receiveFiles(at directory: URL) { action { _ = try await self.cli(["file", "get", "--conflict=rename", directory.path], timeout: 60).checked() } }
    func startMobile() { guard !fixture else { return }; mobile.begin(snapshot: snapshot, services: services, adminDevices: mobileAPIAvailable ? adminDevices : []) }
    func restoreAccess() {
        guard !fixture, access.enabled else { return }
        access.changed = { [weak self] in self?.updatePolling() }
        access.restore(); updatePolling()
    }
    func beginAccess() {
        guard !fixture else { return }
        do { try access.enable(); access.changed = { [weak self] in self?.updatePolling() }; updatePolling() }
        catch { message = "Saved link unavailable. Reissue the access link on this Mac."; return }
        Task { await refresh(); await driveAccess(openRequired: true) }
    }
    private func driveAccess(openRequired: Bool = false) async {
        guard !fixture, access.enabled else { return }
        if snapshot.state == .connected && preferences.bool("shields-up") == true { access.blockIncoming(); return }
        await access.update(snapshot: snapshot, configured: services)
        mobile.accessURL = access.url
        guard access.wantsConnection else { return }
        if snapshot.state == .disconnected && !busy && access.shouldReconnect() {
            connection(true)
        } else if openRequired || openedAccessState != (installation?.executable ?? "") + snapshot.state.rawValue {
            openedAccessState = (installation?.executable ?? "") + snapshot.state.rawValue
            if let authURL = snapshot.authURL { NSWorkspace.shared.open(authURL) }
            else if let path = installation?.appPath, snapshot.state != .connected { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }
    func installAccessClient() {
        guard !fixture, !busy, installation == nil else { return }
        action {
            let package = try await TailscaleInstaller.acquire(executor: self.executor)
            guard NSWorkspace.shared.open(package) else { throw TailscaleFailure.invalid("Verified package is ready but Installer could not open it.") }
        }
    }
    func allowAccessIncoming() {
        guard !fixture else { return }
        if capabilities.flag("set", "shields-up") { set("shields-up", "false") }
        else { message = "Allow incoming connections in the official client."; if let path = installation?.appPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    }
    func reissueAccess() {
        guard !fixture else { return }
        do { try access.reissue(); updatePolling(); Task { await driveAccess() } }
        catch { message = "Access link could not be stored in Keychain." }
    }
    func proxyAccessWeb(_ service: TailscaleService) {
        guard ["http", "https"].contains(service.scheme), service.port > 0, service.port < 65536 else { return }
        let used = Set(services.map(\.port) + shares.map(\.port) + [Int(access.url?.port ?? 49182)])
        guard let port = (18080...18180).first(where: { !used.contains($0) }) else { message = "No unused web sharing port"; return }
        share(target: service.url(host: "127.0.0.1")!.absoluteString, port: port, path: "/", publicly: false, mode: .http) { [weak self] in
            guard let self else { return }
            var exposed = service; exposed.id = UUID().uuidString; exposed.port = port; exposed.path = ""; exposed.scheme = "http"; exposed.name += " (remote)"
            self.services.append(exposed)
        }
    }

    func connectAPI(tailnet: String, credential: String) {
        action {
            let api = self.makeAPI(tailnet, credential)
            let devices = try await api.devices()
            try self.store.write(credential); self.defaults.set(tailnet, forKey: "tailscaleAdminTailnet")
            self.api = api; self.adminDevices = devices
        }
    }
    func restoreAPI() {
        guard let tailnet = defaults.string(forKey: "tailscaleAdminTailnet") else { return }
        action { guard let credential = try self.store.read() else { throw TailscaleFailure.credential }; let api = self.makeAPI(tailnet, credential); self.adminDevices = try await api.devices(); self.api = api }
    }
    func disconnectAPI() {
        guard !busy else { return }
        mobile.end()
        do { try store.remove(); api = nil; adminDevices = []; policy = nil; dnsJSON = ""; routesJSON = ""; defaults.removeObject(forKey: "tailscaleAdminTailnet") }
        catch { message = error.localizedDescription }
    }
    func admin(_ work: @escaping (TailscaleAdminAPI) async throws -> Void) {
        guard let api else { message = "Connect the optional administrator API first."; return }
        action { try await work(api) }
    }
    var mobileAPIAvailable: Bool { snapshot.state == .connected && api?.tailnet.caseInsensitiveCompare(snapshot.tailnet) == .orderedSame && !snapshot.tailnet.isEmpty }
    func approveMobile() {
        guard mobileAPIAvailable else { message = "Connect the administrator API for this Mac’s current tailnet first."; return }
        guard let peer = mobile.candidates.first(where: { $0.id == mobile.selectedID }) else { return }
        admin { api in
            let devices = try await api.devices()
            guard let device = devices.first(where: { $0.nodeID == peer.id || $0.id == peer.id || !Set($0.addresses).intersection(peer.addresses).isEmpty }) else { throw TailscaleFailure.invalid("Selected mobile device not found in this administrator tailnet") }
            try await api.approveDevice(device.id); self.adminDevices = try await api.devices()
            guard self.adminDevices.first(where: { $0.id == device.id })?.authorized == true else { throw TailscaleFailure.invalid("Device approval was not confirmed by read-back") }
        }
    }
    func createMobileKey(preauthorized: Bool) {
        guard mobileAPIAvailable, mobile.active, mobile.authKey == nil else { return }
        let session = mobile
        let sessionID = session.sessionID
        admin { api in
            let key = try await api.createKey(preauthorized: preauthorized)
            guard session.active, session.sessionID == sessionID else { try? await api.revokeKey(key.id); return }
            session.holdKey(key)
        }
    }
    func savePolicy(_ text: String, baseline: TailscalePolicy) {
        admin { api in
            do { try await api.savePolicy(text, baseline: baseline); self.policy = try await api.policy() }
            catch TailscaleFailure.conflict { self.policy = try await api.policy(); throw TailscaleFailure.conflict }
        }
    }
    static func preview(state: TailscaleConnection = .connected) -> TailscaleController {
        let controller = TailscaleController(defaults: UserDefaults(suiteName: "RetroStats.Tailscale.preview." + UUID().uuidString)!, fixture: true)
        controller.installation = .init(executable: "/fixture/tailscale", appPath: nil, variant: .standalone)
        controller.snapshot = try! .parse(Data(#"{"BackendState":"Running","Version":"fixture","CurrentTailnet":{"Name":"example.test"},"Self":{"ID":"mac","HostName":"Studio Mac","UserID":1,"TailscaleIPs":["100.64.0.1"]},"User":{"1":{"LoginName":"runner@example.test"}},"Peer":{"p":{"ID":"phone","HostName":"My iPhone with a very long name","OS":"iOS","UserID":1,"Online":true,"TailscaleIPs":["100.64.0.2"]}}}"#.utf8))
        controller.snapshot.state = state
        controller.access = .preview(snapshot: controller.snapshot, services: controller.services, defaults: controller.defaults)
        controller.capabilities.variant = .standalone
        for command in ["set", "get", "switch", "file", "serve", "funnel", "metrics"] { controller.capabilities.help[command] = "--accept-dns --accept-routes --shields-up --exit-node --exit-node-allow-lan-access --advertise-exit-node --advertise-routes --bg --https --set-path" }
        controller.preferences = .init(values: ["accept-dns": true, "accept-routes": false, "shields-up": false, "exit-node": "", "exit-node-allow-lan-access": false, "advertise-exit-node": false, "advertise-routes": ""])
        if state == .notInstalled { controller.installation = nil; controller.snapshot = .init() }
        return controller
    }
}
