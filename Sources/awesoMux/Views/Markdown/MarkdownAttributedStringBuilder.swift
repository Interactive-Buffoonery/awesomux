import AppKit
import AwesoMuxCore
import DesignSystem
// Only the type: a full `import SwiftUI` shadows Core's `TableColumnAlignment`.
import struct SwiftUI.Color

// MARK: - Attribute keys

extension NSAttributedString.Key {
    /// The comment marker ID for runs inside `<mark>...</mark>`.
    static let markID = NSAttributedString.Key("awesomux.markID")

    /// Present on table-cell content runs so `CommentBadgeOverlay` can draw
    /// borders and expose cell accessibility elements.
    static let tableCellGrid = NSAttributedString.Key("awesomux.tableCellGrid")

    /// Present on added/removed diff lines, valued with the palette `NSColor`
    /// the `CommentBadgeOverlay` washes across the full row. A run background
    /// attribute would stop at the last glyph; a diff row reads as a row only
    /// when the tint spans the whole line.
    static let diffLineTint = NSAttributedString.Key("awesomux.diffLineTint")

    /// Present on every run of a branch-changes file heading; value is the
    /// section key from `BranchDiffSectionIndex`. The overlay draws the chevron
    /// and counts at this range and toggles the fold on click.
    static let diffSectionKey = NSAttributedString.Key("awesomux.diffSectionKey")
    /// Present on hunk-header runs; the overlay draws a hairline above the row.
    static let diffHunkRule = NSAttributedString.Key("awesomux.diffHunkRule")
}

/// Identifies which table cell a character range belongs to, for the border pass.
/// Hashable because it rides NSAttributedString as an attribute value — the
/// storage's run coalescing calls ObjC `-hash` on it, and an Equatable-only
/// Swift box degrades that to a constant hash (severe-performance warning).
struct TableCellGrid: Hashable {
    let table: Int
    let row: Int
    let column: Int
    let isHeader: Bool
}

// MARK: - MarkdownAttributedStringBuilder

/// Pure converter from `RenderedDocument` → `NSAttributedString`.
///
/// ## INVARIANT
/// `attr.string == doc.runs.map(\.text).joined()`
///
/// No characters are inserted beyond `run.text` — badge decorations live in
/// `CommentBadgeOverlay`, and highlights are attribute-only mutations.
///
/// ## Custom attribute keys
/// - `.markID` (Int): present only on runs with a non-nil `run.markID`. Value
///   matches the N in `<!-- USER COMMENT N: … -->`.
///
/// Source mapping (selection spans, scroll anchors) works directly off
/// `RenderedDocument.runs` via `SelectionSourceMapping` — no per-character
/// source attribute is stored here (INT-567 removed the old `.sourceOffset`
/// key, which stamped only run-start offsets and nothing read anymore).
enum MarkdownAttributedStringBuilder {
    /// Leading space reserved on section headings for the fold chevron.
    static let sectionHeadingGutter: CGFloat = 18
    /// Trailing space reserved on section headings so a long path wraps before
    /// the counts badge instead of running under it. Wide enough for
    /// "+99999 −99999" in the badge font plus padding.
    static let sectionHeadingTrailingReserve: CGFloat = 104

