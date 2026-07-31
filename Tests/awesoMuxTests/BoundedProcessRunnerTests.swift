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
                arguments: ["-c", "sleep 5 &"],
                input: .data(Data()),
                maximumOutputByteCount: 1024,
                timeout: .milliseconds(50)
            )
        }

        // Not a latency budget: `terminateThenKill` waits a hard second between
        // SIGTERM and SIGKILL, so a 50 ms timeout plus that escalation plus
        // scheduling can legitimately approach two seconds under contention. The
        // bound only has to prove the child does not outlive the runner.
        #expect(started.duration(to: clock.now) < .seconds(10))
    }
}
