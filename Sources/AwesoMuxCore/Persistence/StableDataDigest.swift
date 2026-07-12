import CryptoKit
import Foundation

public struct StableDataDigest: Equatable, Sendable {
    private let bytes: [UInt8]

    public init(data: Data) {
        bytes = Array(SHA256.hash(data: data))
    }
}

public struct StableDataDigestWriteGate: Sendable {
    private var lastWrittenDigest: StableDataDigest?

    public init(lastWrittenDigest: StableDataDigest? = nil) {
        self.lastWrittenDigest = lastWrittenDigest
    }

    public func shouldWrite(_ digest: StableDataDigest) -> Bool {
        lastWrittenDigest != digest
    }

    /// Force a write whenever the on-disk snapshot is missing, even if the
    /// in-memory digest still matches. Without this, an externally-deleted
    /// `session-state.json` would never be recreated until the user made a
    /// change — including the `applicationWillTerminate` flush, where the
    /// gate would otherwise leave no restore file at all.
    public func shouldWrite(
        _ digest: StableDataDigest,
        snapshotFileExists: Bool
    ) -> Bool {
        !snapshotFileExists || lastWrittenDigest != digest
    }

    public mutating func recordWritten(_ digest: StableDataDigest) {
        lastWrittenDigest = digest
    }
}
