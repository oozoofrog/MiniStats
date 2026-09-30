import AppKit
import Foundation

private final class TailscalePackageRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allows(_ url: URL) -> Bool { url.scheme == "https" && ["pkgs.tailscale.com", "dl.tailscale.com"].contains(url.host ?? "") && url.user == nil && url.password == nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(request.url.map(Self.allows) == true ? request : nil) }
}

struct TailscaleInstaller {
    static func packageURL(index: String) -> URL? {
        guard let range = index.range(of: "Tailscale-[0-9]+\\.[0-9]+\\.[0-9]+-macos\\.pkg", options: .regularExpression) else { return nil }
        return URL(string: "https://pkgs.tailscale.com/stable/" + index[range])
    }
    static func validSignature(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // macOS 26 reports trusted Developer ID packages with this distribution status.
        // Gatekeeper assessment remains a separate required check before opening Installer.
        let trusted = lines.contains {
            $0 == "Status: signed by a developer certificate issued by Apple for distribution"
                || $0.hasPrefix("Status: signed by a certificate trusted by ")
        }
        let signer = "Developer ID Installer: Tailscale Inc. (W5364U7YZB)"
        return trusted && (lines.contains("1. " + signer) || lines.contains(signer))
    }
    static func existingClient() -> Bool {
        TailscaleInstallation.detect() != nil || ["/Applications/Tailscale.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tailscale.app").path].contains { FileManager.default.fileExists(atPath: $0) }
    }
    static func acquire(executor: any TailscaleExecuting = TailscaleCLI()) async throws -> URL {
        guard !existingClient() else { throw TailscaleFailure.invalid("An existing Tailscale client was found. Open or repair it instead of installing another distribution.") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 180; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: TailscalePackageRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: URL(string: "https://pkgs.tailscale.com/stable/")!)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url.map(TailscalePackageRedirect.allows) == true else { throw TailscaleFailure.invalid("Official package index unavailable") }
        var index = Data()
        for try await byte in stream { guard index.count < 524_288 else { throw TailscaleFailure.outputLimit }; index.append(byte) }
        guard let source = packageURL(index: String(decoding: index, as: UTF8.self)) else { throw TailscaleFailure.invalid("No official macOS package found") }
        let (temporary, downloadResponse) = try await session.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let downloadResponse = downloadResponse as? HTTPURLResponse, downloadResponse.statusCode == 200, downloadResponse.url.map(TailscalePackageRedirect.allows) == true,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 268_435_456 else { throw TailscaleFailure.invalid("Invalid official package download") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetroStats-Installer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let package = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: temporary, to: package)
            let signature = try await executor.run(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", package.path], timeout: 20).checked()
            guard validSignature(signature.text) else { throw TailscaleFailure.invalid("Official Tailscale installer signature did not match") }
            _ = try await executor.run(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "install", package.path], timeout: 30).checked()
            try Task.checkCancellation()
            guard !existingClient() else { throw TailscaleFailure.invalid("A client was installed during preparation. Open it instead.") }
            return package
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
