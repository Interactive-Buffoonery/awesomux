import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct RemoteForegroundLivenessReportTests {
    @Test func encodingIsBoundedAndRoundTripsEveryState() throws {
        for state in [
            RemoteForegroundLivenessReport.State.idleShell,
            .busyShell,
            .liveCommand,
            .indeterminate,
            .gone,
        ] {
            let report = RemoteForegroundLivenessReport(
                state: state,
                comm: "zsh",
                hasChildren: false
            )
            let data = try report.encoded()
            #expect(data.count <= RemoteForegroundLivenessReport.maximumEncodedByteCount)
            #expect(try JSONDecoder().decode(RemoteForegroundLivenessReport.self, from: data) == report)
        }
    }

    @Test func encodingRejectsOversizedCommand() {
        let report = RemoteForegroundLivenessReport(
            state: .liveCommand,
            comm: String(repeating: "x", count: 600)
        )
        #expect(throws: EncodingError.self) {
            try report.encoded()
        }
    }
}
