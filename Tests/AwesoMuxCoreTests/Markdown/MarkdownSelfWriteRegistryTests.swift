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

    @Test("writes sweep expired entries and retain the exact validity boundary", arguments: [false, true])
    func writeSweepsEntriesNoReaderWillEverExpire(atBoundary: Bool) {
        var registry = MarkdownSelfWriteRegistry(validityInterval: .seconds(5))
        let closedTab = URL(fileURLWithPath: "/tmp/awesomux-closed.md")
        registry.record(fileURL: closedTab, source: "big source", at: now)
        #expect(registry.entryCountForTesting == 1)

        let writeTime = now.advanced(by: .seconds(atBoundary ? 5 : 6))
        registry.record(fileURL: url, source: "other", at: writeTime)

        #expect(registry.entryCountForTesting == (atBoundary ? 2 : 1))
        if atBoundary {
            #expect(
                registry.context(fileURL: closedTab, onDiskSource: "big source", at: writeTime)
                    == MarkdownSelfWriteContext(source: "big source", isSelfWrite: true))
        }
    }
}
