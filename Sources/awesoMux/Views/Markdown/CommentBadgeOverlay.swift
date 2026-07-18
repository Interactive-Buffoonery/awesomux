import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - CommentBadgeOverlay

/// A transparent overlay view that draws `•••` pills at the TRAILING edge of the
/// LAST glyph in each `<mark>` span, plus an "add" pill for the current selection.
/// Pills are rendered via `NSView.draw(_:)` — the 1:1 text-storage invariant is
/// maintained (no characters inserted).
///
/// ## Placement
/// The overlay is added as a subview *of the `NSTextView` itself*, sized to the
/// text view's bounds. Because it is a child of the (flipped) documentView, it
/// scrolls with the document automatically — the clip view moves the documentView,
/// and the overlay rides along. All pill rects live in the **text view's flipped
/// coordinate space** (origin top-left, +Y down), and this view overrides
/// `isFlipped` to match so that space is shared 1:1 with no extra conversion.
///
/// ## Hit testing
/// `hitTest` returns `self` only for pill rects; nil elsewhere so clicks pass
/// through to the text view beneath.
@MainActor
final class CommentBadgeOverlay: NSView {

    /// Match the host `NSTextView`, which is flipped. Pill rects are computed in
    /// text-view (flipped) space; sharing the flip means no Y inversion when the
    /// overlay draws them — the bug that placed top-of-document pills at the pane
    /// bottom (INT-562 Bigfoot).
    override var isFlipped: Bool { true }

    // MARK: - Model

    struct Pill {
        let markID: String?  // the annotation id; nil for the "add" pill
        let displayNumber: Int?  // 1-based badge ordinal for accessibility; nil for "add"
        let rect: NSRect  // in overlay's coordinate space
    }

    private var pills: [Pill] = []

    /// Cell border rects to stroke, in overlay (== text-view flipped) space.
    private var tableBorderRects: [NSRect] = []

    /// Per-cell info for accessibility: each table cell's grid position, rect (overlay
    /// space), and text. Lets VoiceOver announce a body cell together with its column
    /// header ("Status: Active") instead of reading the table as a run-on line.
    struct TableCellInfo { let grid: TableCellGrid; let rect: NSRect; let text: String }
    private var tableCellInfos: [TableCellInfo] = []

    /// Cached inputs for recomputing table borders on a plain relayout (e.g. a pane
    /// resize) that doesn't route through `updateBadges`. The text view is weak (the
    /// overlay must not keep it alive); the attributed string is a strong reference
    /// to the SAME instance the text storage holds, cleared when the document has no
    /// tables so table-free docs skip the per-layout recompute entirely.
    private weak var borderTextView: NSTextView?
    private var borderAttr: NSAttributedString?

    /// Cached inputs so a plain relayout (pane resize) recomputes PILL positions
    /// too, mirroring the border cache above. Without this, a resize that
    /// rewraps marked text left pills — and their mouse/accessibility hit
    /// targets — at pre-reflow coordinates until the next source/highlight/
    /// filter change (adversarial review). Cleared for annotation-free
    /// documents so they keep the nil fast-path in `layout()`.
    private weak var badgeTextView: NSTextView?
    private var badgeAttr: NSAttributedString?
    private var badgeDisplayNumbers: [String: Int] = [:]
    private var badgeHiddenIDs: Set<String> = []

    /// Stroke color for table cell borders. Set by `MarkdownTextView.updateNSView`
    /// from the adaptive text color. Nil ⇒ no borders drawn.
    var tableBorderColor: NSColor? = nil {
        didSet { if oldValue != tableBorderColor { needsDisplay = true } }
    }

    // MARK: - Callbacks

    /// Called when a numbered pill is clicked. Arguments: annotation id, pill rect in
    /// overlay coordinates, the overlay view itself (for NSPopover anchoring).
    var onPillClicked: ((String, NSRect, NSView) -> Void)? = nil

