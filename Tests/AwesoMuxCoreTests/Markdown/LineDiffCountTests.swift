import Testing
@testable import AwesoMuxCore

@Suite("LineDiffCount")
struct LineDiffCountTests {
    @Test(
        arguments: [
            ("a", "a\nb", true, nil), (nil, "a", false, nil), ("a", "a", false, nil),
            (String(repeating: "a", count: LineDiffCount.maxDiffBytes + 1), "a", false, .countUnavailable),
            ("a", String(repeating: "a", count: LineDiffCount.maxDiffBytes + 1), false, .countUnavailable),
            (
                Array(repeating: "old", count: LineDiffCount.maxDiffLines).joined(separator: "\n"),
                Array(repeating: "new", count: LineDiffCount.maxDiffLines).joined(separator: "\n"),
                false, .exact(LineDiffCount(added: 2_000, removed: 2_000))
            ),
            (Array(repeating: "line", count: LineDiffCount.maxDiffLines + 1).joined(separator: "\n"), "line", false, .countUnavailable),
            ("line", Array(repeating: "line", count: LineDiffCount.maxDiffLines + 1).joined(separator: "\n"), false, .countUnavailable),
        ] as [(String?, String, Bool, LineDiffCount.ExternalEdit?)])
    func externalEdits(old: String?, new: String, isSelfWrite: Bool, expected: LineDiffCount.ExternalEdit?) {
        #expect(LineDiffCount.forExternalEdit(old: old, new: new, isSelfWrite: isSelfWrite) == expected)
    }

}
