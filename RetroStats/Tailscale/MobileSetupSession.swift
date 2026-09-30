import AppKit
import Foundation
import Network
import CoreImage.CIFilterBuiltins
import Darwin

protocol MobileGuideServing: AnyObject {
    func start(address: String, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void, failed: @escaping () -> Void) throws
    func stop()
}

final class MobileGuideServer: MobileGuideServing, @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    init(port: UInt16 = 0) { self.port = port }
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "RetroStats.MobileGuide")
    private var expiry: DispatchWorkItem?
    static func allowedRequest(_ text: String, token: String, now: Date, expires: Date) -> Bool {
        guard now < expires else { return false }
        let first = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        return first.count == 3 && first[0] == "GET" && first[1] == "/" + token && first[2] == "HTTP/1.1"
    }
    func start(address: String, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void, failed: @escaping () -> Void) throws {
        guard listener == nil, !address.isEmpty else { throw TailscaleFailure.invalid("Guide address unavailable") }
        let parameters = NWParameters.tcp
        let localPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: localPort)
        let listener = try NWListener(using: parameters, on: localPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: if let port = listener?.port { ready(port.rawValue) }
            case .failed: failed()
            case .waiting: failed()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 8 else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            connection.start(queue: self.queue)
            let deadline = DispatchWorkItem { [weak self] in connection.cancel(); self?.connections[id] = nil }
            self.queue.asyncAfter(deadline: .now() + 5, execute: deadline)
            self.receive(connection, id: id, data: Data(), token: token, expires: expires, page: page, visited: visited, deadline: deadline)
        }
        listener.start(queue: queue)
        let expiry = DispatchWorkItem { [weak self] in self?.stop() }
        self.expiry = expiry
        if expires != .distantFuture { queue.asyncAfter(deadline: .now() + max(0, expires.timeIntervalSinceNow), execute: expiry) }
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var buffer = data; buffer.append(chunk ?? Data())
            guard buffer.count <= 8192, error == nil else { connection.cancel(); self.connections[id] = nil; return }
            let request = String(decoding: buffer, as: UTF8.self)
            if !request.contains("\r\n\r\n"), !complete {
                self.receive(connection, id: id, data: buffer, token: token, expires: expires, page: page, visited: visited, deadline: deadline); return
            }
            let allowed = Self.allowedRequest(request, token: token, now: Date(), expires: expires)
            let remote: String
            if case .hostPort(let host, _) = connection.endpoint { remote = host.debugDescription } else { remote = "" }
            let body = allowed ? page(remote) : "Session unavailable"
            if allowed { visited(remote) }
            let status = allowed ? "200 OK" : "404 Not Found"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; font-src data:; script-src 'sha256-\(MacAccessPage.scriptHash)'; connect-src http:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in
                deadline.cancel(); connection.cancel(); self.connections[id] = nil
            })
        }
    }
    func stop() { queue.async { self.expiry?.cancel(); self.expiry = nil; self.listener?.cancel(); self.listener = nil; self.connections.values.forEach { $0.cancel() }; self.connections.removeAll() } }
    deinit { listener?.cancel(); expiry?.cancel() }
}

enum SetupLanguage: String, CaseIterable { case ko = "한국어", en = "English"
    static var system: Self { Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .ko : .en }
    func text(_ ko: String, _ en: String) -> String { self == .ko ? ko : en }
}

