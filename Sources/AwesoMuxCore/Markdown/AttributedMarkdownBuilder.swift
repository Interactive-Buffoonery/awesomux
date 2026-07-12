// Sources/AwesoMuxCore/Markdown/AttributedMarkdownBuilder.swift
//
// Walks the swift-markdown AST into a flat [RenderedRun] sequence that preserves
// UTF-8 source ranges, enclosing-inline ranges, precise-mapping flags, and <mark> IDs.
//
// Design notes:
// - InlineHTML nodes (<mark>, </mark>, <!-- … -->) are consumed here; no run is emitted for them.
// - markID deferral: <mark> arms collection → runs are tracked → </mark> moves them to
//   pendingMarkRunIndices → <!-- USER COMMENT N: … --> stamps N onto those runs.
//   Two adjacent marks are handled correctly because pending is always cleared before the
//   next <mark> can open.
// - preciseMapping is computed as (text.utf8.count == sourceRange byte-length). Inline/fenced
//   code get the outer (backtick-inclusive) range so preciseMapping is always false for them.
//   Entity-bearing text (e.g. &amp; → &) is also imprecise by the same formula.

import Foundation
import Markdown

// MARK: - Builder entry point

public enum AttributedMarkdownBuilder {
    /// Parse `source` and return a `RenderedDocument` whose runs are 1:1 with the
    /// rendered text (no markup strings, no badge characters).
    public static func build(_ source: String) -> RenderedDocument {
        let frontMatter = MarkdownFrontMatter.parse(source)
        var ctx = Context(
            source: source,
            mapper: SourceOffsetMapper(source: source),
            frontMatterRange: frontMatter?.fullRange
        )
        let document = Document(parsing: source)
        var first = true
        if let frontMatter, !frontMatter.metadataText.isEmpty {
            ctx.emitFrontMatter(frontMatter.metadataText)
            first = false
        }
        for block in document.children {
            if ctx.blockIsFrontMatter(block) { continue }
            // An own-line annotation marker is an HTMLBlock. Consume it BEFORE
            // the separator logic — it emits no runs, and emitting its "\n\n"
            // would stack a blank gap between its neighbors.
            if let html = block as? HTMLBlock, ctx.consumeAnnotationBlock(html) { continue }
            if !first { ctx.emitSeparator() }
            first = false
            ctx.visitBlock(block)
        }
        return RenderedDocument(
            source: source,
            runs: ctx.runs,
            annotations: ctx.finalizedAnnotations(),
            taskProgress: TaskProgress(done: ctx.completedTaskCount, total: ctx.taskCount)
        )
    }
}

// MARK: - Inline style accumulator

private struct InlineStyle {
    var bold: Bool = false
    var italic: Bool = false
    var strike: Bool = false
    var link: String? = nil
}

// MARK: - Build context

private struct Context {
    let source: String
    let mapper: SourceOffsetMapper
    let frontMatterRange: Range<Int>?
    var runs: [RenderedRun] = []
    var annotations: [PlanAnnotation] = []
    var annotationIndexByID: [String: Int] = [:]
    // Thread notes buffer until build end: a note may precede its annotation
    // in the file, and orphans (no matching id) stay hidden (contract).
    var threadNotes: [(id: String, note: PlanAnnotation.Note)] = []
    var completedTaskCount = 0
    var taskCount = 0

    // Per-document table serial: incremented for each Table node so the
    // attributed-string builder can group every run of one table.
    var tableSerial: Int = 0

    // Mark tracking:
    // openMarkRunIndices: indices of runs emitted since the last <mark> open.
    // pendingMarkRunIndices: run indices waiting to be stamped by the comment marker
    //   (populated when </mark> closes the block; consumed when the comment arrives).
    var openMarkRunIndices: [Int] = []
    var pendingMarkRunIndices: [Int] = []
    var isMarkOpen: Bool = false

    // MARK: Byte-range helpers

    func byteRange(of node: any Markup) -> Range<Int>? {
        guard let r = node.range,
              let lo = mapper.utf8Offset(forLine: r.lowerBound.line, column: r.lowerBound.column),
              let hi = mapper.utf8Offset(forLine: r.upperBound.line, column: r.upperBound.column),
              lo <= hi else { return nil }
        return lo..<hi
    }

    // MARK: Leaf emission

    mutating func emitFrontMatter(_ text: String) {
        runs.append(RenderedRun(
            text: text,
            style: .frontMatter,
            sourceRange: nil,
            enclosingRange: nil,
            preciseMapping: false
        ))
    }

