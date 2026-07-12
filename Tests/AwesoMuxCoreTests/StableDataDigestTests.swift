import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Stable data digest")
struct StableDataDigestTests {
    @Test("same bytes produce equal digests")
    func sameBytesProduceEqualDigests() {
        let first = StableDataDigest(data: Data("snapshot".utf8))
        let second = StableDataDigest(data: Data("snapshot".utf8))

        #expect(first == second)
    }

    @Test("different bytes produce different digests")
    func differentBytesProduceDifferentDigests() {
        let first = StableDataDigest(data: Data("snapshot".utf8))
        let second = StableDataDigest(data: Data("snapshot changed".utf8))

        #expect(first != second)
    }

    @Test("write gate skips repeated identical digests")
    func writeGateSkipsRepeatedIdenticalDigests() {
        let digest = StableDataDigest(data: Data("snapshot".utf8))
        var gate = StableDataDigestWriteGate()

        #expect(gate.shouldWrite(digest))

        gate.recordWritten(digest)

        #expect(!gate.shouldWrite(digest))
    }

    @Test("write gate resumes writes when digest changes")
    func writeGateResumesWritesWhenDigestChanges() {
        let first = StableDataDigest(data: Data("snapshot".utf8))
        let second = StableDataDigest(data: Data("snapshot changed".utf8))
        let gate = StableDataDigestWriteGate(lastWrittenDigest: first)

        #expect(!gate.shouldWrite(first))
        #expect(gate.shouldWrite(second))
    }

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

    @Test("write gate still writes for new digest regardless of file presence")
    func writeGateWritesForNewDigestRegardlessOfFilePresence() {
        let recorded = StableDataDigest(data: Data("snapshot".utf8))
        let changed = StableDataDigest(data: Data("snapshot changed".utf8))
        let gate = StableDataDigestWriteGate(lastWrittenDigest: recorded)

        #expect(gate.shouldWrite(changed, snapshotFileExists: true))
        #expect(gate.shouldWrite(changed, snapshotFileExists: false))
    }
}