struct MobileGuideContent {
    var language: SetupLanguage
    var address: String, account: String, tailnet: String
    var services: [TailscaleService]
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;") }
    var sections: [(String, String)] {
        let t = language.text
        let host = address.isEmpty ? t("Mac 연결 후 주소가 표시됩니다", "Address appears after this Mac connects") : address
        let web = services.first { ["http", "https"].contains($0.scheme) }?.url(host: address)?.absoluteString ?? "http://\(host):8080"
        return [
            (t("1. 설치하고 연결하기", "1. Install and connect"), t("App Store에서 Tailscale을 설치하고 실행하세요. VPN 구성 추가를 허용한 다음 Mac과 같은 계정으로 로그인하세요. Mac 계정: \(account), 네트워크: \(tailnet). 인증키 방식은 Mac에서 직접 표시·복사한 키를 모바일 앱에 입력하세요. 키는 이 페이지에 포함되지 않습니다. 앱에서 Connected를 확인하세요. 로그인했지만 기기가 안 보이면 Mac에서 본인 기기를 선택하고 승인 대기 여부를 확인하세요.", "Install and open Tailscale from the App Store. Allow the VPN configuration and sign in with the same account as this Mac: \(account), tailnet: \(tailnet). For an auth key, enter the key explicitly displayed/copied on the Mac. No key is included in this page. Check Connected in the app. If the device is missing, select your own device on the Mac and check approval.")),
            (t("2. 실제 연결 확인", "2. Verify the connection"), t("같은 Wi-Fi의 안내 페이지는 등록 전 안내입니다. 연결 후에는 Mac 도우미에 표시된 Tailscale 주소 URL을 Safari에서 새로 여세요. Mac에 모바일 브라우저 접속이 확인되어야 실제 Mac 경로 확인입니다. Online이나 ping만으로 파일·웹 사용 성공이 확인되지는 않습니다. 실패하면 양쪽 VPN 연결, 기기 승인, 접근 정책과 Mac 방화벽을 확인하세요. 서로 다른 네트워크에서는 Mac 안내와 설치 QR로 먼저 등록하세요.", "The same-Wi-Fi guide is for setup. After connecting, open the Tailscale-address URL shown by the Mac helper in Safari. The Mac must observe that mobile browser request to verify this path. Online or ping alone does not verify file/web access. If it fails, check both VPNs, device approval, access policy and the Mac firewall. Across different networks, start with the Mac guide and official installation QR.")),
            (t("파일: Files 앱의 SMB", "Files: SMB in the Files app"), t("Mac에서 시스템 설정 → 일반 → 공유 → 파일 공유를 켜고 공유 폴더·사용자 및 SMB 옵션을 직접 선택하세요. iPhone/iPad의 파일 앱 → 둘러보기 → 더 보기 → 서버에 연결에 smb://\(host)를 입력하세요. Mac에서 허용한 사용자로 로그인합니다. 폴더 목록을 열고 테스트 파일을 읽으면 성공입니다. 실패하면 SMB 활성화, 공유 사용자·암호, 접근 정책의 TCP 445를 확인하세요. Mac 암호는 이 안내 페이지에 입력하지 마세요.", "On the Mac, open System Settings → General → Sharing → File Sharing, and select the shared folders, users and SMB options. In Files → Browse → More → Connect to Server, enter smb://\(host). Sign in as an allowed Mac user. Opening the folder and reading a test file verifies access. If it fails, check SMB, user/password and policy for TCP 445. Never enter your Mac password into this guide page.")),
            (t("웹: Safari", "Web: Safari"), t("Mac에 웹 서버를 먼저 실행하세요. Safari에서 \(web)를 엽니다. 원하는 서비스의 실제 페이지가 열리면 성공입니다. 이 안내 페이지가 열리는 것과는 별개입니다. 실패하면 서비스의 수신 주소·포트, 방화벽과 접근 정책을 확인하고 Mac의 서비스 바로가기에서 포트를 맞추세요.", "Start the web service on the Mac first, then open \(web) in Safari. Loading the intended service verifies access separately from this guide. If it fails, check the service bind address/port, firewall and policy, and set the correct port in the Mac service shortcuts.")),
            (t("SSH · 화면 공유", "SSH · Screen Sharing"), t("Mac 공유 설정에서 원격 로그인 또는 화면 공유를 켜고 허용 사용자를 선택하세요. iPhone/iPad의 SSH 앱에는 \(host):\(services.first(where: { $0.scheme == "ssh" })?.port ?? 22), VNC 화면 공유 앱에는 \(host):\(services.first(where: { $0.scheme == "vnc" })?.port ?? 5900)을 입력합니다. 셸 명령 또는 실제 Mac 화면을 확인해야 성공입니다. 호스트 키·인증·서비스 설정과 접근 정책을 확인하세요. macOS 원격 로그인과 Tailscale SSH 서버는 별도 기능입니다.", "Enable Remote Login or Screen Sharing in Mac Sharing settings and select allowed users. Enter \(host):\(services.first(where: { $0.scheme == "ssh" })?.port ?? 22) in an iPhone/iPad SSH app, or \(host):\(services.first(where: { $0.scheme == "vnc" })?.port ?? 5900) in a VNC app. Verify a shell command or the actual Mac screen. Check host keys, authentication, service settings and policy. macOS Remote Login and the Tailscale SSH server are separate features.")),
            (t("Taildrop 파일 보내기·받기", "Send and receive with Taildrop"), t("같은 사용자 소유이고 태그가 없는 기기끼리 사용합니다. 모바일 공유 메뉴에서 Tailscale과 Mac을 선택하세요. Mac에서는 Taildrop 받기로 저장 폴더를 선택합니다. 반대로 Mac의 기기 목록에서 파일 보내기를 선택하고 모바일 Tailscale 앱에서 받습니다. 수신된 파일을 열어 성공을 확인하세요. 대상이 없으면 소유 계정·태그·배포판 제한을 확인하세요.", "Use devices owned by the same user without tags. On mobile, select Tailscale and this Mac from the Share menu. On the Mac, choose a destination with Receive Taildrop. To send the other way, choose Send file from the Mac device list and receive in the mobile Tailscale app. Open the received file to verify success. If no target appears, check account ownership, tags and distribution restrictions.")),
            (t("인터넷 우회: Exit Node", "Route internet traffic: Exit Node"), t("Mac에서 Exit Node 제공을 명시적으로 켜고 관리자 라우트 승인을 받으세요. 모바일 Tailscale 앱에서 Exit Node → 이 Mac을 직접 선택합니다. 필요한 경우 모바일에서 LAN 접근을 허용하세요. 선택 전후 모바일 Safari로 외부 IP 확인 사이트를 열어 Mac의 외부 IP와 비교해야 우회 성공입니다. 해제는 모바일 앱에서 None을 선택하고 외부 IP를 다시 확인합니다. Wi-Fi에서 셀룰러로 전환해 반복 확인하세요. Mac이 잠들면 우회가 중단될 수 있습니다. 장애 시 자동으로 우회를 해제하지 않습니다.", "Explicitly enable this Mac as an Exit Node and get administrator route approval. In the mobile Tailscale app, select Exit Node → this Mac yourself; allow LAN access there if needed. Compare the mobile external IP before/after in Safari with the Mac external IP to verify routing. Select None on mobile to stop, then verify again. Repeat after switching Wi-Fi to cellular. Mac sleep can interrupt routing. Routing is never automatically disabled on failure."))]
    }
    var html: String {
        let title = language.text("iPhone·iPad와 Mac 연결", "Connect iPhone or iPad to this Mac")
        let sections = sections.map { "<section><h2>\(Self.escape($0.0))</h2><p>\(Self.escape($0.1))</p></section>" }.joined()
        return "<!doctype html><html lang='\(language == .ko ? "ko" : "en")'><meta name='viewport' content='width=device-width, initial-scale=1'><meta charset='utf-8'><title>\(title)</title><style>body{font:17px system-ui;line-height:1.7;max-width:680px;margin:auto;padding:22px;color:#18231c;background:#f4f4e9}section{border-top:1px solid #88998c;margin-top:24px}a{color:#14593c}p{overflow-wrap:anywhere}</style><h1>\(title)</h1><p>\(language.text("읽기 전용 · 15분 후 종료 · 자격 증명을 입력하지 마세요", "Read only · expires after 15 minutes · do not enter credentials"))</p><a href='https://apps.apple.com/app/tailscale/id1470499037'>\(language.text("공식 App Store 설치", "Official App Store installation"))</a>\(sections)</html>"
    }
}

