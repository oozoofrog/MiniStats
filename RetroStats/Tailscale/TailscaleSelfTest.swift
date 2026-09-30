import Foundation
import AppKit
import Network

private func tsRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TailscaleFailure.invalid("Self-test: " + message) }
}
private func tsThrows(_ expected: TailscaleFailure, _ work: () async throws -> Void) async throws {
    do { try await work(); throw TailscaleFailure.invalid("Self-test: expected failure was missing") }
    catch let failure as TailscaleFailure { try tsRequire(failure == expected, "Wrong typed failure") }
}

actor TailscaleFixtureExecutor: TailscaleExecuting {
    var calls: [[String]] = []
    var state: Data
    var prefs: [String: Any] = ["accept-dns": true, "accept-routes": false, "shields-up": false, "exit-node": "", "advertise-routes": "10.1.0.0/24"]
    var delayStatus = false
    init(state: Data) { self.state = state }
    func blockIncoming() { prefs["shields-up"] = true }
    func delayNextStatus() { delayStatus = true }
    func setState(_ data: Data) { state = data }
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> TailscaleCommandResult {
        calls.append(arguments)
        if arguments.last == "--help" {
            return .init(stdout: Data("Usage --accept-dns --accept-routes --shields-up --exit-node --advertise-exit-node --advertise-routes --ssh".utf8), stderr: Data(), status: 0)
        }
        if arguments == ["status", "--json"] {
            let saved = state
            if delayStatus { delayStatus = false; try? await Task.sleep(for: .milliseconds(180)) }
            return .init(stdout: saved, stderr: Data(), status: 0)
        }
        if ["up", "down"].contains(arguments.first ?? "") {
            var object = try JSONSerialization.jsonObject(with: state) as! [String: Any]
            object["BackendState"] = arguments.first == "up" ? "Running" : "Stopped"
            state = try JSONSerialization.data(withJSONObject: object)
        }
        if arguments.first == "set", let flag = arguments.last {
            let parts = flag.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let value = String(parts[1]); prefs[String(parts[0])] = value == "true" ? true : value == "false" ? false : value as Any
        }
        if arguments == ["get", "--json"] { return .init(stdout: try JSONSerialization.data(withJSONObject: prefs), stderr: Data(), status: 0) }
        return .init(stdout: Data(), stderr: Data(), status: 0)
    }
}
private actor FixtureAPITransport: TailscaleAPITransport {
    var results: [TailscaleAPIResponse]
    var requests: [URLRequest] = []
    var delayKey: TimeInterval = 0
    func delayAuthKey(_ duration: TimeInterval) { delayKey = duration }
    init(_ results: [TailscaleAPIResponse]) { self.results = results }
    func send(_ request: URLRequest) async throws -> TailscaleAPIResponse {
        requests.append(request)
        guard !results.isEmpty else { throw TailscaleFailure.invalid("Self-test: unexpected API call") }
        let result = results.removeFirst()
        if request.url?.path.hasSuffix("/keys") == true && request.httpMethod == "POST", delayKey > 0 { try await Task.sleep(for: .seconds(delayKey)) }
        return result
    }
}
private final class FixtureCredentials: TailscaleCredentialStore {
    var value: String?
    var interactiveReads = 0, backgroundReads = 0
    var backgroundReadDenied = false
    func read() throws -> String? { interactiveReads += 1; return value }
    func readWithoutInteraction() throws -> String? {
        backgroundReads += 1
        if backgroundReadDenied { throw TailscaleFailure.credential }
        return value
    }
    func write(_ value: String) throws { self.value = value }
    func remove() throws { value = nil }
}
private final class FixtureGuide: MobileGuideServing {
    var address = "", token = "", expires = Date.distantPast, stopped = false
    var visited: ((String) -> Void)?
    var page: ((String) -> String)?
    func start(address: String, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void, failed: @escaping () -> Void) throws {
        self.address = address; self.token = token; self.expires = expires; self.page = page; self.visited = visited
        ready(45123)
    }
    func stop() { stopped = true }
}

