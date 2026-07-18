import AppKit
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

// MARK: - Headless harness

/// TextKit 2 text view inside a scroll view, configured like `makeNSView` after
/// INT-687: infinite container in both axes, no self-sizing. Headless TextKit 2
/// needs explicit geometry (INT-567); `updateDocumentGeometry()` pins the wrap
/// width via tailIndent and sizes the frame from layout usage. NOTE: the harness
/// does NOT register the clip-view frame observer — tests that exercise the
/// notification path register it themselves.
@MainActor
private func makeWideTableHarness(
    source: String, paneWidth: CGFloat = 300
) -> (
    scrollView: NSScrollView,
    textView: NSTextView,
    coordinator: MarkdownTextViewCoordinator,
    attr: NSMutableAttributedString
) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 400))
    // Deterministic wrap basis: the machine-dependent default (legacy when a
    // mouse is attached) reserves scroller width and would shift expectations.
    scrollView.scrollerStyle = .overlay
    let textView = NSTextView(usingTextLayoutManager: true)
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    textView.isEditable = false
    textView.textContainerInset = NSSize(width: 20, height: 20)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    scrollView.documentView = textView

    let doc = AttributedMarkdownBuilder.build(source)
    let attr = NSMutableAttributedString(
        attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc)
    )
    textView.textStorage?.setAttributedString(attr)

    let coordinator = MarkdownTextViewCoordinator(selectedSourceSpan: .constant(nil))
    coordinator.textView = textView
    coordinator.lastDoc = doc
    coordinator.currentAttr = attr
    coordinator.noteStorageReplaced()
    return (scrollView, textView, coordinator, attr)
}

private let wideTableSource = """
    | Column Alpha | Column Bravo | Column Charlie |
    | - | - | - |
    | aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | cccccccccccccccccccccccccccccc |
    """

// MARK: - Wide-table overflow (INT-687)

@Suite("Wide-table overflow (INT-687)")
@MainActor
struct WideTableOverflowTests {

