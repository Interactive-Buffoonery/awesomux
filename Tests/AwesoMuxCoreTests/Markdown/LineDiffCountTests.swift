import Testing
@testable import AwesoMuxCore

@Suite("LineDiffCount")
struct LineDiffCountTests {
    @Test("between counts added-only lines")
    func addedOnly() {
        let count = LineDiffCount.between("a\nb", "a\nb\nc")

        #expect(count == LineDiffCount(added: 1, removed: 0))
    }

    @Test("between counts removed-only lines")
    func removedOnly() {
        let count = LineDiffCount.between("a\nb\nc", "a\nb")

        #expect(count == LineDiffCount(added: 0, removed: 1))
    }

    @Test("between counts mixed added and removed lines")
    func mixedAddAndRemove() {
        let count = LineDiffCount.between("a\nb\nc", "a\nx\nc\ny")

        #expect(count == LineDiffCount(added: 2, removed: 1))
    }

    @Test("between returns empty for identical strings")
    func identicalStrings() {
        let count = LineDiffCount.between("a\nb", "a\nb")

        #expect(count.isEmpty)
    }

    @Test("between counts empty-to-content as pure addition")
    func emptyToContent() {
        let count = LineDiffCount.between("", "a")

        #expect(count == LineDiffCount(added: 1, removed: 0))
    }

    @Test("between counts content-to-empty as pure removal")
    func contentToEmpty() {
        let count = LineDiffCount.between("a\nb", "")

        #expect(count == LineDiffCount(added: 0, removed: 2))
    }

    @Test("between preserves trailing-newline edge cases")
    func trailingNewline() {
        let count = LineDiffCount.between("a", "a\n")

        #expect(count == LineDiffCount(added: 1, removed: 0))
    }

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

    @Test("forExternalEdit returns counts for genuine external edits")
    func gateReturnsExternalEditCounts() {
        let count = LineDiffCount.forExternalEdit(
            old: "a\nb",
            new: "a\nb\nc",
            isSelfWrite: false
        )

        #expect(count == LineDiffCount(added: 1, removed: 0))
    }

    @Test("forExternalEdit suppresses oversized inputs")
    func gateSuppressesOversizedInputs() {
        let huge = String(repeating: "a", count: LineDiffCount.maxDiffBytes + 1)

        #expect(LineDiffCount.forExternalEdit(old: huge, new: "a", isSelfWrite: false) == nil)
        #expect(LineDiffCount.forExternalEdit(old: "a", new: huge, isSelfWrite: false) == nil)
    }
}
