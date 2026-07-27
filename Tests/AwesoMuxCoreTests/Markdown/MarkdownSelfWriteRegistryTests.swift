import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("MarkdownSelfWriteRegistry")
struct MarkdownSelfWriteRegistryTests {
    private let url = URL(fileURLWithPath: "/tmp/awesomux-plan.md")
    private let now = ContinuousClock.now

    @Test("recorded matching source is treated as self-write")
    func matchingRecordedWriteSuppresses() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", at: now)

        let context = registry.context(fileURL: url, onDiskSource: "self", at: now)

        #expect(context == MarkdownSelfWriteContext(source: "self", isSelfWrite: true))
    }

    @Test("matching source is not consumed by first reader")
    func secondIndependentReaderAlsoSuppresses() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", at: now)

        _ = registry.context(fileURL: url, onDiskSource: "self", at: now)
        let secondRead = registry.context(fileURL: url, onDiskSource: "self", at: now)

        #expect(secondRead == MarkdownSelfWriteContext(source: "self", isSelfWrite: true))
    }

    @Test("new write supersedes previous source for same file")
    func supersedingWriteReplacesPriorEntry() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "first", at: now)
        registry.record(fileURL: url, source: "second", at: now.advanced(by: .seconds(1)))

        let secondMatch = registry.context(
            fileURL: url,
            onDiskSource: "second",
            at: now.advanced(by: .seconds(1))
        )
        let oldContent = registry.context(
            fileURL: url,
            onDiskSource: "first",
            at: now.advanced(by: .seconds(1))
        )

        #expect(secondMatch == MarkdownSelfWriteContext(source: "second", isSelfWrite: true))
        #expect(oldContent == MarkdownSelfWriteContext(source: "second", isSelfWrite: false))
    }

    @Test("entry expires after validity interval")
    func expiryPolicyTakesEffect() {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        registry.record(fileURL: url, source: "self", at: now)

        let expired = registry.context(
            fileURL: url,
            onDiskSource: "self",
            at: now.advanced(by: .seconds(6))
        )

        #expect(expired == nil)
    }

    @Test("non-matching source is external but keeps self-write baseline")
    func nonMatchingContentIsExternal() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", at: now)

        let context = registry.context(fileURL: url, onDiskSource: "external", at: now)

        #expect(context == MarkdownSelfWriteContext(source: "self", isSelfWrite: false))
    }

    /// A closed tab's path is never read again, so read-time expiry never runs
    /// for it. Asserted on `entryCountForTesting` rather than `context(…)`,
    /// which reports nil for a stale entry whether or not the source was
    /// released — the bug this covers is retained bytes, not a wrong answer.
    ///
    /// This is the one test that goes red without the sweep.
    @Test("a stale entry is dropped by a later write to a different file")
    func writeSweepsEntriesNoReaderWillEverExpire() {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        let closedTab = URL(fileURLWithPath: "/tmp/awesomux-closed.md")
        registry.record(fileURL: closedTab, source: "big source", at: now)
        #expect(registry.entryCountForTesting == 1)

        registry.record(fileURL: url, source: "other", at: now.advanced(by: .seconds(6)))

        #expect(
            registry.entryCountForTesting == 1,
            "the stale entry should have been swept, leaving only the new write"
        )
    }

    /// Non-regression guard, not evidence of the sweep: this passes on the
    /// unfixed code too. It exists to catch an over-eager sweep — an inverted
    /// comparison, or one that takes live entries with it.
    @Test("a write inside the validity window keeps both entries")
    func writeSweepSparesLiveEntries() {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        let other = URL(fileURLWithPath: "/tmp/awesomux-other.md")
        registry.record(fileURL: other, source: "still fresh", at: now)

        registry.record(fileURL: url, source: "new", at: now.advanced(by: .seconds(1)))

        #expect(registry.entryCountForTesting == 2)
        #expect(
            registry.context(
                fileURL: other,
                onDiskSource: "still fresh",
                at: now.advanced(by: .seconds(1))
            ) == MarkdownSelfWriteContext(source: "still fresh", isSelfWrite: true)
        )
    }

    /// The sweep and the read must agree at the exact boundary. If one is ever
    /// tidied from `<=` to `<` while the other is not, `record` starts evicting
    /// entries `context(…)` still honors and a background tab announces the
    /// user's own save as an external edit — with every other test still green.
    /// Both assertions below sit exactly `validityInterval` after the write.
    @Test("an entry aged exactly the validity interval survives both the sweep and the read")
    func sweepAndReadAgreeAtTheBoundary() {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        let other = URL(fileURLWithPath: "/tmp/awesomux-other.md")
        registry.record(fileURL: other, source: "boundary", at: now)
        let boundary = now.advanced(by: .seconds(5))

        registry.record(fileURL: url, source: "new", at: boundary)

        #expect(
            registry.entryCountForTesting == 2,
            "the sweep must not drop an entry aged exactly the validity interval"
        )
        #expect(
            registry.context(fileURL: other, onDiskSource: "boundary", at: boundary)
                == MarkdownSelfWriteContext(source: "boundary", isSelfWrite: true),
            "the read must still honor an entry aged exactly the validity interval"
        )
    }
}
