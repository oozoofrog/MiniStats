import AppKit
import Foundation
import CryptoKit

/// This record has no credentials. The bearer link token lives in a separate Keychain item.
struct MacAccessRecord: Codable, Equatable {
    var port: UInt16 = 49182
    var identity = ""
    var host = ""
    var address = ""
    var paused = false
}

enum MacAccessIdentity {
    static func match(remote: String, snapshot: TailscaleSnapshot) -> TailscalePeer? {
        guard let local = snapshot.local, !local.userID.isEmpty, local.userID != "0", local.tags.isEmpty else { return nil }
        let matches = snapshot.peers.filter { $0.mobile && $0.tags.isEmpty && $0.userID == local.userID && !$0.approvalPending && $0.addresses.contains(remote) }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct MacAccessService: Identifiable, Equatable {
    let service: TailscaleService
    var reachable: Bool
    var localOnly: Bool
    var id: String { service.id }
    func action(host: String) -> URL? { reachable ? service.url(host: host) : nil }
}

@MainActor final class MacAccessCoordinator: ObservableObject {
    enum Phase: String { case off = "Not enabled", preparing = "Preparing", install = "Install required", login = "Sign in required", approval = "Approval required", deviceApproval = "Device approval required", ready = "Mac ready", unavailable = "Retrying", conflict = "Link unavailable", accountChanged = "Account changed", paused = "Paused", incomingBlocked = "Access permission required" }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var enabled = false
    @Published private(set) var url: URL?
    @Published private(set) var message = ""
    @Published private(set) var mobileName = ""
    @Published private(set) var identificationNeeded = false
    @Published private(set) var services: [MacAccessService] = []
    @Published var language: SetupLanguage = .en { didSet { updatePage() } }
    var changed: (() -> Void)?
    private let defaults: UserDefaults
    private let store: any TailscaleCredentialStore
    private let factory: (UInt16) -> any MobileGuideServing
    private let probe: any MacAccessProbing
    private let page = MacAccessIdentityPage()
    private var record: MacAccessRecord?
    private var token = "", bound = "", lastRemote = ""
    private var server: (any MobileGuideServing)?
    private var generation = 0
    private var latest = TailscaleSnapshot()
    private var lastProbe = -Double.infinity
    private var selectedMobileID: String?
    private var probing = false
    private var interactive = true
    private var serverReady = false
    private(set) var reconnectAfter = -Double.infinity
    var wantsConnection: Bool { enabled && record?.paused != true && phase != .accountChanged }
    init(defaults: UserDefaults, store: any TailscaleCredentialStore = TailscaleKeychain(service: "RetroStats.MyMac", account: "hub-link"), factory: @escaping (UInt16) -> any MobileGuideServing = { MobileGuideServer(port: $0) }, probe: any MacAccessProbing = MacAccessProbe()) {
        self.defaults = defaults; self.store = store; self.factory = factory; self.probe = probe
        record = defaults.data(forKey: "macAccessRecord").flatMap { try? JSONDecoder().decode(MacAccessRecord.self, from: $0) }
        enabled = record != nil
        if enabled { phase = record?.paused == true ? .paused : .preparing }
    }
    private func persist() { if let record, let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: "macAccessRecord") } else { defaults.removeObject(forKey: "macAccessRecord") } }
    func enable() throws {
        if record == nil { let value = Self.newToken(); try store.write(value); record = MacAccessRecord(); token = value }
        if token.isEmpty { guard let saved = try store.read(), Self.validToken(saved) else { throw TailscaleFailure.credential }; token = saved }
        record?.paused = false; enabled = true; phase = .preparing; persist(); changed?()
    }
    static func newToken() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    static func validToken(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
    func restore() {
        guard enabled, record?.paused != true else { return }
        do { guard let saved = try store.readWithoutInteraction(), Self.validToken(saved) else { throw TailscaleFailure.credential }; token = saved; changed?() }
        catch { phase = .conflict; message = "Saved access link needs Keychain access. Continue setup to approve it, or reissue the link." }
    }
    func disable() {
        stop(); enabled = false; record = nil; persist(); token = ""; url = nil; services = []; mobileName = ""; phase = .off
        do { try store.remove(); message = "" } catch { message = "Link disabled. Keychain cleanup failed; reissue before enabling again." }
        changed?()
    }
    func reissue() throws {
        stop(); token = Self.newToken(); try store.write(token)
        record = MacAccessRecord(port: UInt16.random(in: 49152...65535)); enabled = true; url = nil; mobileName = ""; identificationNeeded = false; phase = .preparing; persist(); changed?()
    }
    func pause() { stop(); record?.paused = true; persist(); phase = enabled ? .paused : .off; changed?() }
    func stop() { generation += 1; services = []; lastProbe = -Double.infinity; mobileName = ""; identificationNeeded = false; lastRemote = ""; selectedMobileID = nil; server?.stop(); server = nil; bound = ""; serverReady = false }
    func blockIncoming() { stop(); phase = .incomingBlocked; message = "Allow incoming access to continue." }
    func wake() { stop(); lastProbe = -Double.infinity; if wantsConnection { phase = .preparing } }
    func shouldReconnect() -> Bool {
        guard wantsConnection, ProcessInfo.processInfo.systemUptime >= reconnectAfter else { return false }
        reconnectAfter = ProcessInfo.processInfo.systemUptime + 30; return true
    }
    func update(snapshot: TailscaleSnapshot, configured: [TailscaleService]) async {
        guard enabled else { return }
        latest = snapshot
        if record?.paused == true { phase = .paused; return }
        if token.isEmpty {
            do { guard let saved = try store.readWithoutInteraction(), Self.validToken(saved) else { throw TailscaleFailure.credential }; token = saved }
            catch { phase = .conflict; message = "Saved access link needs Keychain access. Continue setup to approve it, or reissue the link."; return }
        }
        if let identity = record?.identity, !identity.isEmpty, snapshot.local != nil, !snapshot.account.isEmpty, identity != snapshot.identity {
            stop(); services = []; mobileName = ""; phase = .accountChanged; message = "This link belongs to another Mac account. Reissue it to use the current account."; return
        }
        guard snapshot.state == .connected, let local = snapshot.local, !local.address.isEmpty else {
            stop(); services = []; mobileName = ""
            switch snapshot.state {
            case .notInstalled: phase = .install
            case .signedOut: phase = .login
            case .extensionApproval: phase = .approval
            case .deviceApproval: phase = .deviceApproval
            default: phase = .unavailable
            }
            updatePage(); return
        }
        if record?.identity.isEmpty == true {
            record?.identity = snapshot.identity
            record?.address = local.address
            record?.host = local.address // Numeric endpoint also works when the mobile client does not accept MagicDNS.
            persist()
        }
        // If a numeric address changes, never keep an endpoint that now identifies another node.
        if let record, record.host == record.address, record.address != local.address {
            self.record?.host = local.address; self.record?.address = local.address; persist()
            message = "Mac address changed. Save the updated access link."
        }
        guard let record else { return }
        url = URL(string: "http://\(record.host.contains(":") ? "[\(record.host)]" : record.host):\(record.port)/\(token)")
        if bound != local.address || server == nil {
            stop(); bound = local.address
            let generation = self.generation, token = self.token
            let server = factory(record.port); self.server = server; let page = self.page
            do {
                try server.start(address: local.address, token: token, expires: .distantFuture, page: { page.get(remote: $0) }, visited: { [weak self] remote in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.lastRemote = remote
                        if let peer = MacAccessIdentity.match(remote: remote, snapshot: self.latest) { self.mobileName = peer.name; self.identificationNeeded = false }
                        else { self.identificationNeeded = true }
                    }
                }, ready: { [weak self] actualPort in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        guard actualPort == record.port else { self.stop(); self.phase = .conflict; self.message = "Saved port was not bound. Reissue the link."; return }
                        self.serverReady = true; self.phase = .ready; self.message = ""; self.updatePage()
                    }
                }, failed: { [weak self] in
                    Task { @MainActor in guard let self, self.generation == generation else { return }; self.stop(); self.phase = .conflict; self.message = "Access link could not start. Retrying the saved port; reissue the link if another app uses it, or allow RetroStats through the firewall." }
                })
            } catch { stop(); phase = .conflict; message = "Access link could not bind its saved address/port. Reissue the link or check the firewall." }
        }
        if serverReady { phase = .ready }
        if let peer = MacAccessIdentity.match(remote: lastRemote, snapshot: snapshot) { mobileName = peer.name; identificationNeeded = false }
        if !probing && (ProcessInfo.processInfo.systemUptime - lastProbe >= 15 || services.map(\.service) != configured) {
            probing = true; let generation = self.generation
            let results = await probe.check(host: local.address, services: configured)
            probing = false
            if generation == self.generation && !Task.isCancelled { services = results; lastProbe = ProcessInfo.processInfo.systemUptime }
        }
        updatePage()
    }
    private func updatePage() {
        var addresses = Set(latest.peers.flatMap(\.addresses).filter { MacAccessIdentity.match(remote: $0, snapshot: latest) != nil })
        if let selectedMobileID, let peer = latest.peers.first(where: { $0.id == selectedMobileID }), peer.mobile, latest.canTaildrop(to: peer), !peer.approvalPending { addresses.formUnion(peer.addresses) }
        page.set(MacAccessPage.hub(language: .en, host: record?.host ?? latest.local?.address ?? "", services: services), addresses: addresses)
    }
    func selectMobile(_ id: String) {
        guard let peer = latest.peers.first(where: { $0.id == id }), peer.mobile, latest.canTaildrop(to: peer), !peer.approvalPending, peer.addresses.contains(lastRemote) else { return }
        mobileName = peer.name; selectedMobileID = id; identificationNeeded = false; updatePage()
    }
    func selectPurpose(_ scheme: String) { guard interactive else { return }; if ["smb", "vnc", "ssh"].contains(scheme) { openSharingSettings() } }
    static func preview(snapshot: TailscaleSnapshot, services: [TailscaleService], defaults: UserDefaults, observedMobile: Bool = false) -> MacAccessCoordinator {
        let access = MacAccessCoordinator(defaults: defaults)
        access.interactive = false; access.enabled = true
        switch snapshot.state {
        case .connected: access.phase = .ready
        case .notInstalled: access.phase = .install
        case .signedOut: access.phase = .login
        case .extensionApproval: access.phase = .approval
        case .deviceApproval: access.phase = .deviceApproval
        default: access.phase = .unavailable
        }
        access.latest = snapshot; access.mobileName = observedMobile && snapshot.state == .connected ? snapshot.peers.first?.name ?? "" : ""
        access.url = URL(string: "http://100.64.0.1:49182/fixture-link")
        access.services = services.map { .init(service: $0, reachable: $0.scheme != "vnc", localOnly: false) }
        return access
    }
}

