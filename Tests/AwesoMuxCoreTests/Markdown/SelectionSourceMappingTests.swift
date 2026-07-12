// Tests/AwesoMuxCoreTests/Markdown/SelectionSourceMappingTests.swift
import Testing
@testable import AwesoMuxCore

@Suite("SelectionSourceMapping")
struct SelectionSourceMappingTests {
    private func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: Array(s.utf8)[r], as: UTF8.self) }

    @Test("sub-word selection inside one precise run maps exactly")
    func subWord() {
        let src = "fix the loader now"   // rendered == source (all plain)
        let doc = AttributedMarkdownBuilder.build(src)
        // select "loa" (utf16 8..<11)
        let span = try! #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 8..<11, in: doc))
        #expect(sub(src, span) == "loa")
    }

    @Test("selection crossing markup snaps to whole constructs — never splits the syntax")
    func crossingMarkupSnaps() {
        let src = "a **b** c"   // rendered "a b c"
        let doc = AttributedMarkdownBuilder.build(src)
        // select rendered "b c" = utf16 2..<5
        let span = try! #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 2..<5, in: doc))
        let wrapped = sub(src, span)
        // must be a markup-safe span: the bold construct is whole, NOT "b** c"
        #expect(wrapped == "**b** c")
        #expect(!wrapped.hasPrefix("b**"))   // the corruption case is gone
    }

    @Test("selection inside inline code snaps to the whole code span")
    func codeWholeNode() {
        let src = "see `foo` ok"
        let doc = AttributedMarkdownBuilder.build(src)
        // any selection touching the code maps to "`foo`"
        let span = try! #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 4..<6, in: doc))
        #expect(sub(src, span) == "`foo`")
    }

    @Test("synthetic-only or empty selection yields nil")
    func nilCases() {
        let doc = AttributedMarkdownBuilder.build("- a\n- b")
        #expect(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 0..<2, in: doc) == nil)  // a bullet
        #expect(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 3..<3, in: doc) == nil)  // empty
    }

    @Test("cross-block selection spanning a paragraph break yields nil")
    func crossBlockYieldsNil() {
        // Two paragraphs separated by a blank line. Selecting text that spans both
        // paragraphs must return nil — a <mark> cannot span a CommonMark block boundary.
        let src = "alpha\n\nbeta"
        let doc = AttributedMarkdownBuilder.build(src)
        // "alpha" renders at utf16 0..<5; "beta" renders after the \n\n separator run.
        // Select from inside "alpha" (utf16 3) into "beta" (utf16 ends after sep+4 = 9).
        // The rendered layout is: "alpha"(5) + "\n\n"(2) + "beta"(4) = indices 0..10.
        // Pick a range that straddles both words: 3..<9 (alpha→bet).
        let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: 3..<9, in: doc)
        #expect(span == nil)
    }

    @Test("spanTouchesExistingMark detects overlap with commented runs")
    func touchesExistingMark() {
        // "see <mark>this</mark><!-- USER COMMENT 1: x --> ok"
        // Rendered text: "see this ok" (mark/comment nodes are consumed, not emitted as runs).
        // "this" occupies rendered UTF-16 positions 4..<8.
        // The source offsets of "this" are 12..<16 (after "see <mark>", 10 chars).
        let src = "see <mark>this</mark><!-- USER COMMENT 1: x --> ok"
        let doc = AttributedMarkdownBuilder.build(src)

        // Locate the source span of "this" by mapping the rendered selection for it.
        // "see " = 4 chars (utf16 0..<4), "this" = 4 chars (utf16 4..<8).
        let thisSpan = SelectionSourceMapping.sourceSpan(forSelectedUTF16: 4..<8, in: doc)
        let thisSourceSpan = try! #require(thisSpan, "expected a valid span for 'this'")

        // The span for "this" should touch the existing mark → true.
        #expect(SelectionSourceMapping.spanTouchesExistingMark(thisSourceSpan, in: doc) == true)

        // The span for "see" (utf16 0..<3 → source 0..<3) must NOT touch the mark.
        let seeSpan = try! #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 0..<3, in: doc))
        #expect(SelectionSourceMapping.spanTouchesExistingMark(seeSpan, in: doc) == false)

        // The span for " ok" (utf16 8..<11 → source after the comment) must NOT touch the mark.
        let okSpan = try! #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 9..<11, in: doc))
        #expect(SelectionSourceMapping.spanTouchesExistingMark(okSpan, in: doc) == false)
    }

    @Test("adjacent-but-not-overlapping spans do not trip the nested-mark check")
    func adjacentSpansDoNotTouch() {
        // Classic off-by-one trap for range-overlap logic: a selection that
        // ends exactly where a mark starts (or starts exactly where it ends)
        // is adjacent, not nested, and must stay annotatable.
        let src = "see <mark>this</mark><!-- USER COMMENT 1: x --> ok"
        let doc = AttributedMarkdownBuilder.build(src)
        // "this" occupies source bytes 10..<14 (after "see <mark>").
        #expect(SelectionSourceMapping.spanTouchesExistingMark(4 ..< 10, in: doc) == false)
        #expect(SelectionSourceMapping.spanTouchesExistingMark(14 ..< 18, in: doc) == false)
        // One byte of overlap on either edge trips it.
        #expect(SelectionSourceMapping.spanTouchesExistingMark(9 ..< 11, in: doc) == true)
        #expect(SelectionSourceMapping.spanTouchesExistingMark(13 ..< 15, in: doc) == true)
    }

    @Test("within-paragraph selection across a soft break still maps (no over-bail)")
    func softBreakDoesNotBlock() {
        // A single paragraph with a soft line break: "a\nb" in source renders as "a b"
        // (SoftBreak → " "). Selecting across the soft break must still return a span.
        let src = "a\nb"
        let doc = AttributedMarkdownBuilder.build(src)
        // Rendered: "a"(utf16 0..<1) + " "(utf16 1..<2, soft break, synthetic) + "b"(utf16 2..<3).
        // Select "a b" (0..<3) — spans the soft break but stays within one paragraph.
        // The soft-break run has text " " (not "\n\n"), so the block-boundary guard must not fire.
        let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: 0..<3, in: doc)
        #expect(span != nil)
    }

    // MARK: - Scroll-anchor mapping (INT-567)

    @Test("mid-paragraph anchor maps to its own byte offset, not the paragraph start")
    func midParagraphAnchorIsPrecise() {
        let src = "one two three four five"   // single precise run, ASCII 1:1
        let doc = AttributedMarkdownBuilder.build(src)
        let offset = try! #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 8, in: doc))
        #expect(offset == 8)   // the regression this issue is about: was always 0 (run start)
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 8, in: doc) == 8)
    }

    @Test("round-trip holds at run start and last character")
    func roundTripAtBoundaries() {
        let src = "one two three four five"
        let doc = AttributedMarkdownBuilder.build(src)
        for idx in [0, 22] {
            let byte = try! #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: idx, in: doc))
            #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: byte, in: doc) == idx)
        }
    }

    @Test("multi-byte content round-trips; mid-surrogate and mid-scalar floor to boundary")
    func multiByteAndSurrogateFloor() {
        let src = "héllo 👋 wörld"   // é=2B/1u, 👋=4B/2u (surrogate pair), ö=2B/1u
        let doc = AttributedMarkdownBuilder.build(src)
        // "w" is rendered utf16 index 9; bytes before it: héllo(7 incl. space)... h1+é2+l1+l1+o1+sp1 = 7, +👋4+sp1 = 12.
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 9, in: doc) == 12)
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 12, in: doc) == 9)
        // Mid-surrogate capture index (7 = low half of 👋) floors to the emoji start (byte 7).
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 7, in: doc)
                == SelectionSourceMapping.sourceOffset(forRenderedUTF16: 6, in: doc))
        // Mid-scalar byte target (9 = inside 👋's 4 bytes) floors to the emoji's rendered start (6).
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 9, in: doc) == 6)
    }

    @Test("imprecise run (inline code) maps approximately within the run and round-trips")
    func impreciseRunApproximateMapping() {
        let src = "see `foo` ok"   // code run sourceRange covers the backticks → imprecise
        let doc = AttributedMarkdownBuilder.build(src)
        // Rendered "see foo ok": 'o' at utf16 5 → decoded-walk byte 4+1 = 5 (one byte
        // shy of the true 'o' at 6 — the backtick drift the approximation accepts).
        let byte = try! #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 5, in: doc))
        #expect(byte == 5)
        // Round-trip on the unchanged doc is exact — the reverse walk is the same math.
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: byte, in: doc) == 5)
        // Result stays inside the run's source range even at the rendered run end.
        let lastCodeChar = try! #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 6, in: doc))
        #expect((4..<9).contains(lastCodeChar))
    }

    @Test("one entity does not throw a long paragraph back to its start")
    func entityParagraphKeepsIntraRunAnchoring() {
        // The whole paragraph is ONE imprecise run (entity decode shortens it) —
        // snapping imprecise runs to their start would reintroduce the INT-567 bug
        // for any paragraph containing a single &amp;.
        let tail = (1...80).map { "w\($0)" }.joined(separator: " ")
        let doc = AttributedMarkdownBuilder.build("aaa &amp; \(tail)")
        let target = 40   // rendered index deep in the tail
        let byte = try! #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: target, in: doc))
        #expect(byte > 10, "anchor must not collapse to the paragraph start")
        // Round-trip on the unchanged document is exact despite the entity drift.
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: byte, in: doc) == target)
    }

    @Test("synthetic run (bullet) anchors to the next source-bearing run")
    func syntheticRunAnchorsToNextContent() {
        // Capture at viewport x=0 on a list line lands on the synthetic bullet run;
        // returning nil there would drop the anchor for every list-top position.
        let doc = AttributedMarkdownBuilder.build("- alpha")
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 0, in: doc) == 2)
        // First real character after the bullet maps directly.
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 2, in: doc) == 2)
        // A trailing synthetic run with nothing after it still yields nil.
        let sep = AttributedMarkdownBuilder.build("alpha\n\n---")
        // Assert the structural premise directly so a builder change can't silently
        // skip (or wrongly fail) the nil assertion below.
        #expect(sep.runs.last?.sourceRange == nil, "test premise: doc must end in a synthetic run")
        let renderedLen = sep.runs.map { $0.text.utf16.count }.reduce(0, +)
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: renderedLen - 1, in: sep) == nil)
    }

    @Test("gap fallback: byte in a block or markup gap lands at the preceding run's rendered end")
    func gapFallbackPrefersPrecedingRun() {
        // Blank-line gap between paragraphs: bytes 5..6 belong to no run.
        let para = AttributedMarkdownBuilder.build("alpha\n\nbeta")
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 6, in: para) == 5)
        // Exactly at a run's upperBound (also uncontained).
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 5, in: para) == 5)
        // Markup-delimiter gap inside one paragraph: the ** bytes before "bold".
        let bold = AttributedMarkdownBuilder.build("text **bold**")
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 6, in: bold) == 5)
        // Past the end of the document (stale anchor after truncation) → last run's rendered end.
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 1000, in: para) == 11)
    }

    // MARK: - Tables (INT-566)

    /// Rendered UTF-16 range of the run whose text equals `cellText`.
    private func renderedRange(ofCellText cellText: String, in doc: RenderedDocument) -> Range<Int>? {
        var cursor = 0
        for run in doc.runs {
            let len = run.text.utf16.count
            if run.text == cellText, run.style.tableCellPosition != nil {
                return cursor..<(cursor + len)
            }
            cursor += len
        }
        return nil
    }

    @Test("a single table cell is commentable — selection maps to that cell's source")
    func singleCellMaps() throws {
        let src = "| A | B |\n| - | - |\n| xx | y |"
        let doc = AttributedMarkdownBuilder.build(src)
        let range = try #require(renderedRange(ofCellText: "xx", in: doc))
        let span = try #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: range, in: doc))
        #expect(sub(src, span) == "xx")
    }

    @Test("selection spanning two columns in a row is rejected")
    func crossColumnRejected() throws {
        let src = "| A | B |\n| - | - |\n| x | y |"
        let doc = AttributedMarkdownBuilder.build(src)
        let x = try #require(renderedRange(ofCellText: "x", in: doc))
        let y = try #require(renderedRange(ofCellText: "y", in: doc))
        // Select from the start of "x" to the end of "y" — crosses the `\t` and the `|`.
        let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: x.lowerBound..<y.upperBound, in: doc)
        #expect(span == nil)
    }

    @Test("selection spanning two rows is rejected")
    func crossRowRejected() throws {
        let src = "| A | B |\n| - | - |\n| x | y |"
        let doc = AttributedMarkdownBuilder.build(src)
        // Header "A" (row 0) to body "x" (row 1) — crosses the row `\n`.
        let a = try #require(renderedRange(ofCellText: "A", in: doc))
        let x = try #require(renderedRange(ofCellText: "x", in: doc))
        let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: a.lowerBound..<x.upperBound, in: doc)
        #expect(span == nil)
    }

    @Test("before the first real run, negative, and empty-doc inputs yield nil")
    func anchorNilCases() {
        // "---" emits no run; target inside it has no preceding run → nil (restore no-ops at top).
        let doc = AttributedMarkdownBuilder.build("---\n\nalpha")
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 1, in: doc) == nil)
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: -1, in: doc) == nil)
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: -1, in: doc) == nil)
        let empty = AttributedMarkdownBuilder.build("")
        #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: 0, in: empty) == nil)
        #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: 0, in: empty) == nil)
    }
}
