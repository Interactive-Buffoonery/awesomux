// Tests/AwesoMuxCoreTests/Markdown/AttributedMarkdownBuilderTests.swift
import Testing
@testable import AwesoMuxCore

@Suite("AttributedMarkdownBuilder")
struct AttributedMarkdownBuilderTests {
    private func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: Array(s.utf8)[r], as: UTF8.self) }

    @Test("bold inner text is precise and maps to 'b'; its enclosingRange covers '**b**'")
    func boldEnclosing() throws {
        let src = "a **b** c"
        let doc = AttributedMarkdownBuilder.build(src)
        let b = try #require(doc.runs.first { $0.bold })
        let sr = try #require(b.sourceRange)
        let enc = try #require(b.enclosingRange)
        #expect(b.preciseMapping)
        #expect(sub(src, sr) == "b")
        #expect(sub(src, enc) == "**b**")   // snap target — wrapping THIS is markup-safe
    }

    @Test("inline code is whole-node-only: not precise, source range spans the backticks")
    func inlineCodeWholeNode() throws {
        let src = "see `foo` ok"
        let doc = AttributedMarkdownBuilder.build(src)
        let c = try #require(doc.runs.first { if case .code = $0.style { return true } else { return false } })
        let sr = try #require(c.sourceRange)
        #expect(c.preciseMapping == false)
        #expect(sub(src, sr) == "`foo`")
    }

    @Test("entity-bearing text is not precise")
    func entityNotPrecise() throws {
        let doc = AttributedMarkdownBuilder.build("a &amp; b")
        let r = try #require(doc.runs.first { $0.sourceRange != nil })
        #expect(r.preciseMapping == false)   // text "a & b" (5 utf8) != source "a &amp; b" (9)
    }

    // MARK: Malformed-input hardening (review convergence)

    @Test("a mark whose comment never arrives does not cross-wire onto the next mark")
    func unresolvedMarkDoesNotCrossWire() throws {
        // First <mark> closes but no comment follows before the second <mark> opens.
        // The first run's indices must be discarded, not stamped by comment 1.
        let src = "<mark>a</mark> then <mark>b</mark><!-- USER COMMENT 1: note -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let runB = try #require(doc.runs.first { $0.markID == "1" })
        #expect(runB.text == "b")
        // "a" must NOT have been stamped with markID 1.
        #expect(doc.runs.first { $0.text == "a" }?.markID == nil)
        #expect(doc.annotation(id: "1")?.payload == "note")
    }

    @Test("duplicate comment ID keeps the first note (first-writer-wins)")
    func duplicateCommentIDFirstWins() {
        let src = "<mark>a</mark><!-- USER COMMENT 1: first --> and <mark>b</mark><!-- USER COMMENT 1: second -->"
        let doc = AttributedMarkdownBuilder.build(src)
        #expect(doc.annotation(id: "1")?.payload == "first")   // second note must not clobber the first
    }

    @Test("a stray </mark> with no open mark does not corrupt a pending stamp")
    func strayCloseDoesNotClobberPending() throws {
        // After the valid mark closes (pending set), a rogue </mark> arrives before the
        // comment. The guard must ignore it so comment 1 still stamps run "a".
        let src = "<mark>a</mark></mark><!-- USER COMMENT 1: note -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let runA = try #require(doc.runs.first { $0.text == "a" })
        #expect(runA.markID == "1")
        #expect(doc.annotation(id: "1")?.payload == "note")
    }

    @Test("comment marker with a non-positive N is ignored")
    func nonPositiveCommentIDIgnored() {
        let doc = AttributedMarkdownBuilder.build("<mark>a</mark><!-- USER COMMENT 0: x -->")
        #expect(doc.annotations.isEmpty)
        #expect(doc.runs.first { $0.text == "a" }?.markID == nil)
    }

    @Test("front matter rendering preserves original source offsets for body runs")
    func yamlFrontMatterPreservesSourceOffsets() throws {
        let src = """
        ---
        name: x
        ---

        # Title
        """
        let doc = AttributedMarkdownBuilder.build(src)
        #expect(doc.source == src)
        let title = try #require(doc.runs.first { $0.text == "Title" })
        let sr = try #require(title.sourceRange)
        #expect(sub(src, sr) == "Title")
        #expect(sr.lowerBound == src.utf8.count - "Title".utf8.count)
    }

    @Test("a lone opening delimiter remains normal markdown")
    func loneOpeningDelimiterStaysMarkdown() {
        let doc = AttributedMarkdownBuilder.build("---\n# Title")
        #expect(!doc.runs.contains { $0.style == .frontMatter })
        #expect(doc.runs.contains { $0.style == .heading(level: 1) && $0.text == "Title" })
    }

    // MARK: Tables (INT-566)

    /// Extract `(row, column, text, sourceRange)` for every table-cell/header run.
    private func tableCells(_ doc: RenderedDocument) -> [(row: Int, col: Int, header: Bool, text: String, sr: Range<Int>?)] {
        doc.runs.compactMap { run in
            switch run.style {
            case let .tableHeader(_, row, col, _): return (row, col, true, run.text, run.sourceRange)
            case let .tableCell(_, row, col, _): return (row, col, false, run.text, run.sourceRange)
            default: return nil
            }
        }
    }

    @Test("inline code in a cell keeps monospaced even after table re-styling")
    func tableInlineCode() throws {
        // Regression: emitTableCell rewrites style to .tableCell, which would drop the
        // .code style; the monospaced trait must carry the code-ness instead.
        let src = "| Command | Meaning |\n| - | - |\n| `git status` | check |"
        let doc = AttributedMarkdownBuilder.build(src)
        let code = try #require(doc.runs.first { $0.text == "git status" })
        #expect(code.monospaced)
        #expect(code.style.tableCellPosition != nil)   // still a cell (commentable, gridded)
    }

    @Test("blockquoted table parses column alignment despite the > prefix")
    func tableBlockquoteAlignment() throws {
        // The delimiter row is `> | :- | -: |`; the `> ` prefix must not become a
        // phantom leading column that shifts every real column's alignment.
        let src = "> | L | R |\n> | :- | -: |\n> | a | b |"
        let doc = AttributedMarkdownBuilder.build(src)
        func alignment(ofColumn column: Int) -> TableColumnAlignment? {
            doc.runs.lazy.compactMap { run -> TableColumnAlignment? in
                switch run.style {
                case let .tableHeader(_, _, c, a) where c == column: return a
                case let .tableCell(_, _, c, a) where c == column: return a
                default: return nil
                }
            }.first
        }
        #expect(alignment(ofColumn: 0) == .left)
        #expect(alignment(ofColumn: 1) == .right)
    }

    @Test("a pipe in a comment note cannot split a table row")
    func pipeInNoteInsideTableCell() throws {
        let src = "| A | B |\n| - | - |\n| xx | y |"
        let cell = try #require(AttributedMarkdownBuilder.build(src).runs.first { $0.text == "xx" })
        let span = try #require(cell.sourceRange)
        let (commented, n) = CommentMarkerWriter.insertingComment(
            in: src, span: span, note: "too wide | fix"
        )
        let doc = AttributedMarkdownBuilder.build(commented)
        // The marker survives as one inline HTML comment (unescaped, the pipe splits
        // the row: phantom column, comment vanishes, trailing cell dropped)…
        #expect(doc.annotation(id: String(n))?.payload == "too wide | fix")
        #expect(try #require(doc.runs.first { $0.markID == String(n) }).text == "xx")
        // …and the table keeps exactly its two columns.
        let cells = tableCells(doc)
        #expect(cells.contains { $0.text == "y" && $0.col == 1 })
        #expect(cells.allSatisfy { $0.col <= 1 })
    }

    @Test("a pipe in a comment note round-trips outside tables")
    func pipeInNoteOutsideTable() throws {
        let (commented, n) = CommentMarkerWriter.insertingComment(
            in: "see this ok", span: 4..<8, note: "a | b"
        )
        let doc = AttributedMarkdownBuilder.build(commented)
        // Outside a table nothing strips the `\|` escape — the parser must.
        #expect(doc.annotation(id: String(n))?.payload == "a | b")
    }

    @Test("CRLF sources keep column alignments")
    func tableAlignmentCRLF() {
        // `\r\n` is a single Swift grapheme: splitting the delimiter row on the "\n"
        // scalar finds no lines at all and every column silently falls back to .left.
        let src = "| A | B |\r\n| :-: | -: |\r\n| x | y |\r\n"
        let doc = AttributedMarkdownBuilder.build(src)
        func alignment(ofColumn column: Int) -> TableColumnAlignment? {
            doc.runs.lazy.compactMap { run -> TableColumnAlignment? in
                switch run.style {
                case let .tableHeader(_, _, c, a) where c == column: return a
                case let .tableCell(_, _, c, a) where c == column: return a
                default: return nil
                }
            }.first
        }
        #expect(alignment(ofColumn: 0) == .center)
        #expect(alignment(ofColumn: 1) == .right)
    }

    @Test("empty cells emit no run but neighbours keep correct column indices")
    func tableEmptyCells() throws {
        let src = "| A | B | C |\n| - | - | - |\n| x |  | z |"
        let doc = AttributedMarkdownBuilder.build(src)
        let cells = tableCells(doc)
        // Body row: x at column 0, z at column 2 (the empty middle cell emits nothing
        // but does not shift z into column 1).
        let x = try #require(cells.first { $0.text == "x" })
        #expect(x.row == 1 && x.col == 0)
        let z = try #require(cells.first { $0.text == "z" })
        #expect(z.row == 1 && z.col == 2)
    }

    @Test("multi-byte prose before a table does not shift its delimiter-row slice")
    func tableAlignmentAfterMultiByteProse() {
        // The delimiter row is recovered by slicing a UTF-8 BYTE range out of the
        // source. Emoji and CJK ahead of the table push its byte offset far past
        // its character offset, so anything that conflates the two lands mid-table
        // and every column silently falls back to .left.
        let src = "Intro 🎉🎉 with 日本語テスト before the table.\n\n| A | B |\n| :-: | -: |\n| x | y |\n"
        let doc = AttributedMarkdownBuilder.build(src)
        func alignment(ofColumn column: Int) -> TableColumnAlignment? {
            doc.runs.lazy.compactMap { run -> TableColumnAlignment? in
                switch run.style {
                case let .tableHeader(_, _, c, a) where c == column: return a
                case let .tableCell(_, _, c, a) where c == column: return a
                default: return nil
                }
            }.first
        }
        #expect(alignment(ofColumn: 0) == .center)
        #expect(alignment(ofColumn: 1) == .right)
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

    @Test("past the line cap the rest of a diff fence is one code run")
    func diffFenceLineCapFallsBackToCode() {
        let cap = AttributedMarkdownBuilder.maximumDiffFenceLines
        let body = (0..<(cap + 5)).map { "+\($0)" }.joined(separator: "\n")
        let doc = AttributedMarkdownBuilder.build("```diff\n\(body)\n```\n")
        let diffLines = doc.runs.filter { if case .diffLine = $0.style { return true } else { return false } }
        #expect(diffLines.count == cap)
        let tail = doc.runs.filter { $0.style == .code }
        #expect(tail.count == 1)
        #expect(tail.first?.text == "+\(cap)\n+\(cap + 1)\n+\(cap + 2)\n+\(cap + 3)\n+\(cap + 4)")
        #expect(doc.runs.map(\.text).joined() == body)
    }

    @Test(
        "diff line classification",
        arguments: [
            ("+added", DiffLineKind.added),
            ("-removed", .removed),
            (" context", .context),
            ("@@ -1 +1 @@", .hunk),
            ("@@@ -1 +1 +1 @@@", .hunk),
            ("diff --git a/x b/x", .meta),
            ("index 1..2 100644", .meta),
            ("--- a/x", .meta),
            ("+++ b/x", .meta),
            ("+++ /dev/null", .meta),
            ("--- /dev/null", .meta),
            ("\\ No newline at end of file", .meta),
            ("Binary files a/x and b/x differ", .meta),
            ("new file mode 100644", .meta),
            ("rename from x", .meta),
            // A removed SQL comment and an added `++` line are content, not headers.
            ("--- a comment", .removed),
            ("--- ", .removed),
            ("+++i", .added),
            ("---", .removed),
            ("", .context),
        ] as [(String, DiffLineKind)]
    )
    func diffLineKinds(line: String, expected: DiffLineKind) {
        #expect(DiffLineKind(line: line[...]) == expected)
    }
}
