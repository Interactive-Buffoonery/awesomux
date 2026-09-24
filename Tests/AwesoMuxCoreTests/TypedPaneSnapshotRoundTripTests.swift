import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct TypedPaneSnapshotRoundTripTests {
    @Test func malformedRemotePlanFailsLoudNeverDegradesToLocal() throws {
        // INT-775 contract preserved: a plan tagged ssh but missing its target
        // must throw, not silently decode as a local pane.
        let json = """
            {"kind":"ssh"}
            """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneExecutionPlan.self, from: Data(json.utf8))
        }
    }
}
