import Foundation

public struct MarkdownSelfWriteContext: Equatable, Sendable {
    public let source: String
    public let isSelfWrite: Bool

    public init(source: String, isSelfWrite: Bool) {
        self.source = source
        self.isSelfWrite = isSelfWrite
    }
}

public struct MarkdownSelfWriteRegistry: Sendable {
    public static let defaultValidityInterval: Duration = .seconds(5)

    private let validityInterval: Duration
    private var entries: [String: Entry] = [:]

    public init(validityInterval: Duration = Self.defaultValidityInterval) {
        self.validityInterval = validityInterval
    }

    public mutating func record(
        fileURL: URL,
        source: String,
        at now: ContinuousClock.Instant = .now
    ) {
        // Sweep before inserting: `context(fileURL:onDiskSource:at:)` only
        // expires the path it is asked about, so a file whose tab closes is
        // never asked about again and would keep a full document source alive.
        //
        // ponytail: write-triggered only, so this bounds *growth* — not
        // lifetime. The most recent write's entry (plus anything recorded
        // within one validity interval of it) stays resident until the next
        // write or process exit. Draining that residual needs a tab-close hook,
        // and the obvious one is wrong: `selfWriteRegistry` is a process-wide
        // static shared across every group, so pruning it against a single
        // `DocumentGroupView`'s tabs would drop entries for files still open
        // elsewhere. Upgrade path is a prune keyed on the union of open
        // document paths from `SessionStore`.
        entries = entries.filter { isLive($0.value, at: now) }
        entries[Self.key(for: fileURL)] = Entry(source: source, recordedAt: now)
    }

    public mutating func context(
        fileURL: URL,
        onDiskSource: String,
        at now: ContinuousClock.Instant = .now
    ) -> MarkdownSelfWriteContext? {
        let key = Self.key(for: fileURL)
        guard let entry = entries[key] else { return nil }
        guard isLive(entry, at: now) else {
            entries[key] = nil
            return nil
        }
        return MarkdownSelfWriteContext(
            source: entry.source,
            isSelfWrite: entry.source == onDiskSource
        )
    }

    /// The single expiry rule, shared by the sweep and the read.
    ///
    /// Both callers must agree exactly: if the sweep were ever stricter than
    /// the read, `record` would drop an entry `context(fileURL:onDiskSource:at:)`
    /// still honors, and a background tab would report the user's own save as
    /// somebody else's edit — announced aloud to a VoiceOver user who has no
    /// way to check. One rule, one place, so the two cannot drift apart.
    private func isLive(_ entry: Entry, at now: ContinuousClock.Instant) -> Bool {
        now - entry.recordedAt <= validityInterval
    }

    /// Live entry count, for tests that assert the sweep actually drops
    /// sources. Expiry is invisible through `context(fileURL:onDiskSource:at:)`,
    /// which reports nil for a stale entry whether or not the bytes were
    /// released — so a test written against the public surface alone would pass
    /// on the unfixed code.
    var entryCountForTesting: Int { entries.count }

    private static func key(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

    /// `recordedAt` is a monotonic instant, not a `Date`, and that is
    /// load-bearing rather than stylistic. Wall-clock age is an *input* the
    /// process does not control: an NTP correction or a wake-from-sleep resync
    /// can step it in either direction. A forward step at write time followed
    /// by a correction backward made the sweep evict an entry that a slightly
    /// later read still had to honor — turning a self-write into a spurious
    /// external-edit announcement. A backward step held dead entries past the
    /// window instead, because a negative interval trivially satisfies `<=`.
    /// `ContinuousClock` has no excursion to follow, so neither state is
    /// representable. (This repo has been bitten by `Date`-as-a-duration
    /// before — see the note at `NewWorkspaceSplitButton.swift`.)
    private struct Entry: Sendable {
        let source: String
        let recordedAt: ContinuousClock.Instant
    }
}
