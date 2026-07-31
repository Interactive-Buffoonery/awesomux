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
                // `sh` exits at once; the backgrounded child inherits stdout and
                // holds it for 30 s. A runner that waits for the pipe to close
                // instead of honouring its own timeout blows the bound below by a
                // wide margin rather than creeping past it.
                arguments: ["-c", "sleep 30 &"],
                input: .data(Data()),
                maximumOutputByteCount: 1024,
                timeout: .milliseconds(50),
                // Both the timeout and the SIGTERM-to-SIGKILL escalation return
                // immediately, so a correct runner finishes in well under a second
                // and the bound carries no scheduling slop to absorb.
                delay: { _ in }
            )
        }

        #expect(started.duration(to: clock.now) < .seconds(5))
    }
}
