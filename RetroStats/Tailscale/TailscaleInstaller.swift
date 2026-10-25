import AppKit
import Foundation
import CryptoKit

struct TailscaleInstallJob: Codable, Equatable, Sendable {
    let id: UUID
    var directory: URL { URL(fileURLWithPath: "/private/tmp/RetroStats-Tailscale-" + id.uuidString, isDirectory: true) }
    /// Root creates this directory after authorization. User-writable files are never trusted.
    func progress(fileManager: FileManager = .default) -> String? {
        rootText("result", fileManager: fileManager)
    }
    func rootText(_ name: String, fileManager: FileManager = .default) -> String? {
        guard ["result", "pid"].contains(name) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 else { return nil }
        let file = directory.appendingPathComponent(name)
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? 999) > 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? 999) < 64,
              let data = try? Data(contentsOf: file) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TailscaleInstallOutcome: Sendable, Equatable { case completed, cancelled, denied, pending, failed }
protocol TailscaleInstalling: Sendable {
    func acquire(executor: any TailscaleExecuting, progress: @escaping @Sendable (TailscaleSetupStage) async -> Void) async throws -> URL
    func install(package: URL, job: TailscaleInstallJob, executor: any TailscaleExecuting) async throws -> TailscaleInstallOutcome
    func confirmed(executor: any TailscaleExecuting) async -> Bool
    func progress(job: TailscaleInstallJob) -> String?
    func authorizationActive(job: TailscaleInstallJob, executor: any TailscaleExecuting) async -> Bool?
    func discard(package: URL)
}

