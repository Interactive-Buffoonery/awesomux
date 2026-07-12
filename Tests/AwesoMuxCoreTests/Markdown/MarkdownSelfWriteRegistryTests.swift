import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownSelfWriteRegistry")
struct MarkdownSelfWriteRegistryTests {
    private let url = URL(fileURLWithPath: "/tmp/awesomux-plan.md")
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("recorded matching source is treated as self-write")
    func matchingRecordedWriteSuppresses() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", now: now)

        let context = registry.context(fileURL: url, onDiskSource: "self", now: now)

        #expect(context == MarkdownSelfWriteContext(source: "self", isSelfWrite: true))
    }

    @Test("matching source is not consumed by first reader")
    func secondIndependentReaderAlsoSuppresses() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", now: now)

        _ = registry.context(fileURL: url, onDiskSource: "self", now: now)
        let secondRead = registry.context(fileURL: url, onDiskSource: "self", now: now)

        #expect(secondRead == MarkdownSelfWriteContext(source: "self", isSelfWrite: true))
    }

    @Test("new write supersedes previous source for same file")
    func supersedingWriteReplacesPriorEntry() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "first", now: now)
        registry.record(fileURL: url, source: "second", now: now.addingTimeInterval(1))

        let secondMatch = registry.context(
            fileURL: url,
            onDiskSource: "second",
            now: now.addingTimeInterval(1)
        )
        let oldContent = registry.context(
            fileURL: url,
            onDiskSource: "first",
            now: now.addingTimeInterval(1)
        )

        #expect(secondMatch == MarkdownSelfWriteContext(source: "second", isSelfWrite: true))
        #expect(oldContent == MarkdownSelfWriteContext(source: "second", isSelfWrite: false))
    }

    @Test("entry expires after validity interval")
    func expiryPolicyTakesEffect() {
        var registry = MarkdownSelfWriteRegistry(validityInterval: 5)
        registry.record(fileURL: url, source: "self", now: now)

        let expired = registry.context(
            fileURL: url,
            onDiskSource: "self",
            now: now.addingTimeInterval(6)
        )

        #expect(expired == nil)
    }

    @Test("non-matching source is external but keeps self-write baseline")
    func nonMatchingContentIsExternal() {
        var registry = MarkdownSelfWriteRegistry()
        registry.record(fileURL: url, source: "self", now: now)

        let context = registry.context(fileURL: url, onDiskSource: "external", now: now)

        #expect(context == MarkdownSelfWriteContext(source: "self", isSelfWrite: false))
    }
}
