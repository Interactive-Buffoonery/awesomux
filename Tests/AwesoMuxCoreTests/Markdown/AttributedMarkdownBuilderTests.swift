// Tests/AwesoMuxCoreTests/Markdown/AttributedMarkdownBuilderTests.swift
import Testing
@testable import AwesoMuxCore

@Suite("AttributedMarkdownBuilder")
struct AttributedMarkdownBuilderTests {
    private func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: Array(s.utf8)[r], as: UTF8.self) }

    @Test("concatenated run text equals the rendered string (1:1, no badge chars)")
    func oneToOne() {
        let doc = AttributedMarkdownBuilder.build("x <mark>y</mark><!-- USER COMMENT 1: n --> z")
        let rendered = doc.runs.map(\.text).joined()
        #expect(!rendered.contains("<mark>") && !rendered.contains("</mark>") && !rendered.contains("USER COMMENT"))
        #expect(rendered.contains("y"))   // the marked text survives as ordinary text
    }

    @Test("plain run is precise and maps to its exact source")
    func plainPrecise() throws {
        let src = "hello world"
        let doc = AttributedMarkdownBuilder.build(src)
        let r = try #require(doc.runs.first { $0.sourceRange != nil })
        let sr = try #require(r.sourceRange)
        #expect(r.preciseMapping)
        #expect(sub(src, sr) == "hello world")
    }

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

    @Test("synthetic runs carry no source range")
    func synthetic() {
        let doc = AttributedMarkdownBuilder.build("- one\n- two")
        let bullets = doc.runs.filter { if case .listBullet = $0.style { return true } else { return false } }
        #expect(!bullets.isEmpty && bullets.allSatisfy { $0.sourceRange == nil })
    }

    @Test("GFM task lists render checkbox glyphs and count completion")
    func taskListCheckboxesAndProgress() {
        let doc = AttributedMarkdownBuilder.build("- [ ] not started\n- [x] finished\n- [X] also finished\n- plain")
        let bullets = doc.runs.filter { if case .listBullet = $0.style { return true } else { return false } }

        #expect(bullets.map(\.text) == ["☐\u{00A0}", "☑\u{00A0}", "☑\u{00A0}", "•\u{00A0}"])
        #expect(doc.taskProgress == TaskProgress(done: 2, total: 3))
        #expect(bullets.allSatisfy { $0.sourceRange == nil && !$0.preciseMapping })
    }

    @Test("nested task lists contribute to document progress")
    func nestedTaskListProgress() {
        let doc = AttributedMarkdownBuilder.build("- [ ] parent\n  - [x] child\n  - plain\n- [ ] sibling")

        #expect(doc.taskProgress == TaskProgress(done: 1, total: 3))
        #expect(doc.runs.filter { $0.text == "☐\u{00A0}" }.count == 2)
        #expect(doc.runs.filter { $0.text == "☑\u{00A0}" }.count == 1)
    }

    @Test("plain bullet lists have no task progress")
    func plainBulletListHasNoTaskProgress() {
        let doc = AttributedMarkdownBuilder.build("- one\n- two")

        #expect(doc.taskProgress == TaskProgress(done: 0, total: 0))
        #expect(doc.runs.filter { if case .listBullet = $0.style { return true } else { return false } }
            .allSatisfy { $0.text == "•\u{00A0}" })
    }

    @Test("<mark> wraps the enclosed run with a markID and fills comments")
    func markWrapping() throws {
        let src = "see <mark>this</mark><!-- USER COMMENT 1: fix it --> ok"
        let doc = AttributedMarkdownBuilder.build(src)
        let m = try #require(doc.runs.first { $0.markID == "1" })
        #expect(m.text == "this")
        #expect(doc.annotation(id: "1")?.payload == "fix it")
    }

    @Test("two adjacent marks assign distinct markIDs without cross-wiring")
    func adjacentTwoMarks() throws {
        let src = "<mark>a</mark><!-- USER COMMENT 1: x --> and <mark>b</mark><!-- USER COMMENT 2: y -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let runA = try #require(doc.runs.first { $0.markID == "1" })
        let runB = try #require(doc.runs.first { $0.markID == "2" })
        #expect(runA.text == "a")
        #expect(runB.text == "b")
        #expect(doc.annotations.map(\.id) == ["1", "2"] && doc.annotation(id: "1")?.payload == "x" && doc.annotation(id: "2")?.payload == "y")
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

    @Test("empty input yields an empty document")
    func emptyInput() {
        let doc = AttributedMarkdownBuilder.build("")
        #expect(doc.runs.isEmpty)
        #expect(doc.annotations.isEmpty)
    }

    @Test("YAML front matter renders as metadata, not primary heading content")
    func yamlFrontMatterIsMetadata() throws {
        let src = """
        ---
        name: awesomux-awesomeness
        description: Publish or update plans and references
        ---

        # awesomux-awesomeness publishing

        Body text.
        """
        let doc = AttributedMarkdownBuilder.build(src)
        let metadata = try #require(doc.runs.first)
        #expect(metadata.style == .frontMatter)
        #expect(metadata.text.contains("name: awesomux-awesomeness"))
        #expect(metadata.text.contains("description: Publish or update plans and references"))
        #expect(metadata.sourceRange == nil)

        let rendered = doc.runs.map(\.text).joined()
        #expect(rendered.contains("#") == false)
        #expect(doc.runs.contains { $0.style == .heading(level: 2) && $0.text.contains("name:") } == false)
        let title = try #require(doc.runs.first { $0.style == .heading(level: 1) })
        #expect(title.text == "awesomux-awesomeness publishing")
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

    @Test("front matter with BOM still skips metadata in rendered body")
    func yamlFrontMatterWithBOM() throws {
        let src = "\u{FEFF}---\nname: x\n---\n# Title"
        let doc = AttributedMarkdownBuilder.build(src)

        let metadata = try #require(doc.runs.first { $0.style == .frontMatter })
        #expect(metadata.text == "name: x")
        #expect(!doc.runs.contains { $0.text.contains("\u{FEFF}") })
        let title = try #require(doc.runs.first { $0.style == .heading(level: 1) })
        #expect(title.text == "Title")
    }

    @Test("front matter with dot closing delimiter skips metadata")
    func yamlFrontMatterWithDotClosingDelimiter() throws {
        let src = """
        ---
        name: x
        ...
        # Title
        """
        let doc = AttributedMarkdownBuilder.build(src)

        let metadata = try #require(doc.runs.first { $0.style == .frontMatter })
        #expect(metadata.text == "name: x")
        let title = try #require(doc.runs.first { $0.style == .heading(level: 1) })
        #expect(title.text == "Title")
    }

    @Test("a lone opening delimiter remains normal markdown")
    func loneOpeningDelimiterStaysMarkdown() {
        let doc = AttributedMarkdownBuilder.build("---\n# Title")
        #expect(!doc.runs.contains { $0.style == .frontMatter })
        #expect(doc.runs.contains { $0.style == .heading(level: 1) && $0.text == "Title" })
    }

    @Test("a list followed by a paragraph does not emit a quadruple newline run")
    func listFollowedByParagraphNoDoubleSeparator() {
        let doc = AttributedMarkdownBuilder.build("- one\n- two\n\nafter")
        // No single run should be a doubled-up separator (\n\n\n\n); the builder emits
        // exactly one block separator between the list and the paragraph.
        #expect(!doc.runs.contains { $0.text == "\n\n\n\n" })
        // The rendered text must not contain three or more consecutive newlines.
        let rendered = doc.runs.map(\.text).joined()
        #expect(!rendered.contains("\n\n\n"))
    }

    @Test("a document ending in a list has no orphan trailing separator")
    func listAtEndNoTrailingSeparator() {
        let doc = AttributedMarkdownBuilder.build("- one\n- two")
        let rendered = doc.runs.map(\.text).joined()
        #expect(!rendered.hasSuffix("\n\n"))
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

    @Test("table AST → header/cell runs with non-nil source ranges (acceptance)")
    func tableAST() throws {
        let src = "| A | B |\n| - | - |\n| x | y |"
        let doc = AttributedMarkdownBuilder.build(src)
        let cells = tableCells(doc)

        let a = try #require(cells.first { $0.text == "A" })
        #expect(a.header && a.row == 0 && a.col == 0)
        let b = try #require(cells.first { $0.text == "B" })
        #expect(b.header && b.row == 0 && b.col == 1)
        let x = try #require(cells.first { $0.text == "x" })
        #expect(!x.header && x.row == 1 && x.col == 0)
        let y = try #require(cells.first { $0.text == "y" })
        #expect(!y.header && y.row == 1 && y.col == 1)

        // Every cell carries a real source range that decodes to its text.
        for cell in cells {
            let sr = try #require(cell.sr)
            #expect(sub(src, sr) == cell.text)
        }
    }

    @Test("column alignment is parsed from the delimiter row")
    func tableAlignment() throws {
        let src = "| L | R | C |\n| :- | -: | :-: |\n| a | b | c |"
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
        #expect(alignment(ofColumn: 2) == .center)
    }

    @Test("table run text is 1:1 — no pipes or delimiter dashes leak in")
    func tableOneToOne() {
        let src = "| A | B |\n| - | - |\n| x | y |"
        let doc = AttributedMarkdownBuilder.build(src)
        let rendered = doc.runs.map(\.text).joined()
        #expect(!rendered.contains("|"))
        #expect(!rendered.contains("---") && !rendered.contains(":-"))
        #expect(rendered.contains("A") && rendered.contains("x") && rendered.contains("y"))
    }

    @Test("inline markup inside a cell stays styled and commentable")
    func tableInlineCell() throws {
        let src = "| **b** | y |\n| - | - |\n| p | q |"
        let doc = AttributedMarkdownBuilder.build(src)
        let boldB = try #require(doc.runs.first { $0.bold && $0.text == "b" })
        // It's a header cell with a real source range and an enclosing range over **b**.
        guard case .tableHeader = boldB.style else { Issue.record("expected tableHeader style"); return }
        let sr = try #require(boldB.sourceRange)
        let enc = try #require(boldB.enclosingRange)
        #expect(sub(src, sr) == "b")
        #expect(sub(src, enc) == "**b**")
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
}
