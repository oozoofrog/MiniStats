import Foundation
import Darwin

struct TailscaleCommandResult: Sendable {
    var stdout: Data, stderr: Data, status: Int32
    var text: String { String(decoding: stdout, as: UTF8.self) }
    func checked() throws -> Self { guard status == 0 else { throw TailscaleFailure.command(status) }; return self }
}
protocol TailscaleExecuting: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> TailscaleCommandResult
}

/// Every invocation owns both pipe readers and its deadline. No shell or inherited PATH.
final class TailscaleCLI: TailscaleExecuting, @unchecked Sendable {
    let limit: Int
    init(limit: Int = 1_048_576) { self.limit = limit }
    func run(executable: String, arguments: [String], timeout: TimeInterval = 12) async throws -> TailscaleCommandResult {
        let job = ProcessJob(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: { job.cancel() }
    }
}

private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "RetroStats.Tailscale.process", qos: .utility)
    private let process = Process(), out = Pipe(), err = Pipe()
    private var stdout = Data(), stderr = Data()
    private var continuation: CheckedContinuation<TailscaleCommandResult, Error>?
    private var finished = false, cancelled = false, exited = false
    private var eof = Set<Int>()
    private var failure: Error?
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func start(executable: String, arguments: [String], timeout: TimeInterval, continuation: CheckedContinuation<TailscaleCommandResult, Error>) {
        queue.async {
            self.lock.lock(); self.continuation = continuation; let cancelled = self.cancelled; self.lock.unlock()
            if cancelled { self.complete(.failure(TailscaleFailure.cancelled)); return }
            guard executable.hasPrefix("/"), timeout > 0 else { self.complete(.failure(TailscaleFailure.invalid("An absolute executable and positive timeout are required."))); return }
            self.process.executableURL = URL(fileURLWithPath: executable)
            self.process.arguments = arguments
            self.process.standardInput = FileHandle.nullDevice
            self.process.standardOutput = self.out; self.process.standardError = self.err
            self.process.environment = ["LANG": "en_US.UTF-8", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            for (index, pipe) in [(0, self.out), (1, self.err)] {
                pipe.fileHandleForReading.readabilityHandler = { [weak job = self] handle in
                    guard let self = job else { return }
                    let data = handle.availableData
                    self.lock.lock()
                    if data.isEmpty { self.eof.insert(index); handle.readabilityHandler = nil }
                    else if !self.finished {
                        if self.stdout.count + self.stderr.count + data.count > self.limit { self.failure = TailscaleFailure.outputLimit }
                        else if index == 0 { self.stdout.append(data) } else { self.stderr.append(data) }
                    }
                    let exceeded = self.failure != nil
                    let ready = self.exited && self.eof.count == 2
                    self.lock.unlock()
                    if exceeded { self.abort(TailscaleFailure.outputLimit) } else if ready { self.finishExit() }
                }
            }
            self.process.terminationHandler = { [weak job = self] _ in
                guard let self = job else { return }
                self.lock.lock(); self.exited = true; let ready = self.eof.count == 2; self.lock.unlock()
                if ready { self.finishExit() }
                // Descendants retaining a pipe must not hang completion indefinitely.
                else { self.queue.asyncAfter(deadline: .now() + 0.3) {
                    self.lock.lock(); let drained = self.eof.count == 2; self.lock.unlock()
                    if drained { self.finishExit() }
                    else { self.complete(.failure(TailscaleFailure.invalid("Command ended without closing its output streams; result was discarded."))) }
                } }
            }
            do {
                try self.process.run()
                self.lock.lock(); let cancelledAfterLaunch = self.cancelled; self.lock.unlock()
                if cancelledAfterLaunch { self.abort(TailscaleFailure.cancelled) }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.lock.lock(); let unfinished = !self.finished; self.lock.unlock()
                    if unfinished { self.abort(TailscaleFailure.timeout) }
                }
            } catch { self.complete(.failure(TailscaleFailure.unavailable("Cannot launch the detected Tailscale executable."))) }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let started = continuation != nil; lock.unlock()
        if started { queue.async { self.abort(TailscaleFailure.cancelled) } }
    }
    private func abort(_ error: Error) {
        lock.lock(); let done = finished; lock.unlock(); guard !done else { return }
        if process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            queue.asyncAfter(deadline: .now() + 0.2) { if self.process.isRunning { kill(pid, SIGKILL) } }
        }
        complete(.failure(error))
    }
    private func finishExit() {
        lock.lock()
        let result = TailscaleCommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
        let error = failure
        lock.unlock()
        complete(error.map { .failure($0) } ?? .success(result))
    }
    private func complete(_ result: Result<TailscaleCommandResult, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        lock.unlock()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        continuation.resume(with: result)
    }
}
