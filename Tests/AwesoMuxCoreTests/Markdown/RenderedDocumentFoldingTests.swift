import Testing
@testable import AwesoMuxCore

@Suite("RenderedDocument folding")
struct RenderedDocumentFoldingTests {
    private func run(_ text: String, _ style: RunStyle = .body, source: Range<Int>? = nil) -> RenderedRun {
        RenderedRun(text: text, style: style, sourceRange: source, enclosingRange: source, preciseMapping: source != nil)
    }
    private func doc(_ runs: [RenderedRun]) -> RenderedDocument {
        RenderedDocument(source: "src", runs: runs, annotations: [], taskProgress: TaskProgress(done: 0, total: 0))
    }

    @Test("removed ranges drop those runs and keep the others byte-identical")
    func removesRanges() {
        let d = doc([
            run("h", .heading(level: 2), source: 0..<1), run("\n", .blockSeparator), run("+a", .diffLine(.added), source: 5..<7),
            run("\n", .blockSeparator), run("tail", source: 9..<13),
        ])
        let folded = d.folding(removingRunRanges: [2..<4])
        #expect(folded.runs.map(\.text) == ["h", "\n", "tail"])
        #expect(folded.runs[2].sourceRange == 9..<13)
        #expect(folded.runs[2].preciseMapping == true)
        #expect(folded.source == d.source)
    }

    @Test("an empty range list is the identity")
    func identity() {
        let d = doc([run("a"), run("b")])
        #expect(d.folding(removingRunRanges: []).runs == d.runs)
    }

    @Test("out-of-bounds and overlapping ranges are clamped and unioned")
    func clampsAndUnions() {
        let d = doc([run("a"), run("b"), run("c"), run("d")])
        let folded = d.folding(removingRunRanges: [1..<3, 2..<10, (-4)..<0])
        #expect(folded.runs.map(\.text) == ["a"])
    }

    @Test("the joined text of the folded document equals the joined text of the kept runs")
    func joinedTextInvariant() {
        let d = doc([run("x"), run("y"), run("z")])
        let folded = d.folding(removingRunRanges: [1..<2])
        #expect(folded.runs.map(\.text).joined() == "xz")
    }
}