struct MacAccessPage {
    static let script = """
    const steps=[...document.querySelectorAll('[data-step]')];
    let step=0, checking=false;
    function show(n){step=n;steps.forEach((el,i)=>el.hidden=i!==n);const back=document.querySelector('[data-back]');if(back)back.hidden=n===0;document.querySelector('[data-step-title]')?.focus();}
    document.querySelectorAll('[data-next]').forEach(el=>el.addEventListener('click',()=>show(Math.min(3,step+1))));
    document.querySelector('[data-back]')?.addEventListener('click',()=>show(Math.max(0,step-1)));
    async function check(){
      const link=document.querySelector('[data-access]');if(!link||checking)return;
      checking=true;const c=new AbortController(),timeout=setTimeout(()=>c.abort(),4500);
      try{await fetch(link.href,{mode:'no-cors',cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer',signal:c.signal});location.replace(link.href);}
      catch(e){if(step===3){document.querySelector('[data-check-title]').textContent='Not Connected';document.querySelector('[data-check-copy]').textContent='Open Tailscale and keep your Mac awake.';document.querySelector('[data-retry]').hidden=false;}}
      finally{clearTimeout(timeout);checking=false;}
    }
    document.querySelector('[data-retry]')?.addEventListener('click',check);
    function bindCopy(){document.querySelectorAll('[data-copy]').forEach(button=>button.addEventListener('click',()=>{const input=button.parentElement.querySelector('input');input.focus();input.select();input.setSelectionRange(0,input.value.length);try{if(document.execCommand('copy'))button.textContent='Copied';else button.textContent='Long press to copy';}catch(e){button.textContent='Long press to copy';}}));}bindCopy();
    if(steps.length){show(0);setInterval(check,7000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)check()});check();}
    else if(document.querySelector('.ready-list')){
      let refreshing=false;
      async function refreshHub(){if(refreshing||document.hidden)return;refreshing=true;const c=new AbortController(),timeout=setTimeout(()=>c.abort(),4500);const list=document.querySelector('.ready-list'),status=document.querySelector('[data-path-status]');
        try{const response=await fetch(location.href,{cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer',signal:c.signal});if(!response.ok)throw new Error('unavailable');const nextDoc=new DOMParser().parseFromString(await response.text(),'text/html'),next=nextDoc.querySelector('.ready-list');document.querySelector('h1').textContent=nextDoc.querySelector('h1').textContent;document.title=nextDoc.title;if(!next)throw new Error('unavailable');const open=new Set([...list.querySelectorAll('details[open]')].map(el=>el.dataset.service));list.replaceChildren(...next.childNodes);list.querySelectorAll('details').forEach(el=>el.open=open.has(el.dataset.service));list.hidden=false;status.textContent='';bindCopy();}
        catch(e){list.hidden=true;status.textContent='Not Connected. Wake your Mac and open Tailscale.';}
        finally{clearTimeout(timeout);refreshing=false;}
      }
      setInterval(refreshHub,10000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshHub()});
    }
    """
    static var scriptHash: String { Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString() }
    private static let font: String = {
        guard let url = Bundle.main.url(forResource: "RetroBitmapA", withExtension: "ttf", subdirectory: "Fonts") ?? Bundle.main.url(forResource: "RetroBitmapA", withExtension: "ttf"), let data = try? Data(contentsOf: url) else { return "" }
        return "@font-face{font-family:RetroBitmap;src:url(data:font/ttf;base64," + data.base64EncodedString() + ") format('truetype')}"
    }()
    static func document(language: SetupLanguage, title: String, body: String) -> String {
        """
        <!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='apple-mobile-web-app-capable' content='yes'><title>\(MobileGuideContent.escape(title))</title><style>
        \(font)
        :root{color-scheme:light dark}body{font:14px RetroBitmap,monospace;line-height:24px;max-width:680px;margin:auto;padding:20px;background:#faf9f5;color:#242623}h1,h2{font-weight:400;line-height:1.35}h1{font-size:22px}h2{font-size:22px}section,details{border-top:1px solid #8a998f;margin-top:22px;padding-top:14px}a,button{color:inherit}input{box-sizing:border-box;width:100%;font:14px monospace;padding:12px}p{overflow-wrap:anywhere}button,.action{display:inline-block;box-sizing:border-box;border:1px solid currentColor;padding:12px 16px;min-height:44px;background:transparent;font:inherit;text-decoration:none}:focus-visible{outline:2px solid currentColor;outline-offset:3px}svg{max-width:100%;height:auto;image-rendering:pixelated;shape-rendering:crispEdges}.icon svg{width:33px;height:33px;vertical-align:middle;margin-right:12px}.ready-list{display:grid;gap:16px}summary{cursor:pointer;min-height:44px}.account{overflow-wrap:anywhere;border:1px solid #8a998f;padding:12px}[hidden]{display:none!important}@media(min-width:600px){.ready-list{grid-template-columns:1fr 1fr}.setup-layout{display:grid;grid-template-columns:240px 1fr;gap:24px}}@media(prefers-color-scheme:dark){body{background:#20211f;color:#e9eae3}}
        </style><h1>\(MobileGuideContent.escape(title))</h1><main aria-live='polite'>\(body)</main><script>\(script)</script></html>
        """
    }
    static func setup(language: SetupLanguage, account: String, accessURL: URL?) -> String {
        let e = MobileGuideContent.escape, app = "https://apps.apple.com/app/tailscale/id1470499037"
        let labels = ["Get the App", "Sign In", "Allow Connection", "Checking..."]
        let copy = ["Install Tailscale on this phone or iPad.", "Use the same Tailscale account as your Mac.", "Allow Tailscale to add a VPN configuration.", "Looking for your Mac."]
        let scenes: [MacAccessArt] = [.get, .signIn, .allow, .check]
        var body = ""
        for i in 0...3 {
            body += "<section data-step='\(i)' \(i == 0 ? "" : "hidden")><p>Guide \(i + 1) / 4</p><div class='setup-layout'><div>\(scenes[i].svg)</div><div><h2 \(i == 3 ? "data-check-title" : "") tabindex='-1' data-step-title>\(labels[i])</h2><p \(i == 3 ? "data-check-copy" : "")>\(copy[i])</p>"
            if i == 1 { body += "<div class='account'>Sign-in account<br>\(e(account))</div>" }
            if i < 3 { body += "<p><a class='action' data-next target='_blank' rel='noreferrer' href='\(app)'>\(i == 0 ? "Get Tailscale" : "Open Tailscale")</a></p>" }
            else { body += "<button data-retry hidden>Try Again</button>" }
            body += "</div></div></section>"
        }
        body += "<p><button data-back>Back</button></p>"
        body += "<details><summary>Help</summary>"
        if let accessURL { body += "<p><a data-access href='\(e(accessURL.absoluteString))'>Open My Mac</a></p>" }
        body += "<p>The app and macOS show their own approval screens. Return here after allowing VPN; we check automatically.</p><p>If a browser blocks the automatic check, use Open My Mac after connecting.</p><p>This setup page expires after 15 minutes. Save My Mac once it opens.</p></details>"
        return document(language: .en, title: "My Mac Setup", body: body)
    }
    static var unverified: String {
        document(language: .en, title: "Checking This Device", body: "<p>Waiting for this device's identity.</p><p data-path-status role='status'></p><div class='ready-list'></div><details><summary>Help</summary><p>Use the same Tailscale account as your Mac.</p><p>If your administrator hides devices, ask them to make your phone visible. Multiple matches require a choice on the Mac.</p></details>")
    }
    static func hub(language: SetupLanguage, host: String, services: [MacAccessService]) -> String {
        let e = MobileGuideContent.escape
        var body = "<p>Keep this link for next time.</p><p>Safari Share → Add to Home Screen.</p><p data-path-status role='status'></p><div class='ready-list'>"
        let ready = services.filter(\.reachable)
        if ready.isEmpty { body += "<p>No services ready. Choose one on your Mac.</p>" }
        for result in ready {
            guard let url = result.action(host: host) else { continue }
            let service = result.service
            let title = ["smb": "Files", "vnc": "Mac Screen", "ssh": "Terminal"][service.scheme] ?? service.name
            let scene: MacAccessArt = ["smb": .files, "vnc": .screen, "ssh": .terminal][service.scheme] ?? .web
            body += "<details data-service='\(e(service.id))'><summary class='icon'>\(scene.svg)\(e(title))</summary>"
            let detail: String
            switch service.scheme {
            case "smb": detail = "Paste this in Files → Browse → … → Connect to Server."
            case "vnc": detail = "Open in a VNC app, or copy this address into it."
            case "ssh": detail = "Open in an SSH app, or copy this address into it."
            default: detail = "Open your Mac web app in Safari."
            }
            body += "<p>\(detail)</p>"
            if ["ssh", "smb", "vnc"].contains(service.scheme) { body += "<p>Sign in as an allowed Mac user.</p>" }
            if service.scheme == "ssh" { body += "<p>Verify the host key before signing in.</p>" }
            if ["http", "https", "ssh", "vnc"].contains(service.scheme) { body += "<p><a class='action' href='\(e(url.absoluteString))'>Open</a></p>" }
            body += "<input readonly aria-label='Service address' value='\(e(url.absoluteString))'><button data-copy>Copy Address</button><p>Verify files, screen or sign-in in that app.</p></details>"
        }
        body += "</div><details><summary>Connection Help</summary><p>Keep your Mac awake and RetroStats running.</p><p>Reconnect or sign in again in Tailscale if needed.</p><p>For automatic reconnect: profile → VPN On Demand → Always on Wi-Fi and cellular.</p><p>After using another VPN, check this again.</p><p>Mac addresses are provided here; mobile localhost and Bonjour discovery are separate.</p><p>Never enter passwords on this page.</p></details>"
        return document(language: .en, title: "My Mac", body: body)
    }
}

private final class MacAccessIdentityPage: @unchecked Sendable {
    private let lock = NSLock()
    private var html = "", allowed = Set<String>()
    func set(_ value: String, addresses: Set<String>) { lock.lock(); html = value; allowed = addresses; lock.unlock() }
    func get(remote: String) -> String { lock.lock(); let page = allowed.contains(remote) ? html : nil; lock.unlock(); return page ?? MacAccessPage.unverified }
}