@MainActor final class MobileSetupSession: ObservableObject {
    @Published var active = false
    @Published var language: SetupLanguage = .en { didSet { updatePage() } }
    @Published var lanURL: URL?
    @Published var tailscaleURL: URL?
    @Published var serverMessage = ""
    @Published var selectedID: String? { didSet { pathVerified = false; serviceVerified = false; exitVerified = false } }
    @Published var pathVerified = false
    @Published var serviceVerified = false
    @Published var exitVerified = false
    @Published var candidates: [TailscalePeer] = []
    @Published var keyVisible = false
    @Published private(set) var authKey: TailscaleAuthKey?
    var changed: (() -> Void)?
    private var expires: Date?
    private var initialIDs = Set<String>(), identity = "", localAddress = ""
    private var lastRemote = ""
    private var currentSnapshot = TailscaleSnapshot()
    @Published var identificationNeeded = false
    var accessURL: URL? { didSet { updatePage() } }
    private var lan: (any MobileGuideServing)?, tail: (any MobileGuideServing)?
    private var currentLAN = ""
    private let findLAN: () -> String?
    private let lifetime: TimeInterval
    private let factory: () -> any MobileGuideServing
    private(set) var sessionID = UUID()
    private var token = "", expiryTask: Task<Void, Never>?, keyTask: Task<Void, Never>?
    private var content = MobileGuideContent(language: .system, address: "", account: "", tailnet: "", services: TailscaleService.defaults)
    // The server queue never reads MainActor state. Only this locked, public guide is shared.
    private let page = MobileGuidePage()
    var onEnd: ((TailscaleAuthKey?) -> Void)?
    init(factory: @escaping () -> any MobileGuideServing = { MobileGuideServer() }, findLAN: @escaping () -> String? = { MobileSetupSession.lanAddress() }, lifetime: TimeInterval = 900) { self.factory = factory; self.findLAN = findLAN; self.lifetime = min(900, max(0, lifetime)) }
    func begin(snapshot: TailscaleSnapshot, services: [TailscaleService], adminDevices: [TailscaleAdminDevice] = []) {
        guard !active else { return }
        active = true; sessionID = UUID(); serverMessage = ""; pathVerified = false; serviceVerified = false; exitVerified = false; initialIDs = Set(snapshot.peers.map(\.id)); identity = snapshot.identity
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        expires = Date().addingTimeInterval(lifetime); content.services = services
        update(snapshot: snapshot, services: services, adminDevices: adminDevices)
        expiryTask = Task { try? await Task.sleep(for: .seconds(lifetime)); if !Task.isCancelled { end() } }
        changed?()
    }
    func update(snapshot: TailscaleSnapshot, services: [TailscaleService], adminDevices: [TailscaleAdminDevice] = []) {
        guard active else { return }
        // External account changes invalidate browser evidence and all outstanding secrets.
        if identity != snapshot.identity, !content.address.isEmpty { end(); return }
        identity = snapshot.identity
        currentSnapshot = snapshot
        candidates = snapshot.peers.filter { $0.mobile && !initialIDs.contains($0.id) }
        // Existing mobile devices remain explicitly selectable for reconnection.
        candidates += snapshot.peers.filter { $0.mobile && initialIDs.contains($0.id) }
        for device in adminDevices where ["ios", "ipados"].contains(device.os.lowercased()) {
            if let index = candidates.firstIndex(where: { $0.id == device.nodeID || $0.id == device.id || !Set($0.addresses).intersection(device.addresses).isEmpty }) {
                candidates[index].approvalPending = device.authorized == false
            } else {
                var peer = TailscalePeer.parse(["ID": device.nodeID.isEmpty ? device.id : device.nodeID, "HostName": device.name, "OS": device.os, "TailscaleIPs": device.addresses])
                peer.approvalPending = device.authorized == false; candidates.append(peer)
            }
        }
        if let selectedID, !candidates.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        content.address = snapshot.local?.address ?? ""; content.account = snapshot.account; content.tailnet = snapshot.tailnet; content.services = services
        if let peer = MacAccessIdentity.match(remote: lastRemote, snapshot: snapshot) { selectedID = peer.id; pathVerified = true; identificationNeeded = false }
        updatePage()
        let address = findLAN() ?? ""
        if address != currentLAN {
            lan?.stop(); lan = nil; lanURL = nil; currentLAN = address
            if !address.isEmpty { lan = start(address: address, isTail: false) }
            else { serverMessage = language.text("LAN 주소가 없습니다. Mac 안내와 공식 설치 QR을 사용하세요.", "No LAN address. Use the Mac guide and official installation QR.") }
        }
        if content.address != localAddress {
            tail?.stop(); tail = nil; tailscaleURL = nil; pathVerified = false; localAddress = content.address
            if !localAddress.isEmpty { tail = start(address: localAddress, isTail: true) }
        }
    }
    private func updatePage() { content.language = language; page.set(MacAccessPage.setup(language: language, account: content.account, accessURL: accessURL)) }
    private func start(address: String, isTail: Bool) -> any MobileGuideServing {
        let server = factory(); let page = self.page; let token = self.token
        do {
            try server.start(address: address, token: token, expires: expires ?? Date(), page: { _ in page.get() }, visited: { [weak self] remote in
                Task { @MainActor in
                    guard let self, self.active, self.token == token, isTail else { return }
                    self.lastRemote = remote
                    if let peer = MacAccessIdentity.match(remote: remote, snapshot: self.currentSnapshot) {
                        self.selectedID = peer.id; self.pathVerified = true; self.identificationNeeded = false
                    } else { self.identificationNeeded = true }
                }
            }, ready: { [weak self] port in
                Task { @MainActor in
                    guard let self, self.active, self.token == token, address == (isTail ? self.localAddress : self.currentLAN) else { return }
                    var parts = URLComponents(); parts.scheme = "http"; parts.host = address; parts.port = Int(port); parts.path = "/" + token
                    if isTail { self.tailscaleURL = parts.url } else { self.lanURL = parts.url }
                }
            }, failed: { [weak self] in
                Task { @MainActor in
                    guard let self, self.active, self.token == token else { return }
                    self.serverMessage = self.language.text("안내에 접근할 수 없습니다. 시스템 설정의 로컬 네트워크 권한·방화벽을 확인하고 Mac 안내와 설치 QR을 사용하세요.", "Guide unavailable. Check Local Network permission / firewall in System Settings; use the Mac guide and installation QR.")
                }
            })
        } catch { serverMessage = language.text("안내 주소를 열 수 없습니다. 네트워크·권한을 확인하고 Mac 안내를 사용하세요.", "Guide could not bind this address. Check permissions and the network; use the Mac guide.") }
        return server
    }
    func selectMobile(_ id: String) {
        selectedID = id
        if let peer = currentSnapshot.peers.first(where: { $0.id == id }), peer.mobile, currentSnapshot.canTaildrop(to: peer), !peer.approvalPending, peer.addresses.contains(lastRemote) { pathVerified = true; identificationNeeded = false }
    }
    func holdKey(_ key: TailscaleAuthKey) {
        guard active else { return }
        authKey = key; keyVisible = false; keyTask?.cancel()
        let duration = max(0, key.expires.timeIntervalSinceNow)
        keyTask = Task { try? await Task.sleep(for: .seconds(duration)); if !Task.isCancelled { clearKey() } }
    }
    private func clearKey() {
        if let key = authKey, NSPasteboard.general.string(forType: .string) == key.secret { NSPasteboard.general.clearContents() }
        authKey = nil; keyVisible = false
    }
    func end() {
        guard active else { return }
        active = false; expiryTask?.cancel(); keyTask?.cancel(); lan?.stop(); tail?.stop(); lan = nil; tail = nil
        lanURL = nil; tailscaleURL = nil; token = ""; lastRemote = ""; identificationNeeded = false; expires = nil; localAddress = ""; currentLAN = ""; selectedID = nil; candidates = []
        let key = authKey; clearKey(); onEnd?(key); changed?()
    }
    var guide: MobileGuideContent { content }
    static func preview(snapshot: TailscaleSnapshot, services: [TailscaleService], language: SetupLanguage) -> MobileSetupSession {
        let session = MobileSetupSession()
        session.language = .en
        session.content = .init(language: .en, address: snapshot.local?.address ?? "", account: snapshot.account, tailnet: snapshot.tailnet, services: services)
        session.candidates = snapshot.peers.filter(\.mobile)
        return session
    }
    static func qr(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: output.extent.applying(CGAffineTransform(scaleX: 5, y: 5))) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 180, height: 180))
    }
    nonisolated static func lanAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var item = interfaces
        while let current = item {
            let interface = current.pointee; item = interface.ifa_next
            guard String(cString: interface.ifa_name).hasPrefix("en"), (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
final class MobileGuidePage: @unchecked Sendable {
    private let lock = NSLock(); private var html = ""
    func set(_ value: String) { lock.lock(); html = value; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return html }
}
