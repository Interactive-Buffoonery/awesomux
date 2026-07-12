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
        await #expect(throws: BridgeExecChannel.ExecError.outputTooLarge) {
            _ = try await BridgeExecChannel.run(
                command: "/usr/bin/yes x",
                stdin: nil,
                timeout: .seconds(2)
            )
        }
    }
}