    mutating func emitSeparator() {
        pendingMarkRunIndices = []
        runs.append(RenderedRun(
            text: "\n\n",
            style: .blockSeparator,
            sourceRange: nil,
            enclosingRange: nil,
            preciseMapping: false
        ))
    }

    /// Emit a leaf run. `source` is the byte range of the node itself; `enclosing` is
    /// the range of the top-level inline ancestor (the direct child of the block).
    /// For inline/fenced code the caller passes the outer node range so preciseMapping
    /// is correctly computed as false.
    mutating func emitLeaf(
        text: String,
        style: RunStyle,
        inline: InlineStyle,
        source: Range<Int>?,
        enclosing: Range<Int>?
    ) {
        pendingMarkRunIndices = []
        let precise: Bool
        if let sr = source {
            precise = text.utf8.count == (sr.upperBound - sr.lowerBound)
        } else {
            precise = false
        }
        var run = RenderedRun(
            text: text,
            style: style,
            bold: inline.bold,
            italic: inline.italic,
            strikethrough: inline.strike,
            linkDestination: inline.link,
            sourceRange: source,
            enclosingRange: enclosing ?? source,
            preciseMapping: precise,
            markID: nil
        )
        // If we're inside an open <mark>, record this run's index for later stamping.
        if isMarkOpen {
            let idx = runs.count
            openMarkRunIndices.append(idx)
            run.markID = nil    // will be stamped when comment arrives
        }
        runs.append(run)
    }

    // MARK: InlineHTML handler

    mutating func handleInlineHTML(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        // Check the close tag first: `</mark>` also starts with `<` and would otherwise
        // need the negative-prefix guard the previous version relied on.
        if lower.hasPrefix("</mark>") {
            // Close </mark>: move collected indices to pending; disarm open collection.
            // Guard against a stray close with no matching open — it must not clobber a
            // legitimate pending set that is still waiting for its comment marker.
            guard isMarkOpen else { return }
            pendingMarkRunIndices = openMarkRunIndices
            openMarkRunIndices = []
            isMarkOpen = false
        } else if lower.hasPrefix("<mark>") || lower.hasPrefix("<mark ") {
            // Open <mark>: arm collection. Discard any unresolved pending from a prior
            // mark whose comment never arrived, so a later comment cannot retroactively
            // cross-wire onto those abandoned runs. Nested marks are unsupported: a new
            // open while one is already live re-arms and drops the outer runs collected
            // so far (documented limitation, not a silent correctness claim).
            isMarkOpen = true
            openMarkRunIndices = []
            pendingMarkRunIndices = []
        } else if let marker = PlanAnnotationMarker.parse(trimmed) {
            consumeMarker(marker, forcedAnchor: nil)
        } else if let (n, note) = Self.parseCommentMarker(trimmed) {
            // Legacy marker: surfaces as an annotation with the integer as a
            // string id. `by=user` is an assumption the legacy format cannot
            // record; it matches how those markers were created (contract).
            recordAnnotation(PlanAnnotation(
                id: String(n),
                author: .user,
                payload: note,
                anchor: pendingMarkRunIndices.isEmpty ? .document : .span,
                isLegacy: true
            ))
        }
    }

    // MARK: Annotation markers

    /// Consume a parsed AMX marker. `forcedAnchor` is set by the block-level
    /// path: an own-line marker is document-level regardless of a `<mark>`
    /// pairing left pending by an earlier block, and must not consume it.
    mutating func consumeMarker(_ marker: PlanAnnotationMarker, forcedAnchor: PlanAnnotation.Anchor?) {
        switch marker {
        case .annotation(let a):
            let anchor = forcedAnchor ?? (pendingMarkRunIndices.isEmpty ? .document : .span)
            // Span intents cannot target the whole document; demote rather
            // than guess a target (contract).
            let intent: PlanAnnotationIntent = anchor == .document && a.intent != .comment
                ? .comment
                : a.intent
            recordAnnotation(PlanAnnotation(
                id: a.id,
                author: a.author,
                intent: intent,
                status: a.status,
                payload: a.payload,
                anchor: anchor
            ))
        case .note(let n):
            threadNotes.append((n.annotationID, PlanAnnotation.Note(author: n.author, payload: n.payload)))
        }
    }

    /// First-writer-wins on a duplicate id so a re-used id cannot steal the
    /// first annotation's controls or highlights.
    mutating func recordAnnotation(_ annotation: PlanAnnotation) {
        guard annotationIndexByID[annotation.id] == nil else {
            pendingMarkRunIndices = []
            return
        }
        annotationIndexByID[annotation.id] = annotations.count
        annotations.append(annotation)
        if annotation.anchor == .span {
            for idx in pendingMarkRunIndices {
                runs[idx].markID = annotation.id
            }
            pendingMarkRunIndices = []
        }
    }