    /// Called when the "add" pill is clicked.
    var onAddPillClicked: ((NSRect, NSView) -> Void)? = nil

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = false
    }

    // MARK: - Layout

    /// The overlay autoresizes with the text view, so a pane resize reflows the text
    /// beneath it WITHOUT routing through `updateBadges` (which only fires on a
    /// source/highlight change). Recompute pill AND table border geometry here so
    /// both track the reflowed glyph positions instead of drawing (and hit-testing)
    /// at stale coordinates.
    override func layout() {
        super.layout()
        if let attr = badgeAttr, let textView = badgeTextView {
            // Runs updateTableBorders internally and sets needsDisplay.
            updateBadges(
                attr: attr,
                textView: textView,
                displayNumbers: badgeDisplayNumbers,
                hiddenIDs: badgeHiddenIDs
            )
        } else if let attr = borderAttr, let textView = borderTextView {
            updateTableBorders(attr: attr, textView: textView)
            needsDisplay = true
        }
    }

    // MARK: - Hit testing

    /// Return self for pill rects so mouseDown fires; nil elsewhere so clicks
    /// pass through to the text view. `point` arrives in the SUPERVIEW's space, so
    /// convert into our bounds space (the overlay shares the text view's flipped
    /// origin, but convert explicitly so this stays correct if the frame ever offsets).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for pill in pills {
            if pill.rect.contains(local) { return self }
        }
        return nil
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for pill in pills {
            if pill.rect.contains(point) {
                if let markID = pill.markID {
                    onPillClicked?(markID, pill.rect, self)
                } else {
                    onAddPillClicked?(pill.rect, self)
                }
                return
            }
        }
    }

    // MARK: - Accessibility

    // The pills are custom-drawn rects with mouse-only hit-testing, so VoiceOver has
    // nothing to land on by default — yet they're the *only* way to view/edit/delete a
    // comment or add one. Expose each pill as a pressable button child whose press runs
    // the same callback a click would, so the comment affordances are operable without
    // a mouse. Elements are rebuilt on demand from the current pill list.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityChildren() -> [Any]? {
        guard window != nil else { return [] }
        return pillAccessibilityChildren() + cachedTableElements
    }

    // MARK: - AXTable tree (INT-687)

    /// Identity of one node in a table's accessibility tree, used to look up its
    /// CURRENT rect in `tableAXFrames` at query time. Elements are cached across
    /// layout passes (VoiceOver holds references while the user navigates), so
    /// their frames must be looked up live, never captured — a resize reflow
    /// would otherwise leave every held element announcing stale geometry.
    enum TableAXNode: Hashable {
        case table(Int)
        case row(table: Int, row: Int)
        case column(table: Int, column: Int)
        case cell(table: Int, row: Int, column: Int)
    }

    /// A logical table cell coalesced from its attributed runs — a cell with
    /// inline styling ("**bold** text") spans several runs sharing one
    /// (table, row, column). Rect is the union; text concatenates in document
    /// order (the attribute enumeration walks the string front to back).
    struct LogicalTableCell {
        let grid: TableCellGrid
        let rect: NSRect
        let text: String
    }

    /// One table's rectangularized grid. `cells[row][column]` is nil where GFM
    /// omitted the cell (empty cell, ragged row) — the exposed AXTable must stay
    /// rectangular so VoiceOver's row/column position math never lands in a hole.
    struct TableAXGrid {
        let table: Int
        let rowCount: Int
        let columnCount: Int
        let cells: [[LogicalTableCell?]]
    }

    private var cachedTableElements: [TableCellAccessibilityElement] = []
    private var tableAXFrames: [TableAXNode: NSRect] = [:]
    /// Structure fingerprint of the current grids (texts + shape, no geometry).
    /// The element tree rebuilds — and `.layoutChanged` posts — only when this
    /// changes; pure reflows just refresh `tableAXFrames`.
    private var tableStructureSignature: [String] = []

    /// Read-only view of the cached table elements for tests.
    var tableAccessibilityElements: [NSAccessibilityElement] { cachedTableElements }

    /// Coalesce per-run cell infos into rectangular logical grids, ordered by
    /// table serial. Pure — unit-testable without a view tree.
    static func tableAXGrids(from infos: [TableCellInfo]) -> [TableAXGrid] {
        struct Key: Hashable {
            let table: Int
            let row: Int
            let column: Int
        }
        var merged: [Key: LogicalTableCell] = [:]
        for info in infos {
            let key = Key(table: info.grid.table, row: info.grid.row, column: info.grid.column)
            if let existing = merged[key] {
                merged[key] = LogicalTableCell(
                    grid: existing.grid,
                    rect: existing.rect.union(info.rect),
                    text: existing.text + info.text
                )
            } else {
                merged[key] = LogicalTableCell(grid: info.grid, rect: info.rect, text: info.text)
            }
        }
        let byTable = Dictionary(grouping: merged.values, by: { $0.grid.table })
        return byTable.keys.sorted().compactMap { table in
            guard let cells = byTable[table], !cells.isEmpty else { return nil }
            let rowCount = (cells.map { $0.grid.row }.max() ?? 0) + 1
            let columnCount = (cells.map { $0.grid.column }.max() ?? 0) + 1
            var grid = [[LogicalTableCell?]](
                repeating: [LogicalTableCell?](repeating: nil, count: columnCount),
                count: rowCount
            )
            for cell in cells {
                grid[cell.grid.row][cell.grid.column] = cell
            }
            return TableAXGrid(
                table: table, rowCount: rowCount, columnCount: columnCount, cells: grid)
        }
    }

    /// Live-lookup frames for every AX node. Placeholder cells (grid holes) get
    /// the intersection of their row's Y-extent and column's X-extent when both
    /// are known from populated neighbors; otherwise no frame at all — inventing
    /// geometry (e.g. the whole table rect) would give VoiceOver overlapping,
    /// spatially incoherent cells.
    static func tableAXFrames(for grids: [TableAXGrid]) -> [TableAXNode: NSRect] {
        var frames: [TableAXNode: NSRect] = [:]
        for grid in grids {
            var rowRects = [NSRect?](repeating: nil, count: grid.rowCount)
            var columnRects = [NSRect?](repeating: nil, count: grid.columnCount)
            var tableRect: NSRect? = nil
            for r in 0..<grid.rowCount {
                for c in 0..<grid.columnCount {
                    guard let cell = grid.cells[r][c] else { continue }
                    rowRects[r] = rowRects[r].map { $0.union(cell.rect) } ?? cell.rect
                    columnRects[c] = columnRects[c].map { $0.union(cell.rect) } ?? cell.rect
                    tableRect = tableRect.map { $0.union(cell.rect) } ?? cell.rect
                }
            }
            if let tableRect {
                frames[.table(grid.table)] = tableRect
            }
            for r in 0..<grid.rowCount {
                if let rect = rowRects[r] {
                    frames[.row(table: grid.table, row: r)] = rect
                }
            }
            for c in 0..<grid.columnCount {
                if let rect = columnRects[c] {
                    frames[.column(table: grid.table, column: c)] = rect
                }
            }
            for r in 0..<grid.rowCount {
                for c in 0..<grid.columnCount {
                    let node = TableAXNode.cell(table: grid.table, row: r, column: c)
                    if let cell = grid.cells[r][c] {
                        frames[node] = cell.rect
                    } else if let rowRect = rowRects[r], let columnRect = columnRects[c] {
                        frames[node] = NSRect(
                            x: columnRect.minX, y: rowRect.minY,
                            width: columnRect.width, height: rowRect.height
                        )
                    }
                }
            }
        }
        return frames
    }

    /// Rebuild the cached table/row/column/cell element tree. Called only on a
    /// structural change; frames stay live through `tableAXFrames` lookups.
    private func rebuildTableAccessibilityElements(grids: [TableAXGrid]) {
        cachedTableElements = grids.map { grid in
            let tableElement = liveFrameElement(role: .table, node: .table(grid.table))
            tableElement.setAccessibilityParent(self)

            // Header text per column, for the header-association labels VoiceOver
            // reads on body cells ("Status: Active") — kept from the shipped
            // slice so a cell remains meaningful even outside table navigation.
            var headerText: [Int: String] = [:]
            for c in 0..<grid.columnCount {
                for r in 0..<grid.rowCount where grid.cells[r][c]?.grid.isHeader == true {
                    headerText[c] = grid.cells[r][c]?.text
                    break
                }
            }

            var rowElements: [TableCellAccessibilityElement] = []
            var headerCellElements: [TableCellAccessibilityElement] = []
            var cellsByColumn = [[TableCellAccessibilityElement]](
                repeating: [], count: grid.columnCount)
            for r in 0..<grid.rowCount {
                let rowElement = liveFrameElement(
                    role: .row, node: .row(table: grid.table, row: r))
                rowElement.setAccessibilityParent(tableElement)
                rowElement.setAccessibilityIndex(r)
                var cellElements: [TableCellAccessibilityElement] = []
                for c in 0..<grid.columnCount {
                    let cellElement = liveFrameElement(
                        role: .cell, node: .cell(table: grid.table, row: r, column: c))
                    cellElement.setAccessibilityParent(rowElement)
                    cellElement.setAccessibilityRowIndexRange(NSRange(location: r, length: 1))
                    cellElement.setAccessibilityColumnIndexRange(NSRange(location: c, length: 1))
                    let cell = grid.cells[r][c]
                    let text = cell?.text ?? ""
                    if cell?.grid.isHeader == true {
                        cellElement.setAccessibilityLabel("\(text), column header")
                        headerCellElements.append(cellElement)
                    } else if let header = headerText[c], !header.isEmpty, !text.isEmpty {
                        cellElement.setAccessibilityLabel("\(header): \(text)")
                    } else {
                        cellElement.setAccessibilityLabel(text)
                    }
                    cellElements.append(cellElement)
                    cellsByColumn[c].append(cellElement)
                }
                rowElement.setAccessibilityChildren(cellElements)
                rowElements.append(rowElement)
            }

            let columnElements = (0..<grid.columnCount).map { c -> TableCellAccessibilityElement in
                let columnElement = liveFrameElement(
                    role: .column, node: .column(table: grid.table, column: c))
                columnElement.setAccessibilityParent(tableElement)
                columnElement.setAccessibilityIndex(c)
                columnElement.setAccessibilityChildren(cellsByColumn[c])
                return columnElement
            }

            tableElement.setAccessibilityRows(rowElements)
            tableElement.setAccessibilityColumns(columnElements)
            tableElement.setAccessibilityRowCount(grid.rowCount)
            tableElement.setAccessibilityColumnCount(grid.columnCount)
            tableElement.setAccessibilityColumnHeaderUIElements(headerCellElements)
            tableElement.setAccessibilityChildren(rowElements + columnElements)
            return tableElement
        }
    }

    private func liveFrameElement(
        role: NSAccessibility.Role, node: TableAXNode
    ) -> TableCellAccessibilityElement {
        let element = TableCellAccessibilityElement()
        element.setAccessibilityRole(role)
        element.frameProvider = { [weak self] in
            guard let self, let window = self.window,
                let rect = self.tableAXFrames[node]
            else { return .zero }
            return window.convertToScreen(self.convert(rect, to: nil))
        }
        return element
    }

    private func pillAccessibilityChildren() -> [NSAccessibilityElement] {
        return pills.map { pill in
            let element = PillAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(
                Self.pillAccessibilityLabel(
                    displayNumber: pill.displayNumber,
                    isAddPill: pill.markID == nil
                )
            )
            // Compute the screen frame LIVE from the pill's (scroll-stable) doc-space
            // rect through this overlay — pill rects only recompute on layout, so a
            // snapshot frame would go stale (and mis-announce positions to VoiceOver)
            // the moment the user scrolls. The overlay scrolls with the document, so
            // converting through it always reflects the current scroll offset.
            let pillRect = pill.rect
            element.frameProvider = { [weak self] in
                guard let self, let window = self.window else { return .zero }
                return window.convertToScreen(self.convert(pillRect, to: nil))
            }
            element.onPress = { [weak self] in
                guard let self else { return }
                if let markID = pill.markID {
                    self.onPillClicked?(markID, pill.rect, self)
                } else {
                    self.onAddPillClicked?(pill.rect, self)
                }
            }
            return element
        }
    }

    static func pillAccessibilityLabel(displayNumber: Int?, isAddPill: Bool) -> String {
        if isAddPill { return "Add comment" }
        return displayNumber.map { "Comment \($0)" } ?? "Comment"
    }

    // MARK: - Badge update

    /// Recompute pill positions from the text layout manager.
    ///
    /// Each pill is anchored at the **trailing edge of the mark's last glyph**, not
    /// the line fragment's trailing edge — Fix 2 (INT-562). For a mark in the middle
    /// of a paragraph the pill sits immediately after the highlighted text regardless
    /// of line length; for a mark that wraps, the pill appears after the last glyph
    /// on the mark's final wrapped line.
    ///
    /// All resulting pill rects are in **this overlay's coordinate space, which is
    /// identical to the text view's flipped space** (the overlay is a bounds-sized
    /// subview of the text view and overrides `isFlipped`). The mark's last-glyph
    /// rect comes from `glyphTrailingRectInTextView`, which converts
    /// `firstRect(forCharacterRange:)` (screen) → window → text-view space.
    func updateBadges(
        attr: NSAttributedString,
        textView: NSTextView,
        displayNumbers: [String: Int] = [:],
        hiddenIDs: Set<String> = []
    ) {
        guard textView.textLayoutManager != nil,
            textView.textContentStorage != nil,
            textView.textContainer != nil
        else {
            // Remove all non-add pills but keep any existing add pill.
            pills = pills.filter { $0.markID == nil }
            needsDisplay = true
            return
        }

        // Collect the full NSRange for each markID by unioning all attribute runs.
        // A multi-run mark (e.g. bold + mark on the same span) produces several runs
        // with the same markID; we need the span's overall last character.
        var markRangeByID: [String: NSRange] = [:]
        attr.enumerateAttribute(
            .markID,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, nsRange, _ in
            guard let markID = value as? String else { return }
            if let existing = markRangeByID[markID] {
                let newLoc = min(existing.location, nsRange.location)
                let newMax = max(NSMaxRange(existing), NSMaxRange(nsRange))
                markRangeByID[markID] = NSRange(location: newLoc, length: newMax - newLoc)
            } else {
                markRangeByID[markID] = nsRange
            }
        }

        var newPills: [Pill] = []

        for (markID, fullRange) in markRangeByID {
            guard fullRange.length > 0, !hiddenIDs.contains(markID) else { continue }

            // Glyph-level trailing edge of the mark's last character, in text-view
            // (== overlay) space. firstRect respects ligatures/RTL/composite glyphs;
            // for a wrapped mark it returns the final glyph's line fragment.
            guard
                let tvRect = Self.glyphTrailingRectInTextView(
                    lastCharOf: fullRange, in: textView
                )
            else { continue }

            newPills.append(
                Pill(
                    markID: markID,
                    displayNumber: displayNumbers[markID],
                    rect: Self.pillRect(afterTrailingRect: tvRect)
                ))
        }

        newPills.sort { $0.rect.minY < $1.rect.minY }

        // Preserve the existing add pill (nil markID); it is managed by updateAddPill.
        let addPill = pills.first(where: { $0.markID == nil })
        pills = newPills + (addPill.map { [$0] } ?? [])

        // Cache inputs so layout() can recompute pill geometry on a resize
        // reflow; cleared when the document has no marks (fast path).
        if markRangeByID.isEmpty {
            badgeAttr = nil
            badgeTextView = nil
            badgeDisplayNumbers = [:]
            badgeHiddenIDs = []
        } else {
            badgeAttr = attr
            badgeTextView = textView
            badgeDisplayNumbers = displayNumbers
            badgeHiddenIDs = hiddenIDs
        }

        updateTableBorders(attr: attr, textView: textView)
        needsDisplay = true
    }

    /// Recompute table cell border rects from the `.tableCellGrid` attribute ranges.
    /// Each cell's rect is the union of its per-line glyph rects (converted to
    /// text-view/overlay space), padded to sit just outside the text. A cell that
    /// laid out across more than one line fragment means its row wrapped — the
    /// tab-stop column model no longer matches the glyphs, so that table's grid is
    /// suppressed instead of stroking rules through wrapped text. Since INT-687
    /// the container is infinite (wide tables overflow into a horizontal scroll,
    /// they don't wrap), so this suppression is a safety net, not the norm.
    private func updateTableBorders(attr: NSAttributedString, textView: NSTextView) {
        // Collect each cell's text rect tagged with its grid position.
        var cells: [(grid: TableCellGrid, rect: NSRect)] = []
        var infos: [TableCellInfo] = []
        var wrappedTables: Set<Int> = []
        let full = attr.string as NSString
        attr.enumerateAttribute(
            .tableCellGrid,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, nsRange, _ in
            guard let grid = value as? TableCellGrid, nsRange.length > 0,
                let cell = Self.cellRectInTextView(range: nsRange, in: textView)
            else { return }
            if cell.segments > 1 {
                wrappedTables.insert(grid.table)
            }
            cells.append((grid, cell.rect))
            infos.append(TableCellInfo(grid: grid, rect: cell.rect, text: full.substring(with: nsRange)))
        }
        // Cache inputs so a plain relayout (resize) can refresh borders via layout();
        // clear them when there are no tables so table-free documents keep the nil
        // fast-path in layout() instead of re-enumerating on every resize frame.
        if cells.isEmpty {
            borderAttr = nil
            borderTextView = nil
        } else {
            borderAttr = attr
            borderTextView = textView
        }
        // segments > 1 suppression: since INT-687 the container is infinite and
        // table rows cannot wrap, so this is a retained safety net (e.g. a
        // TextKit fallback path), not the wide-table handler it was under the
        // width-tracking container.
        tableBorderRects = Self.gridLines(for: cells.filter { !wrappedTables.contains($0.grid.table) })
        tableCellInfos = infos

        // INT-687 AXTable upkeep: frames refresh on every pass (cached elements
        // look their rects up live), but the element tree itself rebuilds only
        // when the table STRUCTURE changes — VoiceOver holds element references
        // while navigating, and churning identities per reflow would drop its
        // cursor. Structural changes are announced so a running client re-reads.
        let grids = Self.tableAXGrids(from: infos)
        tableAXFrames = Self.tableAXFrames(for: grids)
        let signature = grids.map { grid in
            "\(grid.table)|\(grid.rowCount)x\(grid.columnCount)|"
                + grid.cells.flatMap { row in
                    row.map { $0.map { "\($0.grid.isHeader ? "h" : "c"):\($0.text)" } ?? "∅" }
                }.joined(separator: "\u{1F}")
        }
        if signature != tableStructureSignature {
            tableStructureSignature = signature
            rebuildTableAccessibilityElements(grids: grids)
            if window != nil {
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
        }
    }

    /// Build a clean grid (outer frame + interior column/row rules) from the raw
    /// per-cell text rects. Drawing a padded box per cell looks ragged: cells in a
    /// column have different text widths and the boxes overlap/gap. Instead we snap
    /// to a shared grid — per-column x-boundaries and per-row y-boundaries unioned
    /// across the whole table — and emit thin rects for each rule so `draw` can
    /// stroke them uniformly. One grid per table serial.
    static func gridLines(for cells: [(grid: TableCellGrid, rect: NSRect)]) -> [NSRect] {
        let pad = MarkdownAttributedStringBuilder.tableCellPadding
        var out: [NSRect] = []

        let byTable = Dictionary(grouping: cells, by: { $0.grid.table })
        for (_, tableCells) in byTable {
            guard !tableCells.isEmpty else { continue }

            let columns = (tableCells.map { $0.grid.column }.max() ?? 0) + 1
            let rows = (tableCells.map { $0.grid.row }.max() ?? 0) + 1

            // Per-column right edge and per-row top/bottom, seeded to sentinels so an
            // empty cell (which emits no run → no rect) leaves its column/row
            // UNPOPULATED rather than pinned to 0 or infinity. GFM allows empty cells,
            // empty columns, and ragged rows; deriving boundaries only from populated
            // cells and carrying the last-seen edge across gaps keeps the grid monotonic
            // instead of drawing a rule at 0 or ±greatestFiniteMagnitude.
            var columnMaxX = [CGFloat](repeating: -.greatestFiniteMagnitude, count: columns)
            var rowMinY = [CGFloat](repeating: .greatestFiniteMagnitude, count: rows)
            var rowMaxY = [CGFloat](repeating: -.greatestFiniteMagnitude, count: rows)
            var tableMinX = CGFloat.greatestFiniteMagnitude
            for cell in tableCells {
                columnMaxX[cell.grid.column] = max(columnMaxX[cell.grid.column], cell.rect.maxX)
                tableMinX = min(tableMinX, cell.rect.minX)
                rowMinY[cell.grid.row] = min(rowMinY[cell.grid.row], cell.rect.minY)
                rowMaxY[cell.grid.row] = max(rowMaxY[cell.grid.row], cell.rect.maxY)
            }
            guard tableMinX.isFinite else { continue }

            // x-boundaries: left frame, then each column's right edge (padded). An empty
            // column (never populated → still sentinel) inherits the previous boundary so
            // the grid stays monotonic and draws no zero-width column.
            let vpad: CGFloat = 3
            var xs: [CGFloat] = [tableMinX - pad]
            for c in 0..<columns {
                let edge = columnMaxX[c].isFinite ? columnMaxX[c] + pad : xs.last!
                xs.append(max(edge, xs.last!))
            }
            // y-boundaries: table top (first populated row's minY), then each row's
            // bottom. Empty rows inherit the previous bottom. Skip the whole table if no
            // row was populated (nothing to anchor the top edge to).
            guard let tableTop = rowMinY.filter({ $0.isFinite }).min() else { continue }
            var ys: [CGFloat] = [tableTop - vpad]
            for r in 0..<rows {
                let edge = rowMaxY[r].isFinite ? rowMaxY[r] + vpad : ys.last!
                ys.append(max(edge, ys.last!))
            }

            guard let left = xs.first, let right = xs.last,
                let top = ys.first, let bottom = ys.last
            else { continue }
            let line: CGFloat = 1

            // Vertical rules (including outer left/right).
            for x in xs {
                out.append(NSRect(x: x - line / 2, y: top, width: line, height: bottom - top))
            }
            // Horizontal rules (including outer top/bottom).
            for y in ys {
                out.append(NSRect(x: left, y: y - line / 2, width: right - left, height: line))
            }
        }
        return out
    }

    /// Bounding rect of `range` in text-view (flipped) space plus the number of
    /// layout segments it spanned, or nil if layout is unavailable. `segments > 1`
    /// means the range wrapped across line fragments — callers use it to detect
    /// tables too wide for the pane.
    ///
    /// Uses TextKit 2 segment geometry (`enumerateTextSegments`), NOT
    /// `firstRect(forCharacterRange:)`. `firstRect` returns a SCREEN rect and needs
    /// the window materialized + layout settled; on a cold open it returns `.zero`,
    /// which made the borders flaky across launches. `enumerateTextSegments` yields
    /// frames already in container space with no window dependency — the same
    /// reliable path `MarkdownTextView.scrollAnchorSourceOffset` uses. Container
    /// space → text-view space is a translation by the container origin (the
    /// text container inset). Per ADR 0018 the grid is drawn from fragment geometry.
    static func cellRectInTextView(range: NSRange, in textView: NSTextView) -> (rect: NSRect, segments: Int)? {
        guard range.length > 0,
            let layoutManager = textView.textLayoutManager,
            let contentStorage = textView.textContentStorage,
            let start = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: range.location),
            let end = contentStorage.location(start, offsetBy: range.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return nil }

        let inset = textView.textContainerInset
        var union: NSRect? = nil
        // "Segments" = DISTINCT line-fragment Y origins, not raw callbacks:
        // enumerateTextSegments can emit duplicate callbacks with identical
        // frames for one visual segment (observed with tab-stop table rows
        // under an unbounded container), and a raw count would falsely report
        // a single-line cell as wrapped.
        var lineYs: Set<CGFloat> = []
        layoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: []
        ) { _, segmentFrame, _, _ in
            let framed = segmentFrame.offsetBy(dx: inset.width, dy: inset.height)
            union = union.map { $0.union(framed) } ?? framed
            lineYs.insert(framed.minY.rounded())
            return true
        }
        return union.map { ($0, lineYs.count) }
    }

    /// Add or remove the "add" pill at the trailing edge of the current selection.
    /// `trailingRect` is the last selected glyph's rect in overlay (text-view) space.
    /// Pass `nil` to remove the add pill.
    func updateAddPill(trailingRect: NSRect?) {
        pills.removeAll { $0.markID == nil }

        guard let trailingRect else {
            needsDisplay = true
            return
        }

        pills.append(
            Pill(
                markID: nil,
                displayNumber: nil,
                rect: Self.pillRect(afterTrailingRect: trailingRect)
            ))
        needsDisplay = true
    }

    // MARK: - Pure geometry helpers

    /// The trailing-edge rect of the **last character** of `range`, expressed in the
    /// text view's (flipped) coordinate space — the same space this overlay uses.
    ///
    /// `firstRect(forCharacterRange:)` returns a SCREEN rect; this converts
    /// screen → window → text-view. Returns `nil` when layout/window is unavailable
    /// (e.g. before the view is on screen) so the caller can skip that pill rather
    /// than place it at a bogus origin.
    static func glyphTrailingRectInTextView(
        lastCharOf range: NSRange,
        in textView: NSTextView
    ) -> NSRect? {
        guard range.length > 0 else { return nil }
        let lastCharRange = NSRange(location: NSMaxRange(range) - 1, length: 1)
        var actualRange = NSRange()
        let screenRect = textView.firstRect(
            forCharacterRange: lastCharRange,
            actualRange: &actualRange
        )
        return textViewRect(fromScreenRect: screenRect, in: textView)
    }

    static func textViewRect(fromScreenRect screenRect: NSRect, in textView: NSTextView) -> NSRect? {
        guard screenRect != .zero, let window = textView.window else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        return textView.convert(windowRect, from: nil)
    }

    /// Builds the pill's rect immediately after the trailing edge of `trailingRect`,
    /// vertically centred on it. Pure function of the trailing rect + the pill's
    /// intrinsic size — unit-testable without a live view tree.
    static func pillRect(afterTrailingRect trailingRect: NSRect) -> NSRect {
        let labelSize = ("•••" as NSString).size(withAttributes: [.font: pillFontStatic()])
        let pillHeight = labelSize.height + 4
        let pillWidth = labelSize.width + 8
        let origin = NSPoint(
            x: trailingRect.maxX + 4,
            y: trailingRect.midY - pillHeight / 2
        )
        return NSRect(origin: origin, size: NSSize(width: pillWidth, height: pillHeight))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Table borders first, behind pills. NSTextTable is TextKit 1 only, so we
        // draw the grid ourselves. Each entry is a 1pt-thin rule rect — fill it so
        // the width stays exactly 1pt (stroking a thin rect doubles the visual line).
        if let borderColor = tableBorderColor, !tableBorderRects.isEmpty {
            borderColor.setFill()
            for rect in tableBorderRects {
                rect.fill()
            }
        }
        for pill in pills {
            drawPill(at: pill.rect, isAdd: pill.markID == nil)
        }
    }

    private func pillFont() -> NSFont { Self.pillFontStatic() }

    static func pillFontStatic() -> NSFont {
        NSFont.systemFont(ofSize: 10, weight: .medium)
    }

    private func drawPill(at rect: NSRect, isAdd: Bool) {
        let pillLabel = "•••"
        let font = pillFont()

        // Fix 1 + Fix 4 (INT-562): opaque Catppuccin Mauve pill background so the pill
        // occludes text behind it and reads as a solid affordance. The add-pill uses
        // the same hue at 0.55 alpha so it reads as a lighter "pending" state while
        // still covering text beneath it (much less transparent than the old 0.12).
        // Use the public Color.aw design-system API; NSColor(Color) resolves the dynamic
        // SwiftUI color to the current appearance.
        let mauveColor = NSColor(Color.aw.mauve)
        let bgColor =
            isAdd
            ? mauveColor.withAlphaComponent(0.55)
            : mauveColor.withAlphaComponent(0.96)

        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        bgColor.setFill()
        path.fill()

        // Glyph color: on the opaque pill use the Catppuccin base (near-black dark bg /
        // near-white light bg) for maximum contrast; on the translucent add pill use the
        // fully-saturated mauve so the dots still read against variable document bgs.
        let glyphColor: NSColor =
            isAdd
            ? mauveColor
            : NSColor(Color.aw.surface.window)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: glyphColor,
        ]

        let labelSize = (pillLabel as NSString).size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: rect.minX + (rect.width - labelSize.width) / 2,
            y: rect.minY + (rect.height - labelSize.height) / 2
        )
        (pillLabel as NSString).draw(at: textOrigin, withAttributes: attrs)
    }
}