    private static let bareRelativeMarkdownPathRegex: NSRegularExpression = {
        let escapedExtensions = DocumentURLValidator.allowedExtensions
            .sorted()
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pathSegment = #"[A-Za-z0-9_+@%.-]+"#
        let pattern =
            #"(?<![A-Za-z0-9_./~%-])(?:(?:\.{1,2})/)*"#
            + pathSegment
            + #"(?:/"#
            + pathSegment
            + #")*\.("#
            + escapedExtensions
            + #")(?:#[A-Za-z0-9._~!$&'()*+,;=:@/?%-]+)?(?=$|[^A-Za-z0-9_+@%./-]|\.(?=$|\s|[\])}>\"']))"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Derive a legible body text color from the terminal background color.
    ///
    /// `GhosttyRuntime` exposes the terminal background but not the configured
    /// foreground. Use the same 0.18 luminance threshold as `AwColor` and
    /// `HighlightContrast` so text and highlight contrast agree.
    static func textColor(forTerminalBackground bg: NSColor) -> NSColor {
        // Normalize to sRGB so component access doesn't throw on pattern/catalog colors.
        let srgb =
            bg.usingColorSpace(.sRGB)
            ?? NSColor(
                srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1
            )
        let luminance = relativeLuminance(srgb)
        if luminance < 0.18 {
            return NSColor(srgbRed: 0.80, green: 0.84, blue: 0.96, alpha: 1)
        } else {
            return NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        }
    }

    /// Heading run index → section key, for the runs of `doc` (which may be a
    /// folded copy of the document the index was built on).
    private static func sectionKeysByRun(in doc: RenderedDocument, index: BranchDiffSectionIndex) -> [Int: String] {
        var out: [Int: String] = [:]
        var occurrences: [String: Int] = [:]
        // Membership only, resolved once: `index.section(key:)` per heading was
        // a linear scan, so a diff with thousands of files paid O(n²) on the
        // main thread per rebuild (review).
        let known = Set(index.keys)
        for heading in BranchDiffSectionIndex.headingSpans(in: doc.runs) {
            let text = BranchDiffSectionIndex.keyText(headingRuns: doc.runs[heading])
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            let key = BranchDiffSectionIndex.key(keyText: text, occurrence: occurrence)
            guard known.contains(key) else { continue }
            for r in heading { out[r] = key }
        }
        return out
    }

    static func attributedString(
        for doc: RenderedDocument,
        textColor: NSColor? = nil,
        terminalBackground: NSColor? = nil,
        relativeLinkBaseURL: URL? = nil,
        allowsDocumentLinks: Bool = true,
        sectionIndex: BranchDiffSectionIndex? = nil
    ) -> NSAttributedString {
        // Pre-join so the backing storage allocates once; appending one
        // attributed substring per run is noticeably expensive on long documents.
        let fullText = doc.runs.map(\.text).joined()
        let result = NSMutableAttributedString(string: fullText)
        let diffPalette = DiffPalette(terminalBackground: terminalBackground)
        let keyForRun = sectionIndex.map { sectionKeysByRun(in: doc, index: $0) } ?? [:]

        var location = 0
        for (runIndex, run) in doc.runs.enumerated() {
            // NSRange is UTF-16-based; use the NSString length, not Character count.
            let length = (run.text as NSString).length
            guard length > 0 else { continue }
            let range = NSRange(location: location, length: length)
            defer { location += length }

            result.addAttribute(.font, value: font(for: run), range: range)
            if let key = keyForRun[runIndex] {
                result.addAttribute(.diffSectionKey, value: key as NSString, range: range)
                result.addAttribute(.paragraphStyle, value: sectionHeadingParagraphStyle, range: range)
            }
            if case .diffLine(.hunk) = run.style {
                result.addAttribute(.diffHunkRule, value: NSNumber(value: true), range: range)
            }
            if case .diffLine(let kind) = run.style {
                result.addAttribute(.paragraphStyle, value: diffLineParagraphStyle, range: range)
                // Layout attributes, so outside the color guard below: the
                // overlay reads the tint to place row washes whether or not a
                // text color was supplied.
                if let tint = diffPalette.tint(kind) {
                    result.addAttribute(.diffLineTint, value: tint, range: range)
                }
            }

            // Contrast against the terminal surface, not app chrome; inline code
            // and front matter are dimmed while staying legible.
            if let fg = textColor {
                switch run.style {
                case .frontMatter:
                    result.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.62), range: range)
                case .code:
                    result.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.85), range: range)
                case .diffLine(let kind):
                    result.addAttribute(
                        .foregroundColor, value: diffLineColor(kind, textColor: fg, palette: diffPalette),
                        range: range)
                    if let tint = diffPalette.tint(kind) {
                        // The sign in the gutter keeps the full hue so the row
                        // still reads without color vision or the tint. One
                        // UTF-16 unit: an added/removed line starts with ASCII.
                        result.addAttribute(
                            .foregroundColor, value: tint, range: NSRange(location: range.location, length: 1))
                    }
                default:
                    if run.monospaced {
                        result.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.85), range: range)
                    } else {
                        result.addAttribute(.foregroundColor, value: fg, range: range)
                    }
                }
            }

            if let markID = run.markID {
                result.addAttribute(.markID, value: markID, range: range)
            }
            if run.strikethrough {
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue, range: range)
            }
            // Only http(s) and Markdown document links become clickable. The
            // coordinator intercepts `.link` clicks and routes them through the
            // URLClassifier/MarkdownLinkIntercept safety pipeline; unsupported
            // file URLs and custom schemes are left as plain text.
            if let dest = run.linkDestination {
                let linkURL: URL?
                if let url = URL(string: dest),
                    let scheme = url.scheme?.lowercased()
                {
                    let isAllowed =
                        scheme == "https" || scheme == "http"
                        || MarkdownLinkIntercept.shouldOpenAsDocument(url)
                    linkURL = isAllowed ? url : nil
                } else {
                    linkURL = MarkdownLinkIntercept.documentURL(
                        forMarkdownDestination: dest,
                        relativeTo: relativeLinkBaseURL
                    )
                }
                if let linkURL,
                    allowsDocumentLinks || !isDocumentLink(linkURL)
                {
                    applyLinkAttributes(to: result, url: linkURL, range: range)
                }
            } else if allowsDocumentLinks, shouldAutoLinkBareRelativePaths(in: run) {
                applyBareRelativeDocumentLinks(
                    to: result,
                    runText: run.text,
                    runRange: range,
                    relativeTo: relativeLinkBaseURL
                )
            }
        }
        applyTableLayout(result, doc: doc)
        return result
    }

    private static func isDocumentLink(_ url: URL) -> Bool {
        if case .document = MarkdownLinkRouting.route(url) {
            return true
        }
        return false
    }

    private static func shouldAutoLinkBareRelativePaths(in run: RenderedRun) -> Bool {
        guard !run.monospaced else { return false }
        switch run.style {
        case .frontMatter, .code, .diffLine:
            return false
        default:
            return true
        }
    }

    private static func applyBareRelativeDocumentLinks(
        to result: NSMutableAttributedString,
        runText: String,
        runRange: NSRange,
        relativeTo relativeLinkBaseURL: URL?
    ) {
        guard relativeLinkBaseURL != nil else { return }

        let nsText = runText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        bareRelativeMarkdownPathRegex.enumerateMatches(in: runText, range: fullRange) { match, _, _ in
            guard let match else { return }
            let candidate = nsText.substring(with: match.range)
            guard
                let linkURL = MarkdownLinkIntercept.documentURL(
                    forMarkdownDestination: candidate,
                    relativeTo: relativeLinkBaseURL
                )
            else {
                return
            }

            applyLinkAttributes(
                to: result,
                url: linkURL,
                range: NSRange(
                    location: runRange.location + match.range.location,
                    length: match.range.length
                )
            )
        }
    }

    private static func applyLinkAttributes(
        to result: NSMutableAttributedString,
        url: URL,
        range: NSRange
    ) {
        result.addAttribute(.link, value: url, range: range)
        // Keep link styling independent of the text view's linkTextAttributes.
        result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    // MARK: - Table layout (tab stops + grid attribute)

    /// Horizontal padding added on each side of a cell's content when computing
    /// column widths / tab stops. Also the inset the border pass strokes to.
    static let tableCellPadding: CGFloat = 10

    /// Vertical breathing room above and below each table row's text, applied
    /// as symmetric paragraph spacing. The border pass draws each horizontal
    /// rule this same distance past the row's glyphs, so the rule lands
    /// centered in the gap between rows (GUI smoke: text was nearly touching
    /// the rules).
    static let tableRowVerticalPadding: CGFloat = 5

    /// Lays out Markdown tables with TextKit 2-compatible tab stops and stamps
    /// `.tableCellGrid` for the border/accessibility pass.
    private static func applyTableLayout(_ result: NSMutableAttributedString, doc: RenderedDocument) {
        struct CellRun { let range: NSRange; let grid: TableCellGrid }
        var cellRuns: [CellRun] = []
        // Accumulate per-cell width across inline runs before reducing to each
        // column's maximum width.
        struct CellKey: Hashable { let table: Int; let row: Int; let column: Int }
        var cellWidth: [CellKey: CGFloat] = [:]
        var columnAlign: [Int: [Int: TableColumnAlignment]] = [:]

        var location = 0
        for run in doc.runs {
            let length = (run.text as NSString).length
            let range = NSRange(location: location, length: length)
            location += length
            guard length > 0 else { continue }
            let (table, row, column, isHeader): (Int, Int, Int, Bool)
            let alignment: TableColumnAlignment
            switch run.style {
            case let .tableHeader(t, r, c, a): (table, row, column, isHeader) = (t, r, c, true); alignment = a
            case let .tableCell(t, r, c, a): (table, row, column, isHeader) = (t, r, c, false); alignment = a
            default: continue
            }
            let grid = TableCellGrid(table: table, row: row, column: column, isHeader: isHeader)
            let width = (run.text as NSString).size(withAttributes: [.font: font(for: run)]).width
            cellRuns.append(CellRun(range: range, grid: grid))
            cellWidth[CellKey(table: table, row: row, column: column), default: 0] += width
            columnAlign[table, default: [:]][column] = alignment
        }
        guard !cellRuns.isEmpty else { return }

        // Wide tables still wrap at the pane edge because each row is one
        // paragraph; `CommentBadgeOverlay` suppresses borders for wrapped cells.
        var columnWidths: [Int: [Int: CGFloat]] = [:]
        for (key, width) in cellWidth {
            columnWidths[key.table, default: [:]][key.column] =
                max(columnWidths[key.table]?[key.column] ?? 0, width)
        }

        // NSTextTab positions the text after the tab; store each column's start
        // x-position so the next stop lands past the previous column's max width.
        let gutter = tableCellPadding * 2
        var columnStart: [Int: [CGFloat]] = [:]
        for (table, widths) in columnWidths {
            let columnCount = (widths.keys.max() ?? 0) + 1
            var starts: [CGFloat] = []
            var x: CGFloat = tableCellPadding
            for c in 0..<columnCount {
                starts.append(x)
                x += (widths[c] ?? 0) + gutter
            }
            columnStart[table] = starts
        }

        var tableStyle: [Int: NSParagraphStyle] = [:]
        for (table, starts) in columnStart {
            guard let widths = columnWidths[table] else { continue }
            let paragraph = NSMutableParagraphStyle()
            // Column 0 starts at the head indent; later columns use tab stops
            // placed at the left edge, right edge, or center by GFM alignment.
            paragraph.tabStops = starts.enumerated().dropFirst().map { idx, start in
                let align = columnAlign[table]?[idx] ?? .left
                let width = widths[idx] ?? 0
                let location: CGFloat
                switch align {
                case .left: location = start
                case .right: location = start + width
                case .center: location = start + width / 2
                }
                return NSTextTab(textAlignment: nsAlignment(align), location: location, options: [:])
            }
            paragraph.firstLineHeadIndent = starts.first ?? tableCellPadding
            paragraph.headIndent = starts.first ?? tableCellPadding
            // Symmetric row padding; the grid pass mirrors this as its rule
            // offset so rules bisect the row gaps.
            paragraph.paragraphSpacingBefore = tableRowVerticalPadding
            paragraph.paragraphSpacing = tableRowVerticalPadding
            // Column 0 has no leading tab, so it stays left-aligned.
            tableStyle[table] = paragraph
        }

        // Apply the paragraph style to the full row, including rows whose first
        // character is a synthetic separator or list marker.
        let ns = result.string as NSString
        for cell in cellRuns {
            result.addAttribute(.tableCellGrid, value: cell.grid, range: cell.range)
            guard let style = tableStyle[cell.grid.table] else { continue }
            result.addAttribute(.paragraphStyle, value: style, range: ns.paragraphRange(for: cell.range))
        }
    }

    private static func nsAlignment(_ a: TableColumnAlignment) -> NSTextAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    // MARK: - Highlight application

    /// Sets highlight backgrounds over every `.markID` range without changing
    /// the string's characters.
    static func applyHighlights(
        _ attr: NSMutableAttributedString,
        highlightColor: NSColor,
        resolvedIDs: Set<String> = [],
        hiddenIDs: Set<String> = []
    ) {
        attr.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: attr.length))

        // Resolved annotations swap to a neutral gray — a categorical hue
        // difference, not a fainter version of the open color, so the state
        // survives low-contrast displays and Increase Contrast (WCAG 1.4.1).
        let resolvedColor = NSColor.systemGray.withAlphaComponent(
            max(highlightColor.alphaComponent * 0.8, 0.18)
        )
        attr.enumerateAttribute(
            .markID,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, range, _ in
            guard let markID = value as? String, !hiddenIDs.contains(markID) else { return }
            let color = resolvedIDs.contains(markID) ? resolvedColor : highlightColor
            attr.addAttribute(.backgroundColor, value: color, range: range)
        }
    }

    // MARK: - Luminance helper

    /// WCAG 2.1 relative luminance. Keep in sync with `HighlightContrast` and
    /// `AwColor`; they share the 0.18 dark-threshold.
    private static func relativeLuminance(_ color: NSColor) -> Double {
        func linearize(_ v: CGFloat) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.redComponent)
            + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }

    // MARK: - Font resolution

    private static func font(for run: RenderedRun) -> NSFont {
        if run.monospaced {
            // This early return bypasses `.tableHeader` below.
            if case .tableHeader = run.style {
                return monoFont(bold: true, italic: run.italic)
            }
            return monoFont(bold: run.bold, italic: run.italic)
        }
        switch run.style {
        case .frontMatter:
            return monoFont(bold: false, italic: false)
        case .heading(let level):
            return headingFont(level: level, italic: run.italic)
        case .code:
            return monoFont(bold: run.bold, italic: run.italic)
        case .diffLine:
            // Never bold or italic (the builder emits diff lines with no inline
            // style), so one cached font serves every line of the document.
            return diffLineFont
        case .tableHeader:
            return bodyFont(bold: true, italic: run.italic)
        case .tableCell:
            return bodyFont(bold: run.bold, italic: run.italic)
        default:
            return bodyFont(bold: run.bold, italic: run.italic)
        }
    }

    private static func bodyFont(bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return applyTraits(to: base, bold: bold, italic: italic)
    }

    private static func headingFont(level: Int, italic: Bool) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 28
        case 2: size = 22
        case 3: size = 18
        case 4: size = 16
        case 5: size = 14
        default: size = 13
        }
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        return applyTraits(to: base, bold: false, italic: italic)
    }

    // MARK: - Diff lines

    /// The three palette hues a diff needs, resolved once per document rather
    /// than once per line.
    ///
    /// Resolved against the terminal background when the caller knows it: the
    /// document sits on the terminal surface, whose color is independent of
    /// app appearance (INT-285), so a dynamic token keyed off light/dark mode
    /// can land Mocha green on a Latte-bright terminal at 1.5:1 and take the
    /// gutter sign — the one non-color cue — with it. Without a background the
    /// dynamic token is the best available guess.
    struct DiffPalette {
        let added: NSColor
        let removed: NSColor
        let hunk: NSColor

        init(terminalBackground: NSColor?) {
            if let terminalBackground {
                let background = Color(nsColor: terminalBackground)
                added = NSColor(Color.aw.terminalHue(.green, terminalBackground: background))
                removed = NSColor(Color.aw.terminalHue(.red, terminalBackground: background))
                hunk = NSColor(Color.aw.terminalHue(.blue, terminalBackground: background))
            } else {
                added = NSColor(Color.aw.green)
                removed = NSColor(Color.aw.red)
                hunk = NSColor(Color.aw.blue)
            }
        }

        /// The row wash for a diff line, at full alpha: the overlay applies its own.
        func tint(_ kind: DiffLineKind) -> NSColor? {
            switch kind {
            case .added: return added
            case .removed: return removed
            case .hunk: return hunk
            case .meta, .context: return nil
            }
        }
    }

    /// Added and removed lines keep body-colored text over a full-row wash of
    /// the palette's green or red (see `DiffPalette.tint`), the way a review
    /// surface reads rather than a terminal: a hundred-line addition in solid
    /// green is a wall, the same lines on a faint tint are still code. Hunk
    /// headers take blue as a landmark; file headers dim toward the body color
    /// rather than taking a hue of their own, because they are navigation, not
    /// change — dimmed to the front-matter level, which is the floor this file
    /// already accepts for secondary text.
    private static func diffLineColor(_ kind: DiffLineKind, textColor fg: NSColor, palette: DiffPalette) -> NSColor {
        switch kind {
        case .added, .removed, .context: return fg.withAlphaComponent(0.85)
        case .hunk: return palette.hunk
        case .meta: return fg.withAlphaComponent(0.62)
        }
    }

    /// A wrapped diff line continues under its content, past the one-column
    /// `+`/`-` gutter, so the gutter stays a straight edge down the block. Two
    /// monospace advances, not one: a single column reads as a stray indent.
    ///
    /// Built once: a document at the renderer's budget has tens of thousands
    /// of diff lines, and every one carries this same style. Neither
    /// `NSParagraphStyle` nor `NSFont` is `Sendable` in the SDK, but both are
    /// immutable once built, which is what `nonisolated(unsafe)` asserts here.
    nonisolated(unsafe) private static let diffLineParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let advance = (" " as NSString).size(withAttributes: [.font: diffLineFont]).width
        style.headIndent = advance * 2
        return style.copy() as! NSParagraphStyle
    }()

    nonisolated(unsafe) private static let diffLineFont: NSFont = monoFont(bold: false, italic: false)

    /// A branch-changes section heading is indented to clear the fold
    /// chevron `CommentBadgeOverlay` draws at the leading edge; a wrapped
    /// heading line indents the same amount so it doesn't run under the
    /// chevron on the first line only.
    nonisolated(unsafe) private static let sectionHeadingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = sectionHeadingGutter
        style.headIndent = sectionHeadingGutter
        return style.copy() as! NSParagraphStyle
    }()

    /// The H2 font, exposed for the sticky header, which renders the current
    /// section's heading text outside this builder's run loop.
    static func sectionHeadingFont() -> NSFont { headingFont(level: 2, italic: false) }

    private static func monoFont(bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: bold ? .bold : .regular)
        return applyTraits(to: base, bold: false, italic: italic)
    }

    private static func applyTraits(to font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return font }
        let symbolicTraits = NSFontDescriptor.SymbolicTraits(rawValue: UInt32(traits.rawValue))
        let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