    /// Handle an own-line annotation HTMLBlock. Returns true when every
    /// non-empty line parsed as an AMX marker (all consumed); false leaves the
    /// block to the ordinary visitor so arbitrary HTML keeps its old behavior.
    mutating func consumeAnnotationBlock(_ html: HTMLBlock) -> Bool {
        let lines = html.rawHTML
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let markers = lines.compactMap { PlanAnnotationMarker.parse($0) }
        guard markers.count == lines.count else { return false }
        for marker in markers {
            consumeMarker(marker, forcedAnchor: .document)
        }
        return true
    }

    /// Attach buffered thread notes to their annotations, in file order.
    func finalizedAnnotations() -> [PlanAnnotation] {
        guard !threadNotes.isEmpty else { return annotations }
        var result = annotations
        for (id, note) in threadNotes {
            guard let index = annotationIndexByID[id] else { continue }
            result[index].notes.append(note)
        }
        return result
    }

    static func parseCommentMarker(_ s: String) -> (Int, String)? {
        guard s.hasPrefix("<!--"), s.hasSuffix("-->") else { return nil }
        let inner = s.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.uppercased().hasPrefix("USER COMMENT") else { return nil }
        let after = inner.dropFirst("USER COMMENT".count).trimmingCharacters(in: .whitespaces)
        guard let colon = after.firstIndex(of: ":"),
              let n = Int(after[after.startIndex..<colon].trimmingCharacters(in: .whitespaces)),
              n > 0   // IDs are positive; reject "0"/"-3" so markID/comments keys stay sane.
        else { return nil }
        // CommentMarkerWriter escapes pipes as `\|` so a marker inside a table row
        // can't split the row. Inside a table GFM strips the escape before this
        // parser sees it; outside a table the raw comment still carries it — undo
        // it here so the displayed note matches what the user typed.
        let note = after[after.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\|", with: "|")
        return (n, note)
    }

    // MARK: Block visitor

    func blockIsFrontMatter(_ node: any Markup) -> Bool {
        guard let frontMatterRange, let range = byteRange(of: node) else { return false }
        return frontMatterRange.lowerBound <= range.lowerBound
            && range.upperBound <= frontMatterRange.upperBound
    }

    mutating func visitBlock(_ node: any Markup) {
        switch node {
        case let h as Heading:
            for child in h.children {
                visitInline(child, style: InlineStyle(), heading: h.level, enclosing: byteRange(of: child))
            }

        case let p as Paragraph:
            for child in p.children {
                visitInline(child, style: InlineStyle(), heading: nil, enclosing: byteRange(of: child))
            }

        case let code as CodeBlock:
            // Trim trailing newline that swift-markdown appends to code strings.
            let rawCode = code.code
            let trimmed = rawCode.hasSuffix("\n") ? String(rawCode.dropLast()) : rawCode
            // Source range spans the entire fenced block (including fences) → preciseMapping = false.
            let sr = byteRange(of: code)
            emitLeaf(text: trimmed, style: .code, inline: InlineStyle(), source: sr, enclosing: sr)

        case let quote as BlockQuote:
            var first = true
            for child in quote.children {
                if !first { emitSeparator() }
                first = false
                visitBlock(child)
            }

        case let list as UnorderedList:
            // Separate items with a block separator, but NOT after the last item: the
            // build() loop already inserts a separator before the next top-level block,
            // and a list that ends the document should not leave an orphan trailing run.
            var firstItem = true
            for item in list.listItems {
                if !firstItem { emitSeparator() }
                firstItem = false
                let bullet: String
                switch item.checkbox {
                case .checked:
                    completedTaskCount += 1
                    taskCount += 1
                    bullet = "☑\u{00A0}"
                case .unchecked:
                    taskCount += 1
                    bullet = "☐\u{00A0}"
                case nil:
                    bullet = "•\u{00A0}"
                }
                runs.append(RenderedRun(
                    text: bullet,
                    style: .listBullet,
                    sourceRange: nil,
                    enclosingRange: nil,
                    preciseMapping: false
                ))
                var firstChild = true
                for child in item.children {
                    if !firstChild { emitSeparator() }
                    firstChild = false
                    visitBlock(child)
                }
            }

        case let list as OrderedList:
            var n = Int(list.startIndex)
            var firstItem = true
            for item in list.listItems {
                if !firstItem { emitSeparator() }
                firstItem = false
                let label = "\(n).\u{00A0}"
                runs.append(RenderedRun(
                    text: label,
                    style: .listNumber("\(n)."),
                    sourceRange: nil,
                    enclosingRange: nil,
                    preciseMapping: false
                ))
                var firstChild = true
                for child in item.children {
                    if !firstChild { emitSeparator() }
                    firstChild = false
                    visitBlock(child)
                }
                n += 1
            }

        case let table as Table:
            visitTable(table)

        case let html as HTMLBlock:
            // A document-level marker nested in a blockquote or list item
            // (the top-level case is consumed in build() before separators).
            // Non-annotation HTML blocks keep their old behavior: no runs.
            _ = consumeAnnotationBlock(html)

        default:
            for child in node.children { visitBlock(child) }
        }
    }

    // MARK: Table visitor

    /// Emit a GFM table as flat cell runs plus synthetic `\t` (between cells) and
    /// `\n` (end of row) separators. Cell content is emitted through `visitInline`
    /// so bold/links/inline-code inside cells work AND each cell's text carries its
    /// own `sourceRange` — keeping cells commentable via the PR2 selection flow.
    ///
    /// swift-markdown's typed accessors (`table.head`, `table.body`,
    /// `columnAlignments`) are internal to the Markdown module, so we traverse the
    /// public `children` instead: a Table's children are its Head then Body; a
    /// Head/Row's children are Cells; a Cell's children are inline nodes. Column
    /// alignment is likewise unreachable via the API, so it's parsed from the
    /// source delimiter row (`parseColumnAlignments`).
    mutating func visitTable(_ table: Table) {
        let serial = tableSerial
        tableSerial += 1

        let alignments = parseColumnAlignments(for: table)
        func alignment(forColumn column: Int) -> TableColumnAlignment {
            column < alignments.count ? alignments[column] : .left
        }

        var row = 0
        var firstRow = true

        // A Table's children are [Head, Body]; a Head is itself the header row.
        for section in table.children {
            if section is Table.Head {
                emitTableRow(section, table: serial, row: row, isHeader: true,
                             firstRow: &firstRow, alignment: alignment)
                row += 1
            } else if section is Table.Body {
                for bodyRow in section.children {
                    emitTableRow(bodyRow, table: serial, row: row, isHeader: false,
                                 firstRow: &firstRow, alignment: alignment)
                    row += 1
                }
            }
        }
    }

    /// Emit one table row (a Head or a Body Row). Cells are `\t`-separated within
    /// the row; the row is terminated by a `\n`. `firstRow` gates the leading
    /// separator so the first row isn't preceded by a stray newline.
    mutating func emitTableRow(
        _ rowNode: any Markup,
        table: Int,
        row: Int,
        isHeader: Bool,
        firstRow: inout Bool,
        alignment: (Int) -> TableColumnAlignment
    ) {
        if !firstRow {
            // Terminate the previous row's paragraph. Synthetic: no source range.
            runs.append(RenderedRun(
                text: "\n", style: .blockSeparator,
                sourceRange: nil, enclosingRange: nil, preciseMapping: false
            ))
        }
        firstRow = false

        var column = 0
        for cell in rowNode.children {
            if column > 0 {
                // Column break inside the row. Synthetic tab; the row's tab-stop
                // paragraph style turns it into the next column.
                runs.append(RenderedRun(
                    text: "\t", style: .blockSeparator,
                    sourceRange: nil, enclosingRange: nil, preciseMapping: false
                ))
            }
            let style: RunStyle = isHeader
                ? .tableHeader(table: table, row: row, column: column, alignment: alignment(column))
                : .tableCell(table: table, row: row, column: column, alignment: alignment(column))
            emitTableCell(cell, style: style)
            column += 1
        }
    }

    /// Emit a single cell's inline content via `visitInline`, then post-stamp the
    /// table style onto every run just emitted. Mirrors the mark-stamping trick
    /// (`handleInlineHTML`) of bookmarking `runs.count` and rewriting by index.
    /// An empty cell emits no content run; its column is still advanced by the
    /// surrounding tab/newline separators.
    mutating func emitTableCell(_ cell: any Markup, style: RunStyle) {
        let start = runs.count
        for child in cell.children {
            visitInline(child, style: InlineStyle(), heading: nil, enclosing: byteRange(of: child))
        }
        for idx in start..<runs.count {
            // A code run must render monospaced even after re-styling to a table cell.
            // `.code` lives in `style`, which we overwrite here for grid membership, so
            // carry the code-ness onto the orthogonal `monospaced` trait first.
            if case .code = runs[idx].style { runs[idx].monospaced = true }
            runs[idx].style = style
        }
    }

    /// Parse per-column alignment from the table's source delimiter row. The
    /// `columnAlignments` API is internal to swift-markdown, so we read the second
    /// line of the table's source range (the `| :- | -: |` separator) and classify
    /// each column by its leading/trailing colon. Returns `.left` for any column
    /// whose delimiter has no colon, and an empty array if the delimiter can't be
    /// located (callers default missing columns to `.left`).
    func parseColumnAlignments(for table: Table) -> [TableColumnAlignment] {
        guard let range = byteRange(of: table) else { return [] }
        let bytes = Array(source.utf8)
        guard range.upperBound <= bytes.count else { return [] }
        let tableText = String(decoding: bytes[range], as: UTF8.self)
        // Split on any newline CHARACTER, not the "\n" scalar: in Swift `\r\n` is a
        // single grapheme cluster, so `split(separator: "\n")` never matches in a
        // CRLF file and the whole table collapses to one "line" — every column
        // silently loses its alignment.
        let lines = tableText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // Line 0 is the header; line 1 is the delimiter row.
        guard lines.count >= 2 else { return [] }
        // A GFM delimiter cell contains only `-`, `:`, and spaces. Splitting the raw
        // line on `|` and keeping ONLY cells that match that shape drops any block
        // prefix (`> ` for a blockquoted table, list indentation) that would otherwise
        // become a phantom leading column and shift every real column's alignment.
        let delimiterCell = Set(":- \t")
        return lines[1]
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { cell in !cell.isEmpty && cell.allSatisfy { delimiterCell.contains($0) } && cell.contains("-") }
            .map { trimmed -> TableColumnAlignment in
                let leading = trimmed.hasPrefix(":")
                let trailing = trimmed.hasSuffix(":")
                switch (leading, trailing) {
                case (true, true): return .center
                case (false, true): return .right
                default: return .left
                }
            }
    }

    // MARK: Inline visitor

    mutating func visitInline(
        _ node: any Markup,
        style: InlineStyle,
        heading: Int?,
        enclosing: Range<Int>?
    ) {
        switch node {
        case let t as Text:
            let runStyle: RunStyle = heading.map { .heading(level: $0) } ?? .body
            emitLeaf(
                text: t.string,
                style: runStyle,
                inline: style,
                source: byteRange(of: t),
                enclosing: enclosing
            )

        case let c as InlineCode:
            // Use the outer node range (including backticks) so preciseMapping = false.
            let outerRange = byteRange(of: c)
            emitLeaf(
                text: c.code,
                style: .code,
                inline: style,
                source: outerRange,
                enclosing: enclosing ?? outerRange
            )

        case let s as Strong:
            var childStyle = style
            childStyle.bold = true
            for child in s.children {
                visitInline(child, style: childStyle, heading: heading, enclosing: enclosing)
            }

        case let e as Emphasis:
            var childStyle = style
            childStyle.italic = true
            for child in e.children {
                visitInline(child, style: childStyle, heading: heading, enclosing: enclosing)
            }

        case let s as Strikethrough:
            var childStyle = style
            childStyle.strike = true
            for child in s.children {
                visitInline(child, style: childStyle, heading: heading, enclosing: enclosing)
            }

        case let l as Link:
            var childStyle = style
            childStyle.link = l.destination
            for child in l.children {
                visitInline(child, style: childStyle, heading: heading, enclosing: enclosing)
            }

        case is SoftBreak:
            // Render as a space (soft line continuation).
            runs.append(RenderedRun(
                text: " ",
                style: .blockSeparator,
                sourceRange: nil,
                enclosingRange: nil,
                preciseMapping: false
            ))

        case is LineBreak:
            // Render as a hard newline.
            runs.append(RenderedRun(
                text: "\n",
                style: .blockSeparator,
                sourceRange: nil,
                enclosingRange: nil,
                preciseMapping: false
            ))

        case let html as InlineHTML:
            handleInlineHTML(html.rawHTML)

        case let image as Image:
            // Emit alt text as plain body run; no image loading.
            let alt = image.plainText
            if !alt.isEmpty {
                emitLeaf(text: alt, style: .body, inline: style, source: byteRange(of: image), enclosing: enclosing)
            }

        default:
            for child in node.children {
                visitInline(child, style: style, heading: heading, enclosing: enclosing)
            }
        }
    }
}
