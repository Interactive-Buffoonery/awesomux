import Testing
@testable import AwesoMuxCore

@Suite("SelectionSourceMapping")
struct SelectionSourceMappingTests {
    private func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: Array(s.utf8)[r], as: UTF8.self) }

    @Test(
        arguments: [
            ("fix the loader now", 8..<11, "loa"),
            ("a **b** c", 2..<5, "**b** c"), ("see `foo` ok", 4..<6, "`foo`"),
            ("- a\n- b", 0..<2, nil), ("- a\n- b", 3..<3, nil),
            ("alpha\n\nbeta", 3..<9, nil), ("a\nb", 0..<3, "a\nb"),
            ("| A | B |\n| - | - |\n| xx | y |", 4..<6, "xx"),
            ("| A | B |\n| - | - |\n| x | y |", 4..<7, nil),
            ("| A | B |\n| - | - |\n| x | y |", 0..<5, nil),
            ("😀", 0..<1, nil), ("😀", 1..<2, nil), ("😀😀", 1..<3, nil),
            ("😀", 0..<2, "😀"), ("😀 **bold**", 1..<7, nil),
            ("e\u{301}x", 1..<2, "\u{301}"), ("éx", 0..<1, "é"),
        ] as [(String, Range<Int>, String?)])
    func selectionSpans(source: String, range: Range<Int>, expected: String?) throws {
        let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: range, in: AttributedMarkdownBuilder.build(source))
        if let expected {
            let bytes = try #require(span)
            #expect(sub(source, bytes).utf8.elementsEqual(expected.utf8))
        } else {
            #expect(span == nil)
        }
    }

    @Test(
        arguments: [
            ("one two three four five", 8, 8, 8, 8, false),
            ("héllo 👋 wörld", 9, 12, 12, 9, false),
            ("héllo 👋 wörld", 7, 7, 9, 6, false),
            ("héllo 👋 wörld", 6, 7, 7, 6, false),
            ("aaa &amp; " + (1...80).map { "w\($0)" }.joined(separator: " "), 40, nil, nil, 40, true),
            ("- alpha", 0, 2, nil, nil, false), ("- alpha", 2, 2, nil, nil, false),
            ("alpha\n\n---", nil, nil, nil, nil, false),
        ] as [(String, Int?, Int?, Int?, Int?, Bool)])
    func scrollAnchors(source: String, rendered: Int?, expectedByte: Int?, byte: Int?, expectedRendered: Int?, entity: Bool) throws {
        let doc = AttributedMarkdownBuilder.build(source)
        if rendered == nil {
            #expect(doc.runs.last?.sourceRange == nil)
            let end = doc.runs.reduce(0) { $0 + $1.text.utf16.count }
            #expect(SelectionSourceMapping.sourceOffset(forRenderedUTF16: end - 1, in: doc) == nil)
            return
        }
        let renderedOffset = try #require(rendered)
        let captured = try #require(SelectionSourceMapping.sourceOffset(forRenderedUTF16: renderedOffset, in: doc))
        if entity {
            #expect(captured > 10)
            #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: captured, in: doc) == expectedRendered)
        } else {
            #expect(captured == expectedByte)
            if let byte {
                #expect(SelectionSourceMapping.renderedUTF16Offset(forSourceOffset: byte, in: doc) == expectedRendered)
            }
        }
    }

    @Test("valid Unicode scalar selections map exactly and preserve bytes when annotated")
    func unicodeScalarSelectionsAndAnnotationInsertion() throws {
        let source = "😀 test"
        let document = AttributedMarkdownBuilder.build(source)
        let span = try #require(SelectionSourceMapping.sourceSpan(forSelectedUTF16: 0..<2, in: document))
        let output = try #require(
            PlanAnnotationWriter.insertingAnnotation(
                in: source, span: span, author: .user, payload: "keep emoji", id: "w8p2"
            ))
        #expect(output.source == "<mark>😀</mark><!-- AMX id=w8p2 by=user: keep emoji --> test")
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
}
