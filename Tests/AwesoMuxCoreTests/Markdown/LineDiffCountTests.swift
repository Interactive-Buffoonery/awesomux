import Testing
@testable import AwesoMuxCore

@Suite("LineDiffCount")
struct LineDiffCountTests {

    @Test("forExternalEdit suppresses self-writes")
    func gateSuppressesSelfWrites() {
        let count = LineDiffCount.forExternalEdit(
            old: "a",
            new: "a\nb",
            isSelfWrite: true
        )

        #expect(count == nil)
    }

    @Test("forExternalEdit suppresses first load")
    func gateSuppressesFirstLoad() {
        let count = LineDiffCount.forExternalEdit(
            old: nil,
            new: "a",
            isSelfWrite: false
        )

        #expect(count == nil)
    }

    @Test("forExternalEdit suppresses identical content")
    func gateSuppressesIdenticalContent() {
        let count = LineDiffCount.forExternalEdit(
            old: "a",
            new: "a",
            isSelfWrite: false
        )

        #expect(count == nil)
    }

    @Test("forExternalEdit signals oversized inputs without exact counts")
    func gateSignalsOversizedInputsWithoutExactCounts() {
        let huge = String(repeating: "a", count: LineDiffCount.maxDiffBytes + 1)

        #expect(LineDiffCount.forExternalEdit(old: huge, new: "a", isSelfWrite: false) == .countUnavailable)
        #expect(LineDiffCount.forExternalEdit(old: "a", new: huge, isSelfWrite: false) == .countUnavailable)
    }

    @Test("forExternalEdit accepts exactly the line limit")
    func gateAcceptsExactLineLimit() {
        let old = Array(repeating: "old", count: LineDiffCount.maxDiffLines).joined(separator: "\n")
        let new = Array(repeating: "new", count: LineDiffCount.maxDiffLines).joined(separator: "\n")

        #expect(
            LineDiffCount.forExternalEdit(old: old, new: new, isSelfWrite: false)
                == .exact(LineDiffCount(added: 2_000, removed: 2_000))
        )
    }

    @Test("forExternalEdit signals inputs over the line limit without exact counts")
    func gateSignalsInputsOverLineLimitWithoutExactCounts() {
        let tooManyLines = Array(repeating: "line", count: LineDiffCount.maxDiffLines + 1)
            .joined(separator: "\n")

        #expect(
            LineDiffCount.forExternalEdit(old: tooManyLines, new: "line", isSelfWrite: false)
                == .countUnavailable
        )
        #expect(
            LineDiffCount.forExternalEdit(old: "line", new: tooManyLines, isSelfWrite: false)
                == .countUnavailable
        )
    }
}