@MainActor func tailscaleSelfTest() throws {
    var finished = false, failure: Error?
    Task { @MainActor in
        do { try await tailscaleAsyncSelfTest() } catch { failure = error }
        finished = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard finished else { throw TailscaleFailure.timeout }
    if let failure { throw failure }
}

@MainActor private func tailscaleAsyncSelfTest() async throws {
    try installationFixtureSelfTest()
    let status = Data(#"{"BackendState":"Running","CurrentTailnet":{"Name":"example.test"},"Self":{"ID":"mac","UserID":1,"HostName":"Mac","TailscaleIPs":["100.64.0.1"]},"User":{"1":{"LoginName":"owner@example.test"}},"Peer":{"a":{"ID":"a","OS":"iOS","UserID":1,"HostName":"My iPhone","Online":true,"Active":true,"CurAddr":"192.0.2.1:4567","TailscaleIPs":["100.64.0.2"]},"b":{"ID":"b","OS":"iOS","UserID":2,"Tags":["tag:test"],"TailscaleIPs":["100.64.0.3"]}}}"#.utf8)
    let snapshot = try TailscaleSnapshot.parse(status)
    try await macAccessSelfTest(snapshot: snapshot)
    try tsRequire(snapshot.state == .connected && snapshot.account == "owner@example.test" && snapshot.peers.count == 2, "Status identity")
    let phone = snapshot.peers.first { $0.id == "a" }!
    try tsRequire(phone.route == "Direct" && snapshot.canTaildrop(to: phone), "Peer path and Taildrop owner")
    try tsRequire(!snapshot.canTaildrop(to: snapshot.peers.first { $0.id == "b" }!), "Tagged / other owner Taildrop")
    let missing = try TailscaleSnapshot.parse(Data("{}".utf8))
    try tsRequire(missing.state == .error && missing.peers.isEmpty, "Missing status fields")
    for (backend, expected) in [("NeedsLogin", TailscaleConnection.signedOut), ("Stopped", .disconnected), ("NeedsMachineAuth", .deviceApproval), ("Starting", .connecting), ("NoState", .connecting)] {
        let parsed = try TailscaleSnapshot.parse(JSONSerialization.data(withJSONObject: ["BackendState": backend]))
        try tsRequire(parsed.state == expected, "Backend states")
    }
    try tsRequire(TailscaleSnapshot.commandFailureState("network extension requires approval") == .extensionApproval && TailscaleSnapshot.commandFailureState("permission denied") == .uncontrollable && TailscaleSnapshot.commandFailureState("Is Tailscale running?") == .error, "Approval state needs explicit evidence; daemon absence is not approval evidence")
    var capabilities = TailscaleCapabilities(); capabilities.help = ["set": "--exit-node --ssh", "serve": "Usage", "funnel": "Usage"]
    for variant in [TailscaleVariant.standalone, .appStore, .cli] {
        capabilities.variant = variant
        try tsRequire(capabilities.sshServer == (variant == .cli), "SSH server distribution boundary")
        try tsRequire(capabilities.fileSharing == (variant == .cli), "File sharing distribution boundary")
        try tsRequire(capabilities.exitClient == (variant != .cli), "Exit client distribution boundary")
        try tsRequire(capabilities.supports("funnel"), "GUI Funnel capability uses detected command")
    }
    try tsRequire(!TailscaleCapabilities().supports("get"), "Unknown version capability")
    let args = try TailscalePreferences.arguments("accept-dns", "false")
    try tsRequire(args == ["set", "--accept-dns=false"], "Only selected setting changes")
    var traffic = TailscaleTraffic()
    func metrics(_ inbound: Int, _ outbound: Int) -> String { "tailscaled_inbound_bytes_total{path=\"direct\"} \(inbound)\ntailscaled_outbound_bytes_total{path=\"derp\"} \(outbound)" }
    traffic.sample(metrics(100, 200), identity: "a", now: 10)
    traffic.sample(metrics(160, 320), identity: "a", now: 13)
    try tsRequire(traffic.inbound == 20 && traffic.outbound == 40, "Cumulative metric difference")
    traffic.sample(metrics(10, 10), identity: "a", now: 16)
    try tsRequire(traffic.rates.isEmpty, "Counter reset")
    traffic.sample(metrics(40, 70), identity: "b", now: 19)
    try tsRequire(traffic.rates.isEmpty, "Account baseline reset")
    traffic.sample(nil, identity: "b", now: 22)
    try tsRequire(traffic.rates.isEmpty, "Missing metrics baseline reset")
    let shareBefore = Data(#"{"TCP":{"443":{"HTTPS":true},"8443":{"TCPForward":"127.0.0.1:9000"}},"Web":{"mac.example.test:443":{"Handlers":{"/one":{"Proxy":"http://127.0.0.1:8080"},"/keep":{"Proxy":"http://127.0.0.1:8081"}}}},"AllowFunnel":{"mac.example.test:443":true},"FutureField":{"preserve":true}}"#.utf8)
    let shareAfter = Data(#"{"TCP":{"443":{"HTTPS":true},"8443":{"TCPForward":"127.0.0.1:9000"}},"Web":{"mac.example.test:443":{"Handlers":{"/keep":{"Proxy":"http://127.0.0.1:8081"}}}},"AllowFunnel":{"mac.example.test:443":true},"FutureField":{"preserve":true}}"#.utf8)
    let shares = try TailscaleShare.parse(shareBefore)
    try tsRequire(shares.count == 3 && shares.contains(where: { $0.mode == .tcp }), "HTTP / TCP sharing schema")
    try tsRequire(TailscaleShare.preservesUnrelated(before: shareBefore, after: shareAfter, port: 443, path: "/one", mode: .https), "Selected sharing removal preserves another path, TCP and unknown schema")
    let broken = Data(String(decoding: shareAfter, as: UTF8.self).replacingOccurrences(of: "\"mac.example.test:443\":true", with: "\"mac.example.test:443\":false").utf8)
    try tsRequire(!TailscaleShare.preservesUnrelated(before: shareBefore, after: broken, port: 443, path: "/one", mode: .https), "Cannot silently change another share's public scope")
    print("PASS: Tailscale status/schema/capabilities, ownership, sharing preservation and isolated tunnel counter reset")

    let executor = TailscaleFixtureExecutor(state: status)
    let suite = "RetroStats.Tailscale.selftest." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
    let controller = TailscaleController(executor: executor, detect: { .init(executable: "/fixture/tailscale", appPath: nil, variant: .standalone) }, store: FixtureCredentials(), defaults: defaults)
    await controller.refresh()
    controller.set("accept-dns", "false")
    while controller.busy { try await Task.sleep(for: .milliseconds(10)) }
    try tsRequire(controller.preferences.bool("accept-dns") == false && controller.preferences.string("advertise-routes") == "10.1.0.0/24", "Preference read-back preserves unrelated routes")
    let calls = await executor.calls
    try tsRequire(calls.filter { $0.first == "set" && $0.last != "--help" } == [["set", "--accept-dns=false"]], "No broad settings replacement")
    await executor.delayNextStatus()
    let stale = Task { await controller.refresh() }
    try await Task.sleep(for: .milliseconds(30))
    controller.setNetworkActive(false) // invalidates an in-flight snapshot
    await stale.value
    try tsRequire(!controller.busy, "Stale completion releases refresh lock")
    await executor.delayNextStatus()
    let externalSwitch = Task { await controller.refresh() }
    try await Task.sleep(for: .milliseconds(30))
    let otherStatus = Data(String(decoding: status, as: UTF8.self).replacingOccurrences(of: "example.test", with: "other.test").utf8)
    await executor.setState(otherStatus)
    await externalSwitch.value
    try tsRequire(controller.snapshot.tailnet == "other.test" && controller.preferences.values.isEmpty && controller.traffic.rates.isEmpty, "External account switch discards old-account preferences and metrics")
    let fixture = TailscaleController(executor: executor, store: FixtureCredentials(), defaults: defaults, fixture: true)
    let count = await executor.calls.count
    fixture.setNetworkActive(true); fixture.startMobile(); await fixture.refresh()
    let fixtureCallCount = await executor.calls.count
    try tsRequire(fixtureCallCount == count && !fixture.mobile.active, "Render fixture starts no CLI/API/server")
    print("PASS: Tailscale partial preference read-back, stale delivery and inert render fixture")

    let runner = TailscaleCLI(limit: 16384)
    let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", "printf stdout; printf stderr >&2"], timeout: 2)
    try tsRequire(result.text == "stdout" && String(decoding: result.stderr, as: UTF8.self) == "stderr", "Parallel pipe drain")
    try await tsThrows(.outputLimit) { _ = try await runner.run(executable: "/usr/bin/yes", arguments: ["bounded"], timeout: 2) }
    try await tsThrows(.timeout) { _ = try await runner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05) }
    let cancel = Task { try await runner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 3) }
    try await Task.sleep(for: .milliseconds(20)); cancel.cancel()
    try await tsThrows(.cancelled) { _ = try await cancel.value }
    let burst = try await TailscaleCLI(limit: 200000).run(executable: "/bin/sh", arguments: ["-c", "(/usr/bin/head -c 70000 /dev/zero >&2) & /usr/bin/head -c 70000 /dev/zero; wait"], timeout: 4)
    try tsRequire(burst.stdout.count == 70000 && burst.stderr.count == 70000, "Both pipes larger than pipe capacity drain without deadlock or truncation")
    print("PASS: CLI concurrent large pipes, output ceiling, timeout and cancellation without Tailscale execution")

    let response = TailscaleAPIResponse(data: Data("{}".utf8), status: 200, etag: "fixture-etag")
    for status in [401, 403, 409, 412] {
        let transport = FixtureAPITransport([.init(data: Data(), status: status, etag: nil)])
        let api = TailscaleAdminAPI(tailnet: "example.test", credential: "test-placeholder", transport: transport)
        try await tsThrows(status == 409 || status == 412 ? .conflict : .api(status)) { _ = try await api.policy() }
    }
    let transport = FixtureAPITransport([response, response])
    let api = TailscaleAdminAPI(tailnet: "example.test", credential: "test-placeholder", transport: transport)
    let baseline = TailscalePolicy(text: "old", etag: "fixture-etag")
    try await api.savePolicy("new", baseline: baseline)
    let requests = await transport.requests
    try tsRequire(requests.count == 2 && requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true && requests[0].url?.path.hasSuffix("/acl/validate") == true && requests[1].value(forHTTPHeaderField: "If-Match") == baseline.etag, "Server validation precedes conditional policy update")
    let body = try JSONSerialization.jsonObject(with: TailscaleAdminAPI.keyBody(preauthorized: false)) as! [String: Any]
    let caps = ((body["capabilities"] as! [String: Any])["devices"] as! [String: Any])["create"] as! [String: Any]
    try tsRequire(body["expirySeconds"] as? Int == 600 && caps["reusable"] as? Bool == false && caps["ephemeral"] as? Bool == false && (caps["tags"] as? [String])?.isEmpty == true, "One-use non-ephemeral untagged 10-minute key")
    try await mobileAdminFixtureSelfTest(status: status, defaults: defaults)
    print("PASS: API permission/expiry/conflict, server policy validation, selected-device approval and auth-key lifetime/race/revoke contract (mock transport only)")

    var servers: [FixtureGuide] = []
    let session = MobileSetupSession(factory: { let server = FixtureGuide(); servers.append(server); return server }, findLAN: { "192.0.2.10" })
    session.begin(snapshot: snapshot, services: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(20))
    try tsRequire(session.selectedID == nil && session.candidates.count == 2, "No mobile identity before a tail-path visit")
    servers.first(where: { $0.address == "192.0.2.10" })?.visited?(phone.address)
    try await Task.sleep(for: .milliseconds(10)); try tsRequire(!session.pathVerified, "LAN visits cannot verify the Tailscale path")
    if let tail = servers.first(where: { $0.address == "100.64.0.1" }) {
        tail.visited?("100.64.0.3"); try await Task.sleep(for: .milliseconds(10)); try tsRequire(!session.pathVerified, "Unselected peer cannot verify path")
        tail.visited?(phone.address); try await Task.sleep(for: .milliseconds(10)); try tsRequire(session.pathVerified, "Source IP identifies own Tailscale browser without selection")
    } else { throw TailscaleFailure.invalid("Self-test: Tailscale listener missing") }
    try tsRequire(!session.serviceVerified && !session.exitVerified, "Browser access cannot imply service or Exit Node success")
    let keyMarker = "self-test-sensitive-marker"
    session.holdKey(.init(id: "test-id", secret: keyMarker, expires: Date().addingTimeInterval(0.04)))
    try tsRequire(!session.keyVisible && !session.guide.html.contains(keyMarker), "Auth key never in HTML / implicit display")
    try await Task.sleep(for: .milliseconds(70))
    try tsRequire(session.authKey == nil, "Key discarded at expiry")
    for language in SetupLanguage.allCases {
        let guide = MobileGuideContent(language: language, address: "100.64.0.1", account: "<unsafe>", tailnet: "example.test", services: TailscaleService.defaults)
        try tsRequire(guide.html.contains("100.64.0.1") && guide.html.contains("&lt;unsafe&gt;") && !guide.html.contains("<unsafe>"), "Localized guide uses escaped actual address/account")
    }
    if let token = servers.first?.token {
        let valid = "GET /\(token) HTTP/1.1\r\nHost: test\r\n\r\n"
        try tsRequire(MobileGuideServer.allowedRequest(valid, token: token, now: Date(), expires: Date().addingTimeInterval(1)), "Exact session path")
        for bad in ["GET / HTTP/1.1", "POST /\(token) HTTP/1.1", "GET /\(token)?x=1 HTTP/1.1", "GET /\(token)/../file HTTP/1.1"] {
            try tsRequire(!MobileGuideServer.allowedRequest(bad, token: token, now: Date(), expires: Date().addingTimeInterval(1)), "Read-only path allowlist")
        }
        try tsRequire(!MobileGuideServer.allowedRequest(valid, token: token, now: Date(), expires: Date().addingTimeInterval(-1)), "Expired token rejected")
    }
    session.end()
    var expiredServers: [FixtureGuide] = []
    let short = MobileSetupSession(factory: { let server = FixtureGuide(); expiredServers.append(server); return server }, findLAN: { "192.0.2.10" }, lifetime: 0.03)
    short.begin(snapshot: snapshot, services: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(60))
    try tsRequire(!short.active && expiredServers.allSatisfy(\.stopped), "Guide timer ends the session and both servers")
    try tsRequire(servers.allSatisfy(\.stopped) && session.lanURL == nil && session.tailscaleURL == nil && session.authKey == nil, "Session shutdown clears servers/URLs/key")
    try await mobileGuideLoopbackSelfTest()
    print("PASS: Mobile candidates, selected-peer path, LAN/Tailscale separation, token/expiry/read-only routing and secret-free bilingual guide")
}

private func mobileGuideLoopbackSelfTest() async throws {
    let server = MobileGuideServer()
    defer { server.stop() }
    let token = "loopback-selftest-session"
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        let once = GuidePortContinuation(continuation)
        do {
            try server.start(address: "127.0.0.1", token: token, expires: Date().addingTimeInterval(4), page: { _ in "loopback guide" }, visited: { _ in }, ready: { once.finish(.success($0)) }, failed: { once.finish(.failure(TailscaleFailure.invalid("Loopback listener failed"))) })
        } catch { once.finish(.failure(error)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish(.failure(TailscaleFailure.timeout)) }
    }
    let response = try await guideRequest(port: port, path: "/" + token)
    try tsRequire(response.contains("200 OK") && response.hasSuffix("loopback guide") && response.contains("script-src 'sha256-" + MacAccessPage.scriptHash + "'"), "Real loopback binding and HTTP response")
    let missing = try await guideRequest(port: port, path: "/not-a-session")
    try tsRequire(missing.contains("404 Not Found") && !missing.contains("loopback guide"), "Real server denies unrelated path")
    print("PASS: guide server binds only requested loopback address and serves allowed read-only path")
}
private final class GuidePortContinuation: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) { lock.lock(); let callback = continuation; continuation = nil; lock.unlock(); callback?.resume(with: result) }
}
private func guideRequest(port: UInt16, path: String) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "RetroStats.guide.selftest")
    return try await withCheckedThrowingContinuation { continuation in
        let capture = GuideResponseContinuation(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), completion: .contentProcessed { error in
                    if let error { capture.finish(.failure(error)); connection.cancel(); return }
                    capture.receive(connection)
                })
            case .failed(let error): capture.finish(.failure(error)); connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { capture.finish(.failure(TailscaleFailure.timeout)); connection.cancel() }
    }
}
private final class GuideResponseContinuation: @unchecked Sendable {
    let lock = NSLock(); var data = Data()
    var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
            self.data.append(chunk ?? Data())
            if let error { self.finish(.failure(error)); connection.cancel() }
            else if complete { self.finish(.success(String(decoding: self.data, as: UTF8.self))); connection.cancel() }
            else { self.receive(connection) }
        }
    }
    func finish(_ result: Result<String, Error>) { lock.lock(); let callback = continuation; continuation = nil; lock.unlock(); callback?.resume(with: result) }
}

