import Testing
@testable import AwesoMuxCore

@Suite("AttributedMarkdownBuilder")
struct AttributedMarkdownBuilderTests {
    private func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: Array(s.utf8)[r], as: UTF8.self) }

    @Test(
        arguments: [
            ("a **b** c", "b", true, "b", "**b**"),
            ("see `foo` ok", "foo", false, "`foo`", nil),
            ("a &amp; b", "a & b", false, "a &amp; b", nil),
        ] as [(String, String, Bool, String, String?)])
    func preciseMappings(source: String, text: String, precise: Bool, slice: String, enclosing: String?) throws {
        let run = try #require(AttributedMarkdownBuilder.build(source).runs.first { $0.text == text })
        #expect(run.preciseMapping == precise)
        #expect(sub(source, try #require(run.sourceRange)) == slice)
        if let enclosing { #expect(sub(source, try #require(run.enclosingRange)) == enclosing) }
    }

    @Test(
        arguments: [
            ("<mark>a</mark> then <mark>b</mark><!-- USER COMMENT 1: note -->", ["b"], "note", ["a"]),
            ("<mark>a</mark><!-- USER COMMENT 1: first --> and <mark>b</mark><!-- USER COMMENT 1: second -->", ["a"], "first", ["b"]),
            ("<mark>a</mark></mark><!-- USER COMMENT 1: note -->", ["a"], "note", []),
            ("<mark>a</mark><!-- USER COMMENT 0: x -->", [], nil, ["a"]),
        ] as [(String, [String], String?, [String])])
    func malformedMarks(source: String, marked: [String], payload: String?, unmarked: [String]) {
        let doc = AttributedMarkdownBuilder.build(source)
        #expect(doc.runs.filter { $0.markID == "1" }.map(\.text) == marked)
        #expect(doc.annotation(id: "1")?.payload == payload)
        for text in unmarked { #expect(doc.runs.first { $0.text == text }?.markID == nil) }
        if payload == nil { #expect(doc.annotations.isEmpty) }
    }

    @Test(arguments: [
        ("> | L | R |\n> | :- | -: |\n> | a | b |", TableColumnAlignment.left),
        ("| A | B |\r\n| :-: | -: |\r\n| x | y |\r\n", .center),
        ("Intro 🎉🎉 with 日本語テスト before the table.\n\n| A | B |\n| :-: | -: |\n| x | y |\n", .center),
    ])
    func tableAlignments(source: String, firstColumn: TableColumnAlignment) {
        let doc = AttributedMarkdownBuilder.build(source)
        for (column, expected) in [firstColumn, .right].enumerated() {
            let alignment = doc.runs.lazy.compactMap { run -> TableColumnAlignment? in
                switch run.style {
                case let .tableHeader(_, _, c, a) where c == column: return a
                case let .tableCell(_, _, c, a) where c == column: return a
                default: return nil
                }
            }.first
            #expect(alignment == expected)
        }
    }

    @Test(arguments: [
        ("--- a comment", DiffLineKind.removed), ("---", .removed), ("+++i", .added),
        ("--- a/x", .meta), ("+++ b/x", .meta), ("@@", .hunk),
    ])
    func diffLineKinds(line: String, expected: DiffLineKind) {
        #expect(DiffLineKind(line: line[...]) == expected)
    }

    @Test("a pipe in a comment note cannot split a table row")
    func pipeInNoteInsideTableCell() throws {
        let src = "| A | B |\n| - | - |\n| xx | y |"
        let cell = try #require(AttributedMarkdownBuilder.build(src).runs.first { $0.text == "xx" })
        let span = try #require(cell.sourceRange)
        let (commented, id) = try #require(
            PlanAnnotationWriter.insertingAnnotation(
                in: src, span: span, author: .user, payload: "too wide | fix"
            ))
        let doc = AttributedMarkdownBuilder.build(commented)
        // The marker survives as one inline HTML comment (unescaped, the pipe splits
        // the row: phantom column, comment vanishes, trailing cell dropped)…
        #expect(doc.annotation(id: id)?.payload == "too wide | fix")
        #expect(try #require(doc.runs.first { $0.markID == id }).text == "xx")
        // …and the table keeps exactly its two columns.
        let cells = doc.runs.compactMap { run -> (text: String, col: Int)? in
            guard let position = run.style.tableCellPosition else { return nil }
            return (run.text, position.column)
        }
        #expect(cells.contains { $0.text == "y" && $0.col == 1 })
        #expect(cells.allSatisfy { $0.col <= 1 })
    }

    @Test("an indented diff fence falls back to the whole-fence range rather than guessing")
    func indentedDiffFenceKeepsBlockRange() throws {
        let src = "- item\n\n   ```diff\n   +a\n   +b\n   ```\n"
        let doc = AttributedMarkdownBuilder.build(src)
        let lines = doc.runs.filter { if case .diffLine = $0.style { return true } else { return false } }
        #expect(lines.count == 2)
        for line in lines {
            #expect(!line.preciseMapping)
            #expect(line.sourceRange == line.enclosingRange)
        }
    }
}
