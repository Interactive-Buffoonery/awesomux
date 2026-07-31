import Foundation
import Testing
@testable import awesoMux

@Suite("Bounded process runner")
struct BoundedProcessRunnerTests {
    @Test("a background child holding stdout is terminated at the timeout")
    func descendantHoldingStdoutDoesNotHang() async {
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: BoundedProcessRunner.ExecError.timedOut) {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                // The descendant outlives the assertion bound below by 20 s. A
                // runner that waits for it to close stdout blows the bound rather
                // than sneaking under it, which is the regression this test exists
                // to catch. It is reaped either way: the child is spawned into its
                // own process group and `terminateThenKill` signals the group.
                arguments: ["-c", "sleep 30 &"],
                input: .data(Data()),
                maximumOutputByteCount: 1024,
                timeout: .milliseconds(50)
            )
        }

        // Sits in the middle of a wide window rather than at the edge of a narrow
        // one. The floor is ~1.05 s — a 50 ms timeout plus the hard second
        // `terminateThenKill` waits between SIGTERM and SIGKILL — and the ceiling
        // is the descendant's 30 s lifetime. The old 2 s bound left under a second
        // of headroom above the escalation and flaked under contention.
        #expect(started.duration(to: clock.now) < .seconds(10))
    }
}