    /// The control experiment for the whole INT-687 layout model: with an
    /// infinite container, a positive tailIndent must still hard-wrap prose at
    /// the pane width while an untouched table row runs past the pane edge in
    /// a single segment.
    @Test("prose wraps at the pane width while a wide table overflows it")
    func proseWrapsWideTableOverflows() throws {
        let prose = (1...80).map { "word\($0)" }.joined(separator: " ")
        let (_, textView, _, attr) = makeWideTableHarness(
            source: prose + "\n\n" + wideTableSource
        )

        let ns = attr.string as NSString
        let proseRange = ns.range(of: prose)
        #expect(proseRange.location != NSNotFound)
        let proseCell = try #require(
            CommentBadgeOverlay.cellRectInTextView(range: proseRange, in: textView)
        )
        #expect(proseCell.segments > 1, "prose must wrap into multiple line segments")
        #expect(
            proseCell.rect.maxX <= 300,
            "wrapped prose must stay within the pane (maxX \(proseCell.rect.maxX))"
        )

        let lastCellRange = ns.range(of: "cccccccccccccccccccccccccccccc")
        #expect(lastCellRange.location != NSNotFound)
        let tableCell = try #require(
            CommentBadgeOverlay.cellRectInTextView(range: lastCellRange, in: textView)
        )
        #expect(tableCell.segments == 1, "a wide table cell must not wrap")
        #expect(
            tableCell.rect.maxX > 300,
            "the wide table must extend past the pane edge (maxX \(tableCell.rect.maxX))"
        )

        #expect(
            textView.frame.width > 300,
            "the document must widen to the table so the horizontal scroller engages"
        )
    }

    @Test("a document without wide content keeps the pane width")
    func narrowDocumentKeepsPaneWidth() {
        let (_, textView, _, _) = makeWideTableHarness(
            source: "Just a short paragraph.\n\n- and\n- a list"
        )
        #expect(textView.frame.width == 300)
    }

    @Test("replacing a wide document with an empty one shrinks the frame back")
    func emptyReplacementShrinksFrame() {
        let (_, textView, coordinator, _) = makeWideTableHarness(source: wideTableSource)
        #expect(textView.frame.width > 300, "premise: the wide table widened the document")

        textView.textStorage?.setAttributedString(NSAttributedString())
        coordinator.currentAttr = NSMutableAttributedString()
        coordinator.noteStorageReplaced()

        #expect(textView.frame.width == 300)
    }

    @Test("source-anchor restore preserves the horizontal scroll position")
    func anchorRestorePreservesHorizontalScroll() {
        let prose = "Intro paragraph before the table."
        let (scrollView, textView, coordinator, _) = makeWideTableHarness(
            source: prose + "\n\n" + wideTableSource
        )
        #expect(textView.frame.width > 300, "premise: horizontal range exists")

        textView.scroll(NSPoint(x: 120, y: 0))
        #expect(scrollView.contentView.bounds.origin.x == 120)

        coordinator.scrollToSourceOffset(prose.utf8.count / 2)

        #expect(
            scrollView.contentView.bounds.origin.x == 120,
            "a vertical anchor restore must not snap the user back to column one"
        )
    }

    @Test("storage paragraphs carry tailIndent on prose/code, none on table rows")
    func storageTailIndentAssertions() throws {
        let prose = "A body paragraph that is fine."
        let source = prose + "\n\n```\ncode line\n```\n\n" + wideTableSource
        let (_, textView, _, _) = makeWideTableHarness(source: source)
        let storage = try #require(textView.textStorage)
        let ns = storage.string as NSString
        let expectedWidth: CGFloat = 300 - 2 * 20

        func style(at text: String) throws -> NSParagraphStyle {
            let range = ns.range(of: text)
            #expect(range.location != NSNotFound, "fixture must contain \(text)")
            return try #require(
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )
        }

        #expect(try style(at: "fine.").tailIndent == expectedWidth)
        #expect(try style(at: "code line").tailIndent == expectedWidth)

        let tableStyle = try style(at: "Column Bravo")
        #expect(tableStyle.tailIndent == 0, "table rows keep their natural width")
        #expect(!tableStyle.tabStops.isEmpty, "table tab stops must survive the wrap pass")
    }

    @Test("a pane resize re-wraps prose to the new width")
    func paneResizeRewrapsProse() throws {
        let prose = "A body paragraph that is fine."
        let (scrollView, textView, coordinator, _) = makeWideTableHarness(source: prose)

        scrollView.setFrameSize(NSSize(width: 500, height: 400))
        coordinator.updateDocumentGeometry()

        let storage = try #require(textView.textStorage)
        let style = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(style.tailIndent == CGFloat(500 - 2 * 20))
        #expect(textView.frame.width == 500)
    }

    @Test("a clip-view frame notification drives the coalesced geometry pass")
    func notificationDrivenResize() throws {
        let prose = "A body paragraph that is fine."
        let (scrollView, textView, coordinator, _) = makeWideTableHarness(source: prose)

        // Mirror makeNSView's observer wiring — the production resize pipeline.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(MarkdownTextViewCoordinator.clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        defer { NotificationCenter.default.removeObserver(coordinator) }

        scrollView.setFrameSize(NSSize(width: 500, height: 400))
        // The observer coalesces through one runloop hop; spin the runloop
        // until the pass lands (bounded, so a regression fails fast). The
        // frame is no witness — NSClipView stretches a narrower documentView
        // to the clip on its own — so watch the wrap width itself.
        let storage = try #require(textView.textStorage)
        func tailIndent() -> CGFloat? {
            (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.tailIndent
        }
        let deadline = Date().addingTimeInterval(2)
        while tailIndent() != 460, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        #expect(tailIndent() == CGFloat(460))
        #expect(textView.frame.width == 500)
    }

    @Test("a sliver pane clamps the wrap width instead of unwrapping prose")
    func sliverPaneClampsWrapWidth() throws {
        let (_, textView, _, _) = makeWideTableHarness(
            source: "words words words", paneWidth: 30
        )
        let storage = try #require(textView.textStorage)
        let style = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        // 30 − 40 is negative; a non-positive tailIndent would mean "from the
        // trailing margin" — the infinite container edge, i.e. no wrap at all.
        #expect(style.tailIndent == 80)
    }
}

// MARK: - AXTable grids (INT-687)

@Suite("AXTable grid coalescing (INT-687)")
@MainActor
struct TableAXGridTests {
    private typealias Info = CommentBadgeOverlay.TableCellInfo

    private func grid(
        table: Int = 0, row: Int, column: Int, isHeader: Bool = false
    ) -> TableCellGrid {
        TableCellGrid(table: table, row: row, column: column, isHeader: isHeader)
    }

