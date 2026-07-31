import Foundation
import Testing
@testable import awesoMux

@Suite("Bridge exec channel")
struct BridgeExecChannelTests {
    @Test("captures bounded stdout")
    func capturesBoundedOutput() async throws {
        let output = try await BridgeExecChannel.run(
            command: "printf bridge-ready",
            stdin: nil
        )
        #expect(String(decoding: output, as: UTF8.self) == "bridge-ready")
    }

    @Test("terminates a child whose stdout exceeds the cap")
    func rejectsOversizedOutput() async {
        // Two mechanisms can terminate this child — the 64 KB output cap and the
        // overall timeout — and the assertion is about which one did. Stalling the
        // timeout leaves the cap as the only live mechanism, so the outcome stops
        // depending on which one the scheduler reaches first. Everything else stays
        // real: a real spawn, a real pipe, the real cap, a real kill.
        await #expect(throws: BridgeExecChannel.ExecError.outputTooLarge) {
            _ = try await BridgeExecChannel.run(
                command: "/usr/bin/yes x",
                stdin: nil,
                timeout: .seconds(30),
                delay: { duration in
                    // The SIGTERM-to-SIGKILL escalation shares this seam and has to
                    // keep running, or the child the cap just terminated is never
                    // reaped. Only the overall timeout is stalled.
                    guard duration == BoundedProcessRunner.terminationEscalation else {
                        // Long, but finite on purpose. A sleep can only ever fire
                        // late, never early, so the cap — which needs about a
                        // millisecond — cannot lose this race under any load. Making
                        // it finite means a broken cap fails the test instead of
                        // hanging it forever.
                        try await Task.sleep(for: .seconds(120))
                        return
                    }
                    try await ContinuousClock().sleep(for: duration)
                }
            )
        }
    }
}
