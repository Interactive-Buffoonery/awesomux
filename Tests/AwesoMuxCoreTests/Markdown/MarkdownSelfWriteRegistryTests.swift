import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownSelfWriteRegistry")
struct MarkdownSelfWriteRegistryTests {
    private let url = URL(fileURLWithPath: "/tmp/awesomux-plan.md")
    private let now = ContinuousClock.now

    @Test(
        arguments: [
            (["self"], ["self"], 0, [MarkdownSelfWriteContext(source: "self", isSelfWrite: true)]),
            (["self"], ["self", "self"], 0, [.init(source: "self", isSelfWrite: true), .init(source: "self", isSelfWrite: true)]),
            (
                ["first", "second"], ["second", "first"], 1,
                [.init(source: "second", isSelfWrite: true), .init(source: "second", isSelfWrite: false)]
            ),
            (["self"], ["self"], 6, [nil]),
            (["self"], ["external"], 0, [.init(source: "self", isSelfWrite: false)]),
        ] as [([String], [String], Int, [MarkdownSelfWriteContext?])])
    func contexts(writes: [String], reads: [String], seconds: Int, expected: [MarkdownSelfWriteContext?]) {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        for (index, source) in writes.enumerated() {
            registry.record(fileURL: url, source: source, at: now.advanced(by: .seconds(index)))
        }
        let results = reads.map { registry.context(fileURL: url, onDiskSource: $0, at: now.advanced(by: .seconds(seconds))) }
        #expect(results == expected)
    }

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
