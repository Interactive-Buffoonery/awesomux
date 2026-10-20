import AppKit
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

// MARK: - Headless harness

@MainActor
private final class FixedStyleScrollView: NSScrollView {
    var requestedStyle: NSScroller.Style = .overlay

    // AppKit reconciles scroller styles with system preferences during layout.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = requestedStyle }
    }
}

/// TextKit 2 text view inside a scroll view, configured like `makeNSView` after
/// INT-687: infinite container in both axes, no self-sizing. Headless TextKit 2
/// needs explicit geometry (INT-567); `updateDocumentGeometry()` pins the wrap
/// width via tailIndent and sizes the frame from layout usage. NOTE: the harness
/// does NOT register the clip-view frame observer — tests that exercise the
/// notification path register it themselves.
@MainActor
private func makeWideTableHarness(
    source: String, paneWidth: CGFloat = 300, scrollerStyle: NSScroller.Style = .overlay
) -> (
    scrollView: NSScrollView,
    textView: NSTextView,
    coordinator: MarkdownTextViewCoordinator,
    attr: NSMutableAttributedString
) {
    let scrollView = FixedStyleScrollView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 400))
    scrollView.requestedStyle = scrollerStyle
    // Deterministic wrap basis: the machine-dependent default (legacy when a
    // mouse is attached) reserves scroller width and would shift expectations.
    scrollView.scrollerStyle = scrollerStyle
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

@MainActor
private func attributedMarkdown(_ source: String) -> NSMutableAttributedString {
    NSMutableAttributedString(
        attributedString: MarkdownAttributedStringBuilder.attributedString(
            for: AttributedMarkdownBuilder.build(source)
        )
    )
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

    @Test("a clip-view notification rewraps visible prose", arguments: [NSScroller.Style.overlay, .legacy])
    func resizeNotificationRewrapsProse(scrollerStyle: NSScroller.Style) async throws {
        let prose = (1...80).map { "word\($0)" }.joined(separator: " ")
        let (scroll, text, coordinator, attr) = makeWideTableHarness(source: prose, scrollerStyle: scrollerStyle)
        let range = (attr.string as NSString).range(of: prose)
        let before = try #require(CommentBadgeOverlay.cellRectInTextView(range: range, in: text))
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(MarkdownTextViewCoordinator.clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)
        defer { NotificationCenter.default.removeObserver(coordinator) }
        scroll.setFrameSize(NSSize(width: 500, height: 400))
        // Geometry is queued on the common run loop; enqueue behind that pass.
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        let after = try #require(CommentBadgeOverlay.cellRectInTextView(range: range, in: text))
        #expect(after.segments > 1)
        #expect(after.segments < before.segments)
        #expect(after.rect.maxX <= scroll.contentSize.width)
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

// MARK: - AXTable lazy materialization

/// Accessibility clients can attach after rendering and must see current cells.
@Suite("AXTable lazy materialization")
@MainActor
struct TableAXLazyMaterializationTests {

    private static let source = "| Name | Status |\n| - | - |\n| Rocket | Good |\n| Bella | Fine |"

    private func makeOverlay(
        source: String = TableAXLazyMaterializationTests.source
    ) -> (scrollView: NSScrollView, textView: NSTextView, overlay: CommentBadgeOverlay) {
        let (scrollView, textView, _, attr) = makeWideTableHarness(source: source)
        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.updateBadges(attr: attr, textView: textView)
        return (scrollView, textView, overlay)
    }

    @Test("a structural change drops the built tree and the next query rebuilds it")
    func structuralChangeInvalidates() throws {
        let (_, textView, overlay) = makeOverlay()
        let original = try #require(overlay.tableAccessibilityElements.first)
        let originalRows = try #require(original.accessibilityRows() as? [NSAccessibilityElement])
        let originalCells = try #require(originalRows[1].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(originalCells[1].accessibilityLabel() == "Status: Good")

        let changed = attributedMarkdown(
            "| Name | Status |\n| - | - |\n| Rocket | Great |\n| Bella | Fine |")
        textView.textStorage?.setAttributedString(changed)
        overlay.updateBadges(attr: changed, textView: textView)

        let rebuilt = try #require(overlay.tableAccessibilityElements.first)
        let rows = try #require(rebuilt.accessibilityRows() as? [NSAccessibilityElement])
        let cells = try #require(rows[1].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(cells[1].accessibilityLabel() == "Status: Great")
    }

    @Test("a client attaching after the render still reaches every cell, with live frames", arguments: [false, true])
    func clientAttachingAfterRender(emptyRow: Bool) throws {
        let source =
            emptyRow
            ? "| A | B |\n| - | - |\n| x | y |\n|  |  |\n| z | w |"
            : Self.source
        let (scrollView, _, overlay) = makeOverlay(source: source)
        let rowCount = emptyRow ? 4 : 3

        // The whole point of deferring: the tree is built by the first query,
        // which can arrive long after the document rendered.
        let window = NSWindow(
            contentRect: scrollView.bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.contentView = nil; window.close() }
        #expect(overlay.window != nil, "premise: the overlay is now in a window")

        let children = try #require(overlay.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(!children.isEmpty, "premise: accessibilityChildren must not be vacuously empty")

        let table = try #require(children.first { $0.accessibilityRole() == .table })
        #expect(table.accessibilityRole() == .table)
        #expect(table.accessibilityRowCount() == rowCount)
        #expect(table.accessibilityColumnCount() == 2)

        let rows = try #require(table.accessibilityRows() as? [NSAccessibilityElement])
        #expect(rows.count == rowCount)
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
        #expect(bodyCells[0].accessibilityLabel() == (emptyRow ? "A: x" : "Name: Rocket"))

        let headerCells = try #require(rows[0].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(headerCells[0].accessibilityLabel() == (emptyRow ? "A, column header" : "Name, column header"))

        let headerElements = try #require(
            table.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement]
        )
        #expect(headerElements.count == 2)
        #expect(bodyCells[0].accessibilityFrame() != .zero)
        for row in rows {
            let cells = try #require(row.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(cells.count == 2)
            for cell in cells {
                #expect(cell.accessibilityFrame().width > 0)
                #expect(cell.accessibilityFrame().height > 0)
            }
        }
    }
}