// MARK: - PillAccessibilityElement

/// Accessibility proxy for a single drawn pill. VoiceOver lands on it as a button;
/// pressing it runs the same handler a mouse click would (open/compose/edit popover).
final class PillAccessibilityElement: NSAccessibilityElement {
    /// Computes the pill's current screen frame on demand (converts the pill's
    /// scroll-stable doc-space rect through the live overlay, so the frame tracks
    /// scrolling — a snapshot would mis-announce button positions after a scroll).
    /// `frameProvider`/`onPress` are typed `@MainActor` so the nonisolated overrides
    /// can only invoke them inside an `assumeIsolated` block — AppKit delivers both
    /// accessibility queries and presses on the main thread. Storing closures (not the
    /// NSView) keeps a non-Sendable view from crossing the isolation boundary.
    var frameProvider: (@MainActor () -> NSRect)?
    var onPress: (@MainActor () -> Void)?

    override func accessibilityFrame() -> NSRect {
        guard let frameProvider else { return .zero }
        return MainActor.assumeIsolated { frameProvider() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }
}

// MARK: - TableCellAccessibilityElement

/// Accessibility proxy for one node of a table's AXTable tree — the table
/// itself, a row, a column, or a cell (role set by the overlay). Read-only —
/// none are pressable. Frame is computed live (a `tableAXFrames` lookup through
/// the overlay) so it tracks both scrolling and reflow, mirroring
/// `PillAccessibilityElement`.
final class TableCellAccessibilityElement: NSAccessibilityElement {
    var frameProvider: (@MainActor () -> NSRect)?

    override func accessibilityFrame() -> NSRect {
        guard let frameProvider else { return .zero }
        return MainActor.assumeIsolated { frameProvider() }
    }
}
