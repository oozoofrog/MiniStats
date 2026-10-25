import Foundation

/// Real short-lived child processes; no Tailscale CLI, credentials or network calls.
func tailscaleCLICancellationSelfTest(iterations: Int = 20) async throws {
    let arguments = ["-c", "while :; do printf output; printf error >&2; /bin/sleep 0.005; done"]
    let runner = TailscaleCLI(limit: 1_048_576)
    func requireFailure(_ expected: TailscaleFailure, work: () async throws -> Void) async throws {
        do {
            try await work()
            throw TailscaleFailure.invalid("Active-output process unexpectedly succeeded")
        } catch let failure as TailscaleFailure {
            guard failure == expected else {
                throw TailscaleFailure.invalid("Expected \(expected), received \(failure) during active-output termination")
            }
        }
    }
    for _ in 0..<iterations {
        let task = Task { try await runner.run(executable: "/bin/sh", arguments: arguments, timeout: 2) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        try await requireFailure(.cancelled) { _ = try await task.value }
        try await requireFailure(.timeout) { _ = try await runner.run(executable: "/bin/sh", arguments: arguments, timeout: 0.02) }
    }
    print("PASS: active stdout/stderr preserve cancellation and timeout classification across \(iterations) races")
}