private func installationFixtureSelfTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-install-selftest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Tailscale.app")
    let binary = app.appendingPathComponent("Contents/MacOS/Tailscale")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture never executed".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    try tsRequire(TailscaleInstallation.detect(appPaths: [app.path], cliPaths: [])?.variant == .standalone, "Standalone bundle detection")
    let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
    try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture receipt".utf8).write(to: receipt)
    try tsRequire(TailscaleInstallation.detect(appPaths: [app.path], cliPaths: [])?.variant == .appStore, "App Store receipt detection")
    let launcher = root.appendingPathComponent("launcher")
    try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
    try tsRequire(TailscaleInstallation.detect(appPaths: [], cliPaths: [launcher.path])?.variant == .appStore, "Launcher resolves its GUI distribution")
    let cli = root.appendingPathComponent("tailscale")
    try Data("fixture never executed".utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    try tsRequire(TailscaleInstallation.detect(appPaths: [], cliPaths: [cli.path])?.variant == .cli, "CLI-only detection")
    try tsRequire(TailscaleInstallation.detect(appPaths: [], cliPaths: []) == nil, "Missing installation detection")
}

@MainActor private func mobileAdminFixtureSelfTest(status: Data, defaults: UserDefaults) async throws {
    let devices = Data(#"{"devices":[{"id":"device-one","nodeId":"new-one","name":"My iPhone","os":"iOS","authorized":false,"addresses":["100.64.0.10"]},{"id":"device-two","nodeId":"new-two","name":"My iPad","os":"iOS","authorized":false,"addresses":["100.64.0.11"]}]}"#.utf8)
    let approved = Data(String(decoding: devices, as: UTF8.self).replacingOccurrences(of: "\"authorized\":false,\"addresses\":[\"100.64.0.10\"]", with: "\"authorized\":true,\"addresses\":[\"100.64.0.10\"]").utf8)
    let ok = TailscaleAPIResponse(data: Data("{}".utf8), status: 200, etag: nil)
    let before = TailscaleAPIResponse(data: devices, status: 200, etag: nil)
    let after = TailscaleAPIResponse(data: approved, status: 200, etag: nil)
    let transport = FixtureAPITransport([before, before, ok, after, after])
    let mobile = MobileSetupSession(factory: { FixtureGuide() }, findLAN: { "192.0.2.10" })
    let executor = TailscaleFixtureExecutor(state: status)
    let controller = TailscaleController(executor: executor, detect: { .init(executable: "/fixture/tailscale", appPath: nil, variant: .standalone) }, store: FixtureCredentials(), mobile: mobile, defaults: defaults, makeAPI: { TailscaleAdminAPI(tailnet: $0, credential: $1, transport: transport) })
    await controller.refresh()
    controller.connectAPI(tailnet: "example.test", credential: "test-placeholder")
    while controller.busy { try await Task.sleep(for: .milliseconds(5)) }
    controller.startMobile()
    try tsRequire(mobile.candidates.contains(where: { $0.id == "new-one" && $0.approvalPending }) && mobile.selectedID == nil, "API discovers pending mobile devices without selecting them")
    mobile.selectedID = "new-one"; controller.approveMobile()
    while controller.busy { try await Task.sleep(for: .milliseconds(5)) }
    let approvals = await transport.requests.filter { $0.url?.path.hasSuffix("/authorized") == true }
    try tsRequire(approvals.count == 1 && approvals[0].url?.path == "/api/v2/device/device-one/authorized", "Only explicitly selected device is approved")
    try tsRequire(controller.adminDevices.first(where: { $0.id == "device-two" })?.authorized == false, "Unselected device remains pending")
    mobile.end()

    let keyResponse = TailscaleAPIResponse(data: Data(#"{"id":"test-key-id","key":"self-test-sensitive-marker"}"#.utf8), status: 200, etag: nil)
    let raceTransport = FixtureAPITransport([before, keyResponse, ok])
    await raceTransport.delayAuthKey(0.08)
    let raceMobile = MobileSetupSession(factory: { FixtureGuide() }, findLAN: { "192.0.2.10" })
    let race = TailscaleController(executor: executor, detect: { .init(executable: "/fixture/tailscale", appPath: nil, variant: .standalone) }, store: FixtureCredentials(), mobile: raceMobile, defaults: defaults, makeAPI: { TailscaleAdminAPI(tailnet: $0, credential: $1, transport: raceTransport) })
    await race.refresh(); race.connectAPI(tailnet: "example.test", credential: "test-placeholder")
    while race.busy { try await Task.sleep(for: .milliseconds(5)) }
    race.startMobile(); race.createMobileKey(preauthorized: false)
    try await Task.sleep(for: .milliseconds(15)); raceMobile.end(); race.startMobile()
    while race.busy { try await Task.sleep(for: .milliseconds(5)) }
    let requests = await raceTransport.requests
    try tsRequire(raceMobile.authKey == nil && requests.contains(where: { $0.httpMethod == "DELETE" && $0.url?.path.hasSuffix("/test-key-id") == true }), "Key returned to a cancelled/replaced session is revoked and never shown")
    raceMobile.end()
}

private struct FixtureAccessProbe: MacAccessProbing {
    var delay: TimeInterval = 0
    func check(host: String, services: [TailscaleService]) async -> [MacAccessService] {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return services.map { .init(service: $0, reachable: ["ssh", "smb"].contains($0.scheme), localOnly: $0.scheme == "http") }
    }
}
private final class FixtureAccessServer: MobileGuideServing {
    let port: UInt16
    var address = "", token = "", expires = Date.distantPast, stopped = false
    var visited: ((String) -> Void)?, failed: (() -> Void)?, page: ((String) -> String)?
    init(port: UInt16) { self.port = port }
    func start(address: String, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void, failed: @escaping () -> Void) throws {
        self.address = address; self.token = token; self.expires = expires; self.page = page; self.visited = visited; self.failed = failed; ready(port)
    }
    func stop() { stopped = true }
}

@MainActor private func macAccessSelfTest(snapshot: TailscaleSnapshot) async throws {
    let suite = "RetroStats.MyMac.selftest." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FixtureCredentials()
    var servers: [FixtureAccessServer] = []
    let factory: (UInt16) -> any MobileGuideServing = { port in let server = FixtureAccessServer(port: port); servers.append(server); return server }
    let access = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    try tsRequire(!access.enabled && servers.isEmpty && store.value == nil, "Access opt-in performs no listener/Keychain operations")
    try access.enable()
    await access.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    let original = access.url
    try tsRequire(access.phase == .ready && original != nil && servers.count == 1 && servers[0].address == snapshot.local?.address && servers[0].expires == .distantFuture, "Persistent server exact tail address / fixed port / no setup expiry")
    try tsRequire(defaults.data(forKey: "macAccessRecord").map { !String(decoding: $0, as: UTF8.self).contains(store.value!) } == true, "Hub token kept outside preferences")
    try tsRequire(servers[0].page?("100.64.0.2").contains("smb://") == true && servers[0].page?("100.64.0.3").contains("smb://") == false && servers[0].page?("192.0.2.10").contains("smb://") == false, "Service hub content requires a known same-owner mobile source, not just possession of its link")
    servers[0].visited?("100.64.0.3")
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(access.mobileName.isEmpty && access.identificationNeeded, "Other owner/tagged peer cannot be identified as own phone")
    servers[0].visited?("100.64.0.2")
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(access.mobileName == "My iPhone" && !access.identificationNeeded, "Observed source automatically identifies one own iOS peer")
    var ambiguous = snapshot; ambiguous.peers.append(snapshot.peers.first { $0.id == "a" }!)
    try tsRequire(MacAccessIdentity.match(remote: "100.64.0.2", snapshot: ambiguous) == nil, "Duplicate source identity requires explicit resolution")
    var missingOwner = snapshot; missingOwner.local?.userID = ""
    try tsRequire(MacAccessIdentity.match(remote: "100.64.0.2", snapshot: missingOwner) == nil, "Unknown owner cannot verify an own phone")
    for lang in SetupLanguage.allCases {
        let html = MacAccessPage.hub(language: lang, host: snapshot.local!.address, services: access.services)
        try tsRequire(html.contains("smb://") && html.contains("ssh://") && !html.contains("vnc://") && !html.contains(":8080") && !html.contains(store.value!), "Only prepared services are actionable; no link token or credentials in page body")
    }
    let beforeWake = servers.count
    access.wake(); await access.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(access.url == original && servers.count == beforeWake + 1 && servers[0].stopped, "Wake rebind preserves bookmark and closes old listener")
    access.stop()
    let restarted = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    restarted.restore(); await restarted.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(restarted.url == original && restarted.phase == .ready, "Restart restores same endpoint and token")
    let savedRecord = defaults.data(forKey: "macAccessRecord"), savedToken = store.value
    let interactiveReads = store.interactiveReads, serverCount = servers.count
    store.backgroundReadDenied = true
    let protected = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    protected.restore(); await protected.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try tsRequire(protected.phase == .conflict && servers.count == serverCount && store.interactiveReads == interactiveReads && store.backgroundReads >= 3, "Startup and polling fail closed without interactive Keychain reads")
    try tsRequire(defaults.data(forKey: "macAccessRecord") == savedRecord && store.value == savedToken, "Denied background Keychain access preserves the saved link and token")
    store.backgroundReadDenied = false
    print("PASS: protected saved-link restoration and polling use noninteractive credentials and preserve state on denial")
    let currentServer = servers.last!
    currentServer.failed?(); try await Task.sleep(for: .milliseconds(10))
    try tsRequire(restarted.phase == .conflict && currentServer.stopped && restarted.url == original, "Port failure preserves saved link instead of silently changing it")
    await restarted.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(restarted.phase == .ready && restarted.url == original, "Saved port retries")
    var signedOut = snapshot; signedOut.state = .signedOut
    await restarted.update(snapshot: signedOut, configured: TailscaleService.defaults)
    try tsRequire(restarted.phase == .login && servers.last!.stopped && restarted.services.isEmpty, "Authentication expiry shuts hub without reporting services ready")
    await restarted.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    var other = snapshot; other.account = "other@example.test"
    await restarted.update(snapshot: other, configured: TailscaleService.defaults)
    try tsRequire(restarted.phase == .accountChanged && servers.last!.stopped && !restarted.wantsConnection, "Account change never moves old bearer link into new account")
    let oldToken = store.value
    try restarted.reissue(); await restarted.update(snapshot: snapshot, configured: TailscaleService.defaults)
    try await Task.sleep(for: .milliseconds(10))
    try tsRequire(restarted.url != original && store.value != oldToken && !MobileGuideServer.allowedRequest("GET /\(oldToken!) HTTP/1.1", token: store.value!, now: Date(), expires: .distantFuture), "Reissue invalidates old bookmark and old token")
    restarted.pause()
    let paused = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    try tsRequire(!paused.wantsConnection && paused.phase == .paused, "Explicit disconnect persists and automatic retry respects it")
    restarted.disable()
    servers.last?.visited?("100.64.0.2"); try await Task.sleep(for: .milliseconds(10))
    try tsRequire(!restarted.enabled && restarted.url == nil && store.value == nil && defaults.data(forKey: "macAccessRecord") == nil && restarted.mobileName.isEmpty, "Off removes token/preferences; late visits cannot resurrect state")
    let offRestart = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    offRestart.restore(); try tsRequire(!offRestart.enabled, "Off stays off at next launch")
    let race = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe(delay: 0.04))
    try race.enable()
    let pending = Task { await race.update(snapshot: snapshot, configured: TailscaleService.defaults) }
    try await Task.sleep(for: .milliseconds(10)); race.disable(); await pending.value
    try tsRequire(race.services.isEmpty && race.url == nil && race.phase == .off, "Probe completion cannot resurrect disabled hub")
    try tsRequire(TailscaleInstaller.packageURL(index: "evil.pkg Tailscale-1.102.4-macos.pkg")?.host == "pkgs.tailscale.com" && TailscaleInstaller.packageURL(index: "evil.pkg") == nil, "Installer source constrained to official package pattern")
    try tsRequire(TailscaleInstaller.validSignature("Status: signed by a certificate trusted by macOS\nDeveloper ID Installer: Tailscale Inc. (W5364U7YZB)") && !TailscaleInstaller.validSignature("Developer ID Installer: Someone else"), "Installer requires trusted Tailscale team signature")
    let developerIDSignature = """
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Certificate Chain:
        1. Developer ID Installer: Tailscale Inc. (W5364U7YZB)
    """
    try tsRequire(TailscaleInstaller.validSignature(developerIDSignature), "Installer accepts actual macOS 26 pkgutil Developer ID output")
    try tsRequire(!TailscaleInstaller.validSignature(developerIDSignature.replacingOccurrences(of: "W5364U7YZB", with: "WRONGTEAM1")), "Installer rejects a different signing team")
    try tsRequire(!TailscaleInstaller.validSignature(developerIDSignature.replacingOccurrences(of: "Apple for distribution", with: "Apple for distribution (revoked)")), "Installer rejects an unrecognized or revoked signature status")
    try tsRequire(!TailscaleInstaller.validSignature(developerIDSignature.replacingOccurrences(of: "signed by a developer certificate issued by Apple for distribution", with: "signed by an untrusted certificate")), "Installer rejects an untrusted certificate even with the Tailscale identity")
    try tsRequire(!TailscaleInstaller.validSignature(developerIDSignature.replacingOccurrences(of: "1. Developer ID Installer", with: "2. Developer ID Installer")), "Installer requires the Tailscale identity on the leaf certificate")
    let stoppedData = Data(#"{"BackendState":"Stopped","CurrentTailnet":{"Name":"example.test"},"Self":{"ID":"mac","UserID":1,"HostName":"Mac","TailscaleIPs":["100.64.0.1"]},"User":{"1":{"LoginName":"owner@example.test"}}}"#.utf8)
    let executor = TailscaleFixtureExecutor(state: stoppedData)
    let coordinated = MacAccessCoordinator(defaults: defaults, store: store, factory: factory, probe: FixtureAccessProbe())
    let controller = TailscaleController(executor: executor, detect: { .init(executable: "/fixture/tailscale", appPath: nil, variant: .standalone) }, store: FixtureCredentials(), defaults: defaults, access: coordinated)
    controller.beginAccess()
    try await Task.sleep(for: .milliseconds(100))
    let calls = await executor.calls
    try tsRequire(calls.contains(["up"]) && !calls.contains(where: { $0.last != "--help" && ["set", "funnel", "serve"].contains($0.first ?? "") }) && controller.snapshot.state == .connected && coordinated.phase == .ready, "Basic coordinator connects and reads back without routes/Exit Node/public sharing mutations")
    await executor.blockIncoming(); await controller.refresh()
    try await Task.sleep(for: .milliseconds(30))
    try tsRequire(coordinated.phase == .incomingBlocked && servers.last!.stopped, "Existing incoming block does not produce a ready hub")
    controller.allowAccessIncoming()
    try await Task.sleep(for: .milliseconds(100))
    let preservedRoutes = await executor.prefs["advertise-routes"] as? String
    try tsRequire(controller.preferences.bool("shields-up") == false && preservedRoutes == "10.1.0.0/24" && coordinated.phase == .ready, "Explicit incoming allowance changes one preference and preserves subnet advertisement")
    controller.connection(false)
    try await Task.sleep(for: .milliseconds(100)); controller.wake()
    try await Task.sleep(for: .milliseconds(20))
    let pausedCalls = await executor.calls
    try tsRequire(pausedCalls.filter { $0.first == "up" }.count == 1 && coordinated.phase == .paused, "Advanced disconnect is respected across wake without reconnect")
    coordinated.disable()
    let script = MacAccessPage.script
    try tsRequire(script.contains("setInterval(check") && script.contains("fetch(link.href") && !script.contains("m.checked=true") && script.contains("refreshHub"), "Browser uses real requests for setup and returning service refresh, no design timer completion")
    print("PASS: My Mac opt-in, source identity, service handoffs, persistent restart/wake, account/expiry/port conflict, reissue/off and stale probe (fixtures only)")
}