    @Test("multi-run cells coalesce; empty and ragged cells stay rectangular holes")
    func coalescingAndRectangularization() throws {
        let infos = [
            Info(
                grid: grid(row: 0, column: 0, isHeader: true),
                rect: NSRect(x: 0, y: 0, width: 40, height: 16), text: "Name"),
            Info(
                grid: grid(row: 0, column: 1, isHeader: true),
                rect: NSRect(x: 50, y: 0, width: 40, height: 16), text: "Status"),
            // (1,0) split across two runs ("**Ro**cket") — must coalesce.
            Info(
                grid: grid(row: 1, column: 0),
                rect: NSRect(x: 0, y: 20, width: 20, height: 16), text: "Ro"),
            Info(
                grid: grid(row: 1, column: 0),
                rect: NSRect(x: 20, y: 20, width: 20, height: 16), text: "cket"),
            // (1,1) omitted — ragged row.
            Info(
                grid: grid(row: 2, column: 0),
                rect: NSRect(x: 0, y: 40, width: 30, height: 16), text: "Dog"),
            Info(
                grid: grid(row: 2, column: 1),
                rect: NSRect(x: 50, y: 40, width: 30, height: 16), text: "Good"),
        ]

        let grids = CommentBadgeOverlay.tableAXGrids(from: infos)
        #expect(grids.count == 1)
        let table = try #require(grids.first)
        #expect(table.rowCount == 3)
        #expect(table.columnCount == 2)

        let merged = try #require(table.cells[1][0])
        #expect(merged.text == "Rocket")
        #expect(merged.rect == NSRect(x: 0, y: 20, width: 40, height: 16))

        #expect(table.cells[1][1] == nil, "the ragged cell must stay a hole, not shift")
    }

    @Test("placeholder frames come from row/column extents; nothing invents geometry")
    func placeholderFrames() throws {
        let infos = [
            Info(
                grid: grid(row: 0, column: 0),
                rect: NSRect(x: 0, y: 0, width: 40, height: 16), text: "a"),
            Info(
                grid: grid(row: 0, column: 1),
                rect: NSRect(x: 50, y: 0, width: 40, height: 16), text: "b"),
            Info(
                grid: grid(row: 1, column: 0),
                rect: NSRect(x: 0, y: 20, width: 40, height: 16), text: "c"),
            // (1,1) missing → placeholder = column 1's X-extent × row 1's Y-extent.
        ]
        let grids = CommentBadgeOverlay.tableAXGrids(from: infos)
        let frames = CommentBadgeOverlay.tableAXFrames(for: grids)

        let placeholder = try #require(
            frames[.cell(table: 0, row: 1, column: 1)]
        )
        #expect(placeholder == NSRect(x: 50, y: 20, width: 40, height: 16))

        let tableFrame = try #require(frames[.table(0)])
        #expect(tableFrame == NSRect(x: 0, y: 0, width: 90, height: 36))
    }

    @Test("an all-empty interior row still gets an interpolated frame band")
    func allEmptyRowInterpolatedFrames() throws {
        // Row 1 is entirely unpopulated (a GFM `|  |  |` row emits no runs).
        let infos = [
            Info(
                grid: grid(row: 0, column: 0),
                rect: NSRect(x: 0, y: 0, width: 40, height: 16), text: "a"),
            Info(
                grid: grid(row: 0, column: 1),
                rect: NSRect(x: 50, y: 0, width: 40, height: 16), text: "b"),
            Info(
                grid: grid(row: 2, column: 0),
                rect: NSRect(x: 0, y: 40, width: 40, height: 16), text: "c"),
            Info(
                grid: grid(row: 2, column: 1),
                rect: NSRect(x: 50, y: 40, width: 40, height: 16), text: "d"),
        ]
        let grids = CommentBadgeOverlay.tableAXGrids(from: infos)
        let table = try #require(grids.first)
        #expect(table.rowCount == 3)
        let frames = CommentBadgeOverlay.tableAXFrames(for: grids)

        // The empty row's band spans the gap between its populated neighbors,
        // full table width — never a .zero frame at the screen origin.
        let rowFrame = try #require(frames[.row(table: 0, row: 1)])
        #expect(rowFrame == NSRect(x: 0, y: 16, width: 90, height: 24))
        let cellFrame = try #require(frames[.cell(table: 0, row: 1, column: 1)])
        #expect(cellFrame == NSRect(x: 50, y: 16, width: 40, height: 24))
    }

    @Test("tables past the cell cap expose no AXTable")
    func cellCapDropsHugeTables() {
        // One cell claiming huge grid indices would demand a dense
        // rows×columns allocation; the cap drops the table instead.
        let infos = [
            Info(
                grid: grid(row: 99_999, column: 99),
                rect: NSRect(x: 0, y: 0, width: 10, height: 10), text: "x")
        ]
        #expect(CommentBadgeOverlay.tableAXGrids(from: infos).isEmpty)
    }
}

// MARK: - AXTable element tree (INT-687)

