import AppKit
import AwesoMuxCore

// MARK: - Attribute keys

extension NSAttributedString.Key {
    /// The comment marker ID for runs inside `<mark>...</mark>`.
    static let markID = NSAttributedString.Key("awesomux.markID")

    /// Present on table-cell content runs so `CommentBadgeOverlay` can draw
    /// borders and expose cell accessibility elements.
    static let tableCellGrid = NSAttributedString.Key("awesomux.tableCellGrid")
}

/// Identifies which table cell a character range belongs to, for the border pass.
struct TableCellGrid: Equatable {
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

    static func attributedString(
        for doc: RenderedDocument,
        textColor: NSColor? = nil,
        relativeLinkBaseURL: URL? = nil,
        allowsDocumentLinks: Bool = true
    ) -> NSAttributedString {
        // Pre-join so the backing storage allocates once; appending one
        // attributed substring per run is noticeably expensive on long documents.
        let fullText = doc.runs.map(\.text).joined()
        let result = NSMutableAttributedString(string: fullText)

        var location = 0
        for run in doc.runs {
            // NSRange is UTF-16-based; use the NSString length, not Character count.
            let length = (run.text as NSString).length
            guard length > 0 else { continue }
            let range = NSRange(location: location, length: length)
            defer { location += length }

            result.addAttribute(.font, value: font(for: run), range: range)

            // Contrast against the terminal surface, not app chrome; inline code
            // and front matter are dimmed while staying legible.
            if let fg = textColor {
                switch run.style {
                case .frontMatter:
                    result.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.62), range: range)
                case .code:
                    result.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.85), range: range)
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
        case .frontMatter, .code:
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