struct TailscaleNativeInstaller: TailscaleInstalling {
    func acquire(executor: any TailscaleExecuting, progress: @escaping @Sendable (TailscaleSetupStage) async -> Void) async throws -> URL { try await TailscaleInstaller.acquire(executor: executor, progress: progress) }
    func install(package: URL, job: TailscaleInstallJob, executor: any TailscaleExecuting) async throws -> TailscaleInstallOutcome {
        try Task.checkCancellation()
        guard !TailscaleInstaller.existingClient() else { throw TailscaleFailure.invalid("A client is already installed. Resume its setup.") }
        let digest = try TailscaleInstaller.digest(package)
        let command = try TailscaleInstaller.installCommand(package: package, digest: digest, job: job)
        // Independent lifetime: cancellation/closing a panel must not kill an authorized package install.
        // OS cancellation still returns a typed result. A timeout leaves the persisted job pending.
        let task = Task.detached {
            try await executor.run(executable: "/usr/bin/osascript", arguments: ["-e", TailscaleInstaller.authorizationScript, command], timeout: 3600)
        }
        let result = try await task.value
        guard result.status == 0 else { return .pending }
        switch result.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "RS_INSTALLED": return .completed
        case "RS_CANCELLED": return .cancelled
        case "RS_DENIED": return .denied
        case "RS_FAILED": return .failed
        case "RS_BUSY": return .pending
        default: return .pending
        }
    }
    func confirmed(executor: any TailscaleExecuting) async -> Bool {
        let path = "/Applications/Tailscale.app"
        guard let bundle = Bundle(path: path), bundle.bundleIdentifier == "io.tailscale.ipn.macsys",
              FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/Tailscale") else { return false }
        do {
            let receipt = try await executor.run(executable: "/usr/sbin/pkgutil", arguments: ["--pkg-info-plist", "com.tailscale.ipn.macsys"], timeout: 5).checked()
            guard let object = try PropertyListSerialization.propertyList(from: receipt.stdout, format: nil) as? [String: Any], object["pkgid"] as? String == "com.tailscale.ipn.macsys" else { return false }
            _ = try await executor.run(executable: "/usr/bin/codesign", arguments: ["--verify", "--strict", path], timeout: 15).checked()
            let identity = try await executor.run(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", path], timeout: 5).checked()
            let lines = String(decoding: identity.stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
            return lines.contains("TeamIdentifier=W5364U7YZB") && lines.contains("Identifier=io.tailscale.ipn.macsys")
        } catch { return false }
    }
    func progress(job: TailscaleInstallJob) -> String? { job.progress() }
    func authorizationActive(job: TailscaleInstallJob, executor: any TailscaleExecuting) async -> Bool? {
        // A missing root result means authorization has not run yet, not that its dialog is gone.
        // Match this user's unique job argument, then confirm the process is osascript.
        do {
            if let value = job.rootText("pid"), let pid = Int32(value), pid > 0 {
                let rootProcess = try await executor.run(executable: "/bin/ps", arguments: ["-ww", "-p", String(pid), "-o", "command="], timeout: 5)
                if rootProcess.status == 0, rootProcess.text.contains(job.directory.path) { return true }
                if ![0, 1].contains(rootProcess.status) { return nil }
            }
            let matches = try await executor.run(executable: "/usr/bin/pgrep", arguments: ["-u", String(getuid()), "-f", job.directory.path], timeout: 5)
            if matches.status == 1 { return false }
            guard matches.status == 0 else { return nil }
            for value in matches.text.split(whereSeparator: \.isWhitespace) {
                guard let pid = Int32(value), pid > 0 else { return nil }
                let process = try await executor.run(executable: "/bin/ps", arguments: ["-p", String(pid), "-o", "comm="], timeout: 5)
                if process.status == 0, process.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/bin/osascript" { return true }
                // Some macOS ps versions return only the executable name in comm.
                if process.status == 0, process.text.trimmingCharacters(in: .whitespacesAndNewlines) == "osascript" { return true }
            }
            return false
        } catch { return nil }
    }
    func discard(package: URL) { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
}

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
    static func acquire(executor: any TailscaleExecuting = TailscaleCLI(), progress: @escaping @Sendable (TailscaleSetupStage) async -> Void = { _ in }) async throws -> URL {
        guard !existingClient() else { throw TailscaleFailure.invalid("An existing Tailscale client was found. Open or repair it instead of installing another distribution.") }
        let extensions = try await executor.run(executable: "/usr/bin/systemextensionsctl", arguments: ["list"], timeout: 5).checked()
        guard TailscaleSetupObservation.extensionState(extensions.text) != .removalPending else { throw TailscaleFailure.invalid("macOS is finishing the previous Tailscale removal. Restart your Mac before installing again.") }
        await progress(.downloading)
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
            await progress(.verifying)
            let signature = try await executor.run(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", package.path], timeout: 20).checked()
            guard validSignature(signature.text) else { throw TailscaleFailure.invalid("Official Tailscale installer signature did not match") }
            _ = try await executor.run(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "install", package.path], timeout: 30).checked()
            try Task.checkCancellation()
            guard !existingClient() else { throw TailscaleFailure.invalid("A client was installed during preparation. Open it instead.") }
            return package
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static let authorizationScript = """
    on run argv
        try
            do shell script (item 1 of argv) with administrator privileges
            return "RS_INSTALLED"
        on error messageText number errorNumber
            if errorNumber is -128 then return "RS_CANCELLED"
            if errorNumber is -60005 or errorNumber is -60007 then return "RS_DENIED"
            if errorNumber is 45 or errorNumber is 75 then return "RS_BUSY"
            return "RS_FAILED"
        end try
    end run
    """
    static func digest(_ package: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: package.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue < 268_435_456 else { throw TailscaleFailure.invalid("The verified package changed. Download it again.") }
        return SHA256.hash(data: try Data(contentsOf: package, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func installCommand(package: URL, digest: String, job: TailscaleInstallJob) throws -> String {
        let payload = try installationPayload(package: package, digest: digest, job: job)
        // Keep the inode and use macOS's kernel lock. A crash leaves no stale directory/PID
        // mutex, and a competing request never executes the installation payload.
        return "exec /usr/bin/lockf -k -s -t 0 /private/var/run/RetroStats-Tailscale-Install.lock /bin/sh -c " + shellQuote(payload)
    }
    static func installationPayload(package: URL, digest: String, job: TailscaleInstallJob) throws -> String {
        guard package.isFileURL, package.path.hasPrefix("/"), package.lastPathComponent.range(of: "^Tailscale-[0-9]+\\.[0-9]+\\.[0-9]+-macos\\.pkg$", options: .regularExpression) != nil,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw TailscaleFailure.invalid("Invalid installation request") }
        // The copied package and result are root-owned. Hash/signature/assessment are checked
        // again after the native authorization dialog, eliminating a mutable-package handoff.
        return """
        set -eu
        job=\(shellQuote(job.directory.path))
        /bin/mkdir -m 755 "$job"
        pkg="$job/connection.pkg"
        trap 'code=$?; /bin/rm -f "$pkg"; if [ "$code" = 0 ]; then printf finished > "$job/result"; else printf "failed:%s" "$code" > "$job/result"; fi; /bin/chmod 644 "$job/result"' EXIT
        printf '%s' "$$" > "$job/pid"
        /bin/chmod 644 "$job/pid"
        printf installing > "$job/result"
        /bin/chmod 644 "$job/result"
        [ ! -e /Applications/Tailscale.app ] || exit 41
        [ ! -e \(shellQuote(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tailscale.app").path)) ] || exit 41
        extensions=$(/usr/bin/systemextensionsctl list)
        if printf '%s\\n' "$extensions" | /usr/bin/grep -F 'io.tailscale.ipn.macsys.network-extension' | /usr/bin/grep -Fq '[terminated waiting to uninstall on reboot]'; then exit 46; fi
        /bin/cp -P \(shellQuote(package.path)) "$pkg"
        [ -f "$pkg" ] && [ ! -L "$pkg" ] || exit 42
        /bin/chmod 600 "$pkg"
        actual=$(/usr/bin/shasum -a 256 "$pkg")
        [ "${actual%% *}" = \(shellQuote(digest)) ] || exit 43
        signature=$(/usr/sbin/pkgutil --check-signature "$pkg")
        printf '%s\\n' "$signature" | /usr/bin/grep -Eq '^ *Status: signed by (a developer certificate issued by Apple for distribution|a certificate trusted by .+)$' || exit 44
        printf '%s\\n' "$signature" | /usr/bin/grep -Eq '^ *1\\. Developer ID Installer: Tailscale Inc\\. \\(W5364U7YZB\\)$' || exit 44
        /usr/sbin/spctl --assess --type install "$pkg"
        /usr/sbin/installer -pkg "$pkg" -target / > /dev/null
        """
    }
}
