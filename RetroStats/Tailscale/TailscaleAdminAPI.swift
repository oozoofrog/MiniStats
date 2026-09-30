import Foundation
import Security

struct TailscaleAPIResponse: Sendable { var data: Data; var status: Int; var etag: String? }
protocol TailscaleAPITransport: Sendable { func send(_ request: URLRequest) async throws -> TailscaleAPIResponse }
private final class NoAPIRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class TailscaleURLTransport: TailscaleAPITransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoAPIRedirect(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> TailscaleAPIResponse {
        let (stream, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in stream {
            guard data.count < 2_097_152 else { throw TailscaleFailure.outputLimit }
            data.append(byte)
        }
        guard let response = response as? HTTPURLResponse else { throw TailscaleFailure.invalid("Invalid API response") }
        return .init(data: data, status: response.statusCode, etag: response.value(forHTTPHeaderField: "ETag"))
    }
}

protocol TailscaleCredentialStore {
    func read() throws -> String?
    func readWithoutInteraction() throws -> String?
    func write(_ value: String) throws
    func remove() throws
}
extension TailscaleCredentialStore {
    func readWithoutInteraction() throws -> String? { try read() }
}
struct TailscaleKeychain: TailscaleCredentialStore {
    // This app uses the macOS file-based keychain. Serialize its temporary
    // interaction policy with every credential operation in this process.
    private static let lock = NSRecursiveLock()
    var service = "RetroStats.TailscaleAdmin"
    var account = "admin"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func read() throws -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TailscaleFailure.credential }
        return String(data: data, encoding: .utf8)
    }
    func readWithoutInteraction() throws -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var allowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw TailscaleFailure.credential }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try read()
    }
    func write(_ value: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var add = query; add[kSecValueData as String] = Data(value.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary) == errSecSuccess else { throw TailscaleFailure.credential }
        } else if status != errSecSuccess { throw TailscaleFailure.credential }
    }
    func remove() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TailscaleFailure.credential }
    }
}

struct TailscalePolicy: Equatable { var text: String; var etag: String }
struct TailscaleAuthKey { var id: String, secret: String; var expires: Date }
struct TailscaleAdminDevice: Identifiable {
    var id: String, nodeID: String, name: String, os: String, addresses: [String], authorized: Bool?
    static func parse(_ data: Data) throws -> [Self] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["devices"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["id"] as? String else { return nil }
            return Self(id: id, nodeID: value["nodeId"] as? String ?? "", name: value["name"] as? String ?? id, os: value["os"] as? String ?? "", addresses: value["addresses"] as? [String] ?? [], authorized: value["authorized"] as? Bool)
        }
    }
}

final class TailscaleAdminAPI: @unchecked Sendable {
    let tailnet: String
    private let credential: String
    private let transport: any TailscaleAPITransport
    init(tailnet: String, credential: String, transport: any TailscaleAPITransport = TailscaleURLTransport()) {
        self.tailnet = tailnet; self.credential = credential; self.transport = transport
    }
    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != ".." else { throw TailscaleFailure.invalid("Missing API identifier") }
        return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
    private func tail(_ suffix: String) throws -> String { "tailnet/\(try component(tailnet))/\(suffix)" }
    func request(_ path: String, method: String = "GET", body: Data? = nil, etag: String? = nil, hujson: Bool = false) async throws -> TailscaleAPIResponse {
        guard !credential.isEmpty, let url = URL(string: "https://api.tailscale.com/api/v2/" + path) else { throw TailscaleFailure.credential }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Basic " + Data((credential + ":").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(hujson ? "application/hujson" : "application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hujson ? "application/hujson" : "application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        let result = try await transport.send(request)
        if result.status == 409 || result.status == 412 { throw TailscaleFailure.conflict }
        guard (200..<300).contains(result.status) else { throw TailscaleFailure.api(result.status) }
        return result
    }
    func devices() async throws -> [TailscaleAdminDevice] { try TailscaleAdminDevice.parse(await request(tail("devices")).data) }
    func approveDevice(_ id: String) async throws { _ = try await request("device/\(component(id))/authorized", method: "POST", body: JSONSerialization.data(withJSONObject: ["authorized": true])) }
    func routes(_ id: String) async throws -> Data { try await request("device/\(component(id))/routes").data }
    func approveRoutes(_ id: String, enabled: [String]) async throws {
        _ = try await request("device/\(component(id))/routes", method: "POST", body: JSONSerialization.data(withJSONObject: ["routes": enabled]))
    }
    func dns(_ resource: String) async throws -> Data {
        guard ["nameservers", "searchpaths", "preferences"].contains(resource) else { throw TailscaleFailure.invalid("Unknown DNS resource") }
        return try await request(tail("dns/" + resource)).data
    }
    func updateDNS(_ resource: String, body: Data) async throws {
        guard ["nameservers", "searchpaths", "preferences"].contains(resource), (try JSONSerialization.jsonObject(with: body)) is [String: Any] else { throw TailscaleFailure.invalid("Invalid DNS JSON") }
        _ = try await request(tail("dns/" + resource), method: "POST", body: body)
    }
    func policy() async throws -> TailscalePolicy {
        let result = try await request(tail("acl"), hujson: true)
        guard let etag = result.etag, !etag.isEmpty else { throw TailscaleFailure.invalid("Server did not supply an ETag; safe policy editing is unavailable.") }
        return .init(text: String(decoding: result.data, as: UTF8.self), etag: etag)
    }
    func validatePolicy(_ text: String) async throws {
        let result = try await request(tail("acl/validate"), method: "POST", body: Data(text.utf8), hujson: true)
        if let root = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any], let errors = root["errors"] as? [Any], !errors.isEmpty { throw TailscaleFailure.invalid("Server policy validation failed. Review the rules and tests.") }
    }
    func savePolicy(_ text: String, baseline: TailscalePolicy) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != baseline.text else { throw TailscaleFailure.invalid("No policy changes to save") }
        try await validatePolicy(text)
        _ = try await request(tail("acl"), method: "POST", body: Data(text.utf8), etag: baseline.etag, hujson: true)
    }
    static func keyBody(preauthorized: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["expirySeconds": 600, "capabilities": ["devices": ["create": ["reusable": false, "ephemeral": false, "preauthorized": preauthorized, "tags": [] as [String]]]]])
    }
    func createKey(preauthorized: Bool, now: Date = Date()) async throws -> TailscaleAuthKey {
        let result = try await request(tail("keys"), method: "POST", body: Self.keyBody(preauthorized: preauthorized))
        guard let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any], let id = object["id"] as? String, let secret = object["key"] as? String, !id.isEmpty, !secret.isEmpty else { throw TailscaleFailure.invalid("Invalid auth-key response") }
        let serverExpiry = (object["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return .init(id: id, secret: secret, expires: min(serverExpiry ?? now.addingTimeInterval(600), now.addingTimeInterval(600)))
    }
    func revokeKey(_ id: String) async throws { _ = try await request(tail("keys/\(component(id))"), method: "DELETE") }
}
