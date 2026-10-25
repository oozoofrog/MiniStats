import Foundation
import Darwin

/// A bounded read-only HTTP server bound to one numeric address, never a wildcard.
/// BSD binding also accepts traffic delivered by the macOS Tailscale tunnel;
/// NWListener readiness alone did not establish that path on the tested host.
final class MobileGuideServer: MobileGuideServing, @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "RetroStats.MobileGuide")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var listenerClosed: DispatchGroup?
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Client] = [:]
    private var expiry: DispatchWorkItem?
    init(port: UInt16 = 0) { self.port = port; queue.setSpecific(key: queueKey, value: 1) }

    private final class Client {
        let fd: Int32
        let remote: String
        let reader: DispatchSourceRead
        let sources = DispatchGroup(), closed = DispatchGroup()
        let queue: DispatchQueue
        var cancelled = false
        var writer: DispatchSourceWrite?
        var deadline: DispatchWorkItem?
        var input = Data(), output = Data()
        var sent = 0, reading = true
        init(fd: Int32, remote: String, queue: DispatchQueue) {
            self.fd = fd; self.remote = remote; self.queue = queue
            sources.enter(); closed.enter()
            reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let sources = self.sources
            reader.setCancelHandler { sources.leave() }
        }
        func cancel() {
            guard !cancelled else { return }; cancelled = true
            deadline?.cancel(); writer?.cancel()
            if !reading { reader.resume(); reading = true }
            reader.cancel()
            let fd = self.fd, closed = self.closed
            sources.notify(queue: queue) { close(fd); closed.leave() }
        }
    }

    static func allowedRequest(_ text: String, token: String, now: Date, expires: Date) -> Bool {
        guard now < expires else { return false }
        let first = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        return first.count == 3 && first[0] == "GET" && first[1] == "/" + token && first[2] == "HTTP/1.1"
    }

    func start(address: String, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void, failed: @escaping () -> Void) throws {
        let actual: UInt16 = try queue.sync {
            guard listener == nil else { throw TailscaleFailure.invalid("Guide already running") }
            let fd = try Self.boundSocket(address: address, port: port)
            var owned = true
            defer { if owned { close(fd) } }
            guard listen(fd, 8) == 0 else { throw Self.socketError() }
            var storage = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            guard withUnsafeMutablePointer(to: &storage, { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }) == 0 else { throw Self.socketError() }
            let family = storage.ss_family
            let actual = withUnsafePointer(to: &storage) { pointer -> UInt16 in
                if family == sa_family_t(AF_INET) {
                    return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
                }
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let closed = DispatchGroup(); closed.enter(); listenerClosed = closed
            source.setCancelHandler { close(fd); closed.leave() }
            source.setEventHandler { [weak self] in self?.acceptClients(fd: fd, token: token, expires: expires, page: page, visited: visited, failed: failed) }
            listener = source; owned = false; source.resume()
            if expires != .distantFuture {
                let timer = DispatchWorkItem { [weak self] in _ = self?.stopOnQueue() }
                expiry = timer; queue.asyncAfter(deadline: .now() + max(0, expires.timeIntervalSinceNow), execute: timer)
            }
            return actual
        }
        ready(actual)
    }

    private static func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
    }
    private static func boundSocket(address: String, port: UInt16) throws -> Int32 {
        var ipv4 = sockaddr_in(), ipv6 = sockaddr_in6()
        let family: Int32
        if inet_pton(AF_INET, address, &ipv4.sin_addr) == 1, ipv4.sin_addr.s_addr != INADDR_ANY {
            family = AF_INET; ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); ipv4.sin_family = sa_family_t(AF_INET); ipv4.sin_port = port.bigEndian
        } else if inet_pton(AF_INET6, address, &ipv6.sin6_addr) == 1, address != "::", withUnsafeBytes(of: ipv6.sin6_addr, { $0.contains { $0 != 0 } }) {
            family = AF_INET6; ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); ipv6.sin6_family = sa_family_t(AF_INET6); ipv6.sin6_port = port.bigEndian
        } else { throw TailscaleFailure.invalid("Guide requires a specific numeric local address") }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do {
            try configure(fd)
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
            let result: Int32
            if family == AF_INET {
                result = withUnsafePointer(to: &ipv4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
                result = withUnsafePointer(to: &ipv6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            guard result == 0 else { throw socketError() }
            return fd
        } catch { close(fd); throw error }
    }

    private func acceptClients(fd: Int32, token: String, expires: Date, page: @escaping (String) -> String, visited: @escaping (String) -> Void, failed: @escaping () -> Void) {
        // Bound work per event as well as concurrent connections.
        for _ in 0..<8 {
            var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            guard clientFD >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stopOnQueue(); failed() }
                return
            }
            guard connections.count < 8 else { close(clientFD); continue }
            do { try Self.configure(clientFD) } catch { close(clientFD); continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, length, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) } }
            guard result == 0 else { close(clientFD); continue }
            let id = UUID(), client = Client(fd: clientFD, remote: String(cString: name), queue: queue)
            connections[id] = client
            client.reader.setEventHandler { [weak self] in self?.receive(id, token: token, expires: expires, page: page, visited: visited) }
            client.reader.resume()
            let timer = DispatchWorkItem { [weak self] in self?.closeClient(id) }
            client.deadline = timer; queue.asyncAfter(deadline: .now() + 5, execute: timer)
        }
    }
    private func receive(_ id: UUID, token: String, expires: Date, page: (String) -> String, visited: (String) -> Void) {
        guard let client = connections[id], client.reading else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(client.fd, &bytes, bytes.count, 0)
        guard count > 0 else {
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { closeClient(id) }
            return
        }
        client.input.append(contentsOf: bytes.prefix(count))
        guard client.input.count <= 8192 else { closeClient(id); return }
        let request = String(decoding: client.input, as: UTF8.self)
        guard request.contains("\r\n\r\n") else { return }
        client.reader.suspend(); client.reading = false
        let allowed = Self.allowedRequest(request, token: token, now: Date(), expires: expires)
        let body = allowed ? page(client.remote) : "Session unavailable"
        if allowed { visited(client.remote) }
        let status = allowed ? "200 OK" : "404 Not Found"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; font-src data:; script-src 'sha256-\(MacAccessPage.scriptHash)'; connect-src http:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
        client.output = Data((header + body).utf8)
        flush(id)
    }
    private func flush(_ id: UUID) {
        guard let client = connections[id] else { return }
        while client.sent < client.output.count {
            let count = client.output.withUnsafeBytes { send(client.fd, $0.baseAddress!.advanced(by: client.sent), $0.count - client.sent, 0) }
            if count > 0 { client.sent += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if client.writer == nil {
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
                    let sources = client.sources; sources.enter()
                    writer.setCancelHandler { sources.leave() }
                    writer.setEventHandler { [weak self] in self?.flush(id) }; client.writer = writer; writer.resume()
                }
                return
            }
            closeClient(id); return
        }
        closeClient(id)
    }
    private func closeClient(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    @discardableResult private func stopOnQueue() -> [DispatchGroup] {
        let completions = connections.values.map(\.closed) + (listenerClosed.map { [$0] } ?? [])
        expiry?.cancel(); expiry = nil; listener?.cancel(); listener = nil; listenerClosed = nil
        for id in Array(connections.keys) { closeClient(id) }
        return completions
    }
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopOnQueue(); return }
        // Wait outside the queue that executes the cancellation handlers. This makes
        // immediate saved-port restart safe without closing a source-owned FD early.
        let completions = queue.sync { stopOnQueue() }
        completions.forEach { $0.wait() }
    }
    deinit { listener?.cancel(); expiry?.cancel(); connections.values.forEach { $0.cancel() } }
}
