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

        #expect(started.duration(to: clock.now) < .seconds(2))
    }
}