@Suite("AXTable element tree (INT-687)")
@MainActor
struct TableAXElementTreeTests {

    /// End-to-end headless: markdown → attributed string → TextKit 2 layout →
    /// overlay grid pass → cached AXTable tree.
    @Test("a rendered table exposes rows, columns, counts, ranges, and header labels")
    func elementTreeStructure() throws {
        let source = "| Name | Status |\n| - | - |\n| Rocket | Good |\n| Bella | Fine |"
        let (_, textView, _, attr) = makeWideTableHarness(source: source)

        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.updateBadges(attr: attr, textView: textView)

        let tables = overlay.tableAccessibilityElements
        #expect(tables.count == 1)
        let table = try #require(tables.first)
        #expect(table.accessibilityRole() == .table)
        #expect(table.accessibilityRowCount() == 3)
        #expect(table.accessibilityColumnCount() == 2)

        let rows = try #require(table.accessibilityRows() as? [NSAccessibilityElement])
        #expect(rows.count == 3)
        #expect(rows[1].accessibilityRole() == .row)
        #expect(rows[1].accessibilityIndex() == 1)

        let columns = try #require(table.accessibilityColumns() as? [NSAccessibilityElement])
        #expect(columns.count == 2)
        #expect(columns[0].accessibilityRole() == .column)

        let bodyCells = try #require(rows[1].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(bodyCells.count == 2)
        #expect(bodyCells[0].accessibilityRole() == .cell)
        #expect(bodyCells[0].accessibilityRowIndexRange() == NSRange(location: 1, length: 1))
        #expect(bodyCells[0].accessibilityColumnIndexRange() == NSRange(location: 0, length: 1))
        #expect(bodyCells[0].accessibilityLabel() == "Name: Rocket")

        let headerCells = try #require(rows[0].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(headerCells[0].accessibilityLabel() == "Name, column header")

        let headerElements = try #require(
            table.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement]
        )
        #expect(headerElements.count == 2)
    }

    @Test("every grid position resolves a frame through the production path")
    func productionAllEmptyRowFramesResolve() throws {
        // The middle row is entirely empty — the strongest hole case real
        // markdown can produce. Whatever row numbering the parser assigns,
        // the invariant is: every (row, column) the AXTable exposes has a
        // non-zero-origin-safe frame (no VoiceOver stops at the screen corner).
        let source = "| A | B |\n| - | - |\n| x | y |\n|  |  |\n| z | w |"
        let (_, textView, _, attr) = makeWideTableHarness(source: source)

        var infos: [CommentBadgeOverlay.TableCellInfo] = []
        let full = attr.string as NSString
        attr.enumerateAttribute(
            .tableCellGrid, in: NSRange(location: 0, length: attr.length), options: []
        ) { value, range, _ in
            guard let grid = value as? TableCellGrid, range.length > 0,
                let cell = CommentBadgeOverlay.cellRectInTextView(range: range, in: textView)
            else { return }
            infos.append(
                CommentBadgeOverlay.TableCellInfo(
                    grid: grid, rect: cell.rect, text: full.substring(with: range)))
        }

        let grids = CommentBadgeOverlay.tableAXGrids(from: infos)
        #expect(!grids.isEmpty)
        let frames = CommentBadgeOverlay.tableAXFrames(for: grids)
        for grid in grids {
            for r in 0..<grid.rowCount {
                for c in 0..<grid.columnCount {
                    #expect(
                        frames[.cell(table: grid.table, row: r, column: c)] != nil,
                        "cell (\(r),\(c)) must have a frame"
                    )
                }
            }
        }
    }

    @Test("mixed documents build one tree per table")
    func mixedDocumentMultipleTables() throws {
        let source = """
            Intro prose paragraph.

            | A | B |
            | - | - |
            | **bo**ld | 2 |

            Middle prose.

            | X |
            | - |
            | 9 |
            """
        let (_, textView, _, attr) = makeWideTableHarness(source: source)
        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.updateBadges(attr: attr, textView: textView)

        let tables = overlay.tableAccessibilityElements
        #expect(tables.count == 2)
        #expect(tables[0].accessibilityRowCount() == 2)
        #expect(tables[0].accessibilityColumnCount() == 2)
        #expect(tables[1].accessibilityRowCount() == 2)
        #expect(tables[1].accessibilityColumnCount() == 1)

        // The inline-styled cell must surface as ONE coalesced cell, not two.
        let rows = try #require(tables[0].accessibilityRows() as? [NSAccessibilityElement])
        let cells = try #require(rows[1].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(cells.count == 2)
        #expect(cells[0].accessibilityLabel() == "A: bold")
    }
}
