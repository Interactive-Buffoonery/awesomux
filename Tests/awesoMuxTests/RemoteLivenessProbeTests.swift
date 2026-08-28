import Foundation
import Testing
@testable import awesoMux

@Suite("Remote liveness probe")
struct RemoteLivenessProbeTests {
    @Test("strict parser accepts one bounded version-one object")
    func acceptsValidObject() throws {
        #expect(
            try RemoteLivenessProbe.decode(
                Data(#"{"state":"idle-shell","v":1,"comm":"zsh","hasChildren":false}"#.utf8)
            ) == .idleShell
        )
    }

    @Test(
        "strict parser rejects contamination and extra objects",
        arguments: [
            "banner\\n{\"v\":1,\"state\":\"idle-shell\"}",
            "{\"v\":1,\"state\":\"idle-shell\"} trailing",
            "{\"v\":1,\"state\":\"idle-shell\"}{\"v\":1,\"state\":\"busy-shell\"}",
            " {\"v\":1,\"state\":\"idle-shell\"}",
        ]
    )
    func rejectsContamination(output: String) {
        #expect(throws: RemoteLivenessProbe.Failure.malformedOutput) {
            try RemoteLivenessProbe.decode(Data(output.utf8))
        }
    }

    @Test("strict parser rejects unsupported versions and oversized output")
    func rejectsVersionAndSize() {
        #expect(throws: RemoteLivenessProbe.Failure.unsupportedVersion) {
            try RemoteLivenessProbe.decode(Data(#"{"v":2,"state":"idle-shell"}"#.utf8))
        }
        #expect(throws: RemoteLivenessProbe.Failure.malformedOutput) {
            try RemoteLivenessProbe.decode(Data(repeating: 0x7B, count: 513))
        }
    }
}
