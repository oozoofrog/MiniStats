import Foundation
import Network

protocol MacAccessProbing: Sendable {
    func check(host: String, services: [TailscaleService]) async -> [MacAccessService]
}

struct MacAccessProbe: MacAccessProbing {
    func check(host: String, services: [TailscaleService]) async -> [MacAccessService] {
        var results: [MacAccessService] = []
        // Only configured service ports are probed. No port scan or sharing mutation.
        for service in services {
            if Task.isCancelled { break }
            let remote = await response(host: host, service: service)
            let local = !remote && ["http", "https"].contains(service.scheme) ? await response(host: "127.0.0.1", service: service) : false
            results.append(.init(service: service, reachable: remote, localOnly: local))
        }
        return results
    }
    private func response(host: String, service: TailscaleService) async -> Bool {
        if ["http", "https"].contains(service.scheme) {
            guard let url = service.url(host: host) else { return false }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 3
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: url); request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse).map { (200...499).contains($0.statusCode) } ?? false
            } catch { return false }
        }
        guard ["smb", "ssh", "vnc"].contains(service.scheme), let port = NWEndpoint.Port(rawValue: UInt16(clamping: service.port)) else { return false }
        let result = AccessSocketProbe(host: host, port: port, scheme: service.scheme)
        return await withTaskCancellationHandler { await result.run() } onCancel: { result.cancel() }
    }
}

/// Banner checks distinguish SSH/VNC from an unrelated listener. SMB sends a SMB1 negotiate
/// with the SMB2 dialect and accepts only an SMB protocol response; no login or file access.
private final class AccessSocketProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RetroStats.AccessProbe")
    private let connection: NWConnection
    private let scheme: String
    private var continuation: CheckedContinuation<Bool, Never>?
    private var ended = false
    init(host: String, port: NWEndpoint.Port, scheme: String) { connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp); self.scheme = scheme }
    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.ended { continuation.resume(returning: false); return }
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if self.scheme == "smb" {
                            var payload: [UInt8] = [0xff,0x53,0x4d,0x42,0x72,0,0,0,0,0x18,0x01,0x28] + [UInt8](repeating: 0, count: 20)
                            let dialect = Array("\u{02}SMB 2.002\0".utf8)
                            payload += [0, UInt8(dialect.count), 0] + dialect
                            let packet = Data([0,0,0,UInt8(payload.count)] + payload)
                            self.connection.send(content: packet, completion: .contentProcessed { error in if error != nil { self.finish(false) } else { self.receive(Data()) } })
                        } else { self.receive(Data()) }
                    case .failed, .cancelled: self.finish(false)
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 2) { self.finish(false) }
            }
        }
    }
    private func receive(_ collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, complete, error in
            var collected = collected; collected.append(data ?? Data())
            let text = String(decoding: collected, as: UTF8.self)
            let valid = self.scheme == "ssh" ? text.hasPrefix("SSH-") : self.scheme == "vnc" ? text.hasPrefix("RFB ") : collected.count >= 8 && [0xfe, 0xff].contains(collected[4]) && Array(collected[5...7]) == [0x53,0x4d,0x42]
            if valid { self.finish(true) }
            else if complete || error != nil || collected.count >= 128 { self.finish(false) }
            else { self.receive(collected) }
        }
    }
    private func finish(_ value: Bool) { guard !ended else { return }; ended = true; connection.cancel(); continuation?.resume(returning: value); continuation = nil }
    func cancel() { queue.async { self.finish(false) } }
}
