import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Stable data digest")
struct StableDataDigestTests {

    @Test("write gate forces a write when the snapshot file is missing")
    func writeGateForcesWriteWhenSnapshotFileIsMissing() {
        let digest = StableDataDigest(data: Data("snapshot".utf8))
        let gate = StableDataDigestWriteGate(lastWrittenDigest: digest)

        // Same digest, file present: skip is correct.
        #expect(!gate.shouldWrite(digest, snapshotFileExists: true))
        // Same digest, file gone: must write — otherwise an externally-
        // deleted session-state.json never gets recreated and the
        // terminate-time flush leaves no restore file.
        #expect(gate.shouldWrite(digest, snapshotFileExists: false))
    }

}
