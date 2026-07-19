import Testing
import AppKit
import AwesoMuxCore
import SwiftUI
@testable import awesoMux

// MARK: - MarkdownAttributedStringBuilder tests

@Suite("MarkdownAttributedStringBuilder")
struct MarkdownTextViewTests {

    @Test("read-only snapshots render document links as plain text")
    func readOnlySnapshotDocumentLinksArePlainText() throws {
        let doc = AttributedMarkdownBuilder.build("[local](next.md) [web](https://example.com)")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp"),
            allowsDocumentLinks: false
        )
        let localRange = try #require(attr.string.range(of: "local"))
        let webRange = try #require(attr.string.range(of: "web"))

        #expect(attr.attribute(.link, at: NSRange(localRange, in: attr.string).location, effectiveRange: nil) == nil)
        #expect(attr.attribute(.link, at: NSRange(webRange, in: attr.string).location, effectiveRange: nil) != nil)
    }

    // MARK: - (a) 1:1 invariant

    /// The NSAttributedString's plain-text string must exactly equal the joined
    /// text of all RenderedRuns — no extra badge characters, no markup strings.
    @Test("1:1 invariant: attr.string equals runs joined")
    func invariantAttrStringEqualsRunsJoined() {
        let source = "# Hello\n\nThis is **bold** and _italic_ text.\n\nSome `code` here."
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)

        let expected = doc.runs.map(\.text).joined()
        #expect(attr.string == expected)
    }

    @Test("1:1 invariant holds for empty document")
    func invariantEmptyDocument() {
        let doc = AttributedMarkdownBuilder.build("")
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)
        #expect(attr.string == doc.runs.map(\.text).joined())
        #expect(attr.string == "")
    }

    @Test("1:1 invariant holds for document with lists")
    func invariantWithLists() {
        let source = "- item one\n- item two\n- item three"
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)
        let expected = doc.runs.map(\.text).joined()
        #expect(attr.string == expected)
    }

    @Test("1:1 invariant holds for ordered list — synthetic number-prefix runs included")
    func invariantWithOrderedList() {
        let source = "1. one\n2. two"
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)
        let expected = doc.runs.map(\.text).joined()
        #expect(attr.string == expected)
    }

    // (b) .sourceOffset stamping tests removed with the attribute itself (INT-567):
    // source mapping now goes through SelectionSourceMapping, covered in
    // Tests/AwesoMuxCoreTests/Markdown/SelectionSourceMappingTests.swift.

    // MARK: - (c) markID stamping

    /// Runs inside <mark>…</mark> blocks paired with comment markers must carry .markID.
    @Test("marked runs carry .markID matching the comment ID")
    func markIDStamping() {
        // The AttributedMarkdownBuilder handles <mark>…</mark> + comment marker.
        let source = "<mark>annotated text</mark><!-- USER COMMENT 1: First note -->"
        let doc = AttributedMarkdownBuilder.build(source)

        // Verify the builder produced at least one run with a markID.
        let markedRuns = doc.runs.filter { $0.markID != nil }
        // If parsing produced no marked runs, skip the attr check.
        // (The test still exercises the attr builder with the plain doc.)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)

        var charOffset = 0
        for run in doc.runs {
            let nsRange = NSRange(charOffset..<(charOffset + run.text.utf16.count))
            // Empty runs occupy no character position; attribute(at:) would be
            // out of bounds. Skip them rather than masking the index with max(_,0).
            guard nsRange.length > 0 else { continue }
            let attrMarkID = attr.attribute(.markID, at: nsRange.location, effectiveRange: nil) as? String

            if let expectedID = run.markID {
                #expect(
                    attrMarkID == expectedID,
                    "run '\(run.text)' has markID=\(expectedID) but attr has \(String(describing: attrMarkID))")
            } else {
                #expect(
                    attrMarkID == nil,
                    "run '\(run.text)' has no markID but attr has \(String(describing: attrMarkID))")
            }
            charOffset += run.text.utf16.count
        }

        // Ensure attr builder didn't drop marked runs: if the builder found marks, the attr must too.
        if !markedRuns.isEmpty {
            var foundMarkID = false
            attr.enumerateAttribute(.markID, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
                if value != nil { foundMarkID = true }
            }
            #expect(foundMarkID, "document has marked runs but attr string has no .markID attributes")
        }
    }

    @Test("unmarked runs do not carry .markID")
    func unmarkedRunsHaveNoMarkID() {
        let source = "Plain paragraph with **bold** and _italic_."
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)

        attr.enumerateAttribute(.markID, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            #expect(value == nil, "expected no .markID in plain paragraph; found one at \(range)")
        }
    }

    // MARK: - (d) Adaptive text color (INT-562 dark-on-dark fix)

    /// Every non-link run must carry a `.foregroundColor` attribute when a text
    /// color is passed to the builder. This is the INT-562 fix: body text, headings,
    /// list bullets, list numbers, blockquote text, and inline code were previously
    /// rendered in a fixed system default (dark on dark terminals — invisible).
    @Test("every text run carries .foregroundColor when textColor is provided")
    func everyRunCarriesForegroundColor() {
        let source = "# Heading\n\n- bullet\n\n1. ordered\n\nPlain **bold** and `code`."
        let doc = AttributedMarkdownBuilder.build(source)
        // Use a near-white (dark terminal) text color.
        let darkBg = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.18, alpha: 1)
        let textColor = MarkdownAttributedStringBuilder.textColor(forTerminalBackground: darkBg)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: textColor)

        // Check every character position (skip link runs which use controlAccentColor,
        // a different foreground — they are still legible and intentional).
        let fullRange = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            #expect(
                value != nil,
                "missing .foregroundColor at range \(range): '\(attr.attributedSubstring(from: range).string)'"
            )
        }
    }

    /// For a dark terminal background, the chosen text color must have higher
    /// relative luminance than the background (i.e. the text is lighter than the bg).
    @Test("dark terminal background → text color luminance is higher than background luminance")
    func darkTerminalYieldsLegibleTextColor() {
        // Catppuccin Mocha base: #1E1E2E  (luminance ≈ 0.012)
        let darkBg = NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
        let textColor = MarkdownAttributedStringBuilder.textColor(forTerminalBackground: darkBg)

        // textColor must be lighter (higher luminance) than darkBg.
        let bgLum = relativeLuminance(darkBg)
        let textLum = relativeLuminance(textColor)

        #expect(
            textLum > bgLum,
            "text luminance \(textLum) must be > background luminance \(bgLum) for dark terminal")
    }

    /// Passing textColor must not alter the attributed string's plain text (1:1 invariant).
    @Test("textColor parameter does not alter the string content (1:1 invariant)")
    func textColorDoesNotChangeString() {
        let source = "# H1\n\nBody **bold** and `code`."
        let doc = AttributedMarkdownBuilder.build(source)
        let textColor = NSColor.white
        let attrWithColor = MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: textColor)
        let attrNoColor = MarkdownAttributedStringBuilder.attributedString(for: doc)

        #expect(
            attrWithColor.string == attrNoColor.string,
            "textColor must not change the attributed string's plain text content")
    }

    // MARK: - Document links

    @Test("relative markdown links resolve from the source document directory")
    func relativeMarkdownLinksResolveFromSourceDirectory() throws {
        let doc = AttributedMarkdownBuilder.build("See [spec](docs/spec.md).")
        let baseURL = URL(fileURLWithPath: "/tmp/awesomux-docs")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: baseURL
        )

        let link = try #require(linkAttribute(in: attr, for: "spec") as? URL)
        #expect(link.isFileURL)
        #expect(link.path == "/tmp/awesomux-docs/docs/spec.md")
    }

    @Test("relative markdown links without a source document directory stay plain text")
    func relativeMarkdownLinksNeedSourceDirectory() throws {
        let doc = AttributedMarkdownBuilder.build("See [spec](docs/spec.md).")
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)

        #expect(linkAttribute(in: attr, for: "spec") == nil)
    }

    @Test("relative markdown links with query stay plain text")
    func relativeMarkdownLinksWithQueryStayPlainText() throws {
        let doc = AttributedMarkdownBuilder.build("[query](docs/spec.md?raw=1) [anchor](docs/spec.md#section)")
        let baseURL = URL(fileURLWithPath: "/tmp/awesomux-docs")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: baseURL
        )

        #expect(linkAttribute(in: attr, for: "query") == nil)
    }

    @Test("relative markdown links with fragments still open the document")
    func relativeMarkdownLinksWithFragmentsOpenDocument() throws {
        let doc = AttributedMarkdownBuilder.build("[anchor](docs/spec.md#section)")
        let baseURL = URL(fileURLWithPath: "/tmp/awesomux-docs")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: baseURL
        )

        let link = try #require(linkAttribute(in: attr, for: "anchor") as? URL)
        #expect(link.isFileURL)
        #expect(link.path == "/tmp/awesomux-docs/docs/spec.md")
        #expect(link.fragment == "section")
    }

    @Test("bare relative markdown paths resolve from the source document directory")
    func bareRelativeMarkdownPathsResolveFromSourceDirectory() throws {
        let doc = AttributedMarkdownBuilder.build("Open docs/spec.md, then keep going.")
        let baseURL = URL(fileURLWithPath: "/tmp/awesomux-docs")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: baseURL
        )

        let link = try #require(linkAttribute(in: attr, for: "docs/spec.md") as? URL)
        #expect(link.isFileURL)
        #expect(link.path == "/tmp/awesomux-docs/docs/spec.md")
        #expect(linkAttribute(in: attr, for: ",") == nil)
    }

    @Test("bare relative markdown paths before sentence periods resolve without linking the period")
    func bareRelativeMarkdownPathsBeforeSentencePeriodsResolve() throws {
        let doc = AttributedMarkdownBuilder.build("Open docs/spec.md. Then keep going.")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp/awesomux-docs")
        )

        let link = try #require(linkAttribute(in: attr, for: "docs/spec.md") as? URL)
        #expect(link.path == "/tmp/awesomux-docs/docs/spec.md")

        let pathWithPeriodRange = (attr.string as NSString).range(of: "docs/spec.md.")
        let sentencePeriodLocation = pathWithPeriodRange.location + ("docs/spec.md" as NSString).length
        #expect(attr.attribute(.link, at: sentencePeriodLocation, effectiveRange: nil) == nil)
    }

    @Test("bare relative markdown paths do not match prefixes of longer extensions")
    func bareRelativeMarkdownPathsDoNotMatchLongerExtensionPrefixes() throws {
        let doc = AttributedMarkdownBuilder.build("Open docs/spec.md.txt.")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp/awesomux-docs")
        )

        #expect(linkAttribute(in: attr, for: "docs/spec.md") == nil)
    }

    @Test("bare relative markdown paths without a source document directory stay plain text")
    func bareRelativeMarkdownPathsNeedSourceDirectory() throws {
        let doc = AttributedMarkdownBuilder.build("Open docs/spec.md.")
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)

        #expect(linkAttribute(in: attr, for: "docs/spec.md") == nil)
    }

    @Test("bare relative markdown paths in verbatim runs stay plain text")
    func bareRelativeMarkdownPathsInVerbatimRunsStayPlainText() throws {
        let source = """
            ---
            path: docs/front-matter.md
            ---

            `docs/inline-code.md`

            ```sh
            cat docs/code-block.md
            ```
            """
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp/awesomux-docs")
        )

        #expect(linkAttribute(in: attr, for: "docs/front-matter.md") == nil)
        #expect(linkAttribute(in: attr, for: "docs/inline-code.md") == nil)
        #expect(linkAttribute(in: attr, for: "docs/code-block.md") == nil)
    }

    @Test("bare relative markdown paths cannot escape the source document directory")
    func bareRelativeMarkdownPathsCannotEscapeSourceDirectory() throws {
        let doc = AttributedMarkdownBuilder.build("Open ../secret.md.")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp/awesomux-docs/docs")
        )

        #expect(linkAttribute(in: attr, for: "../secret.md") == nil)
    }

    // MARK: - Table layout

    @Test("a row with an empty first cell keeps the table paragraph style")
    func emptyFirstCellRowKeepsTableStyle() throws {
        // TextKit conforms a paragraph to the style of its FIRST character; a row
        // opening with the synthetic \t separator (empty first cell) must still be
        // covered or the whole row falls back to default 28pt tab stops.
        let doc = AttributedMarkdownBuilder.build("| A | B |\n| - | - |\n|  | y |")
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)
        let ns = attr.string as NSString
        let y = ns.range(of: "y", options: .backwards)
        #expect(y.location != NSNotFound)
        let paragraph = ns.paragraphRange(for: y)
        let style = try #require(
            attr.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        #expect(!style.tabStops.isEmpty)
        #expect(style.firstLineHeadIndent == MarkdownAttributedStringBuilder.tableCellPadding)
    }

    @Test("inline code in a header cell renders bold like its siblings")
    func headerInlineCodeIsBold() throws {
        let doc = AttributedMarkdownBuilder.build("| `cmd` | Meaning |\n| - | - |\n| x | y |")
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc)
        let r = (attr.string as NSString).range(of: "cmd")
        let font = try #require(attr.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    // MARK: - Luminance helper (mirrors MarkdownAttributedStringBuilder's private impl)

    private func relativeLuminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linearize(_ v: CGFloat) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(srgb.redComponent)
            + 0.7152 * linearize(srgb.greenComponent)
            + 0.0722 * linearize(srgb.blueComponent)
    }

    private func linkAttribute(in attr: NSAttributedString, for text: String) -> Any? {
        let range = (attr.string as NSString).range(of: text)
        guard range.location != NSNotFound else {
            Issue.record("expected rendered text to contain \(text)")
            return nil
        }
        return attr.attribute(.link, at: range.location, effectiveRange: nil)
    }
}

@Suite("MarkdownTextView document link wiring")
@MainActor
struct MarkdownTextViewDocumentLinkWiringTests {
    @Test("MarkdownTextView passes its relative link base into attributed-string construction")
    func markdownTextViewPassesRelativeLinkBaseIntoAttributedStringConstruction() throws {
        let doc = AttributedMarkdownBuilder.build("See [spec](docs/spec.md).")
        let view = MarkdownTextView(
            doc: doc,
            selectedSourceSpan: .constant(nil),
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp/source-doc")
        )

        let attr = view.attributedString(for: doc)
        let range = (attr.string as NSString).range(of: "spec")
        let link = try #require(attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL)

        #expect(link.path == "/tmp/source-doc/docs/spec.md")
    }
}

// MARK: - Task 5: applyHighlights tests

/// These tests operate directly on `NSMutableAttributedString` — no view
/// instantiated, no layout manager required. They exercise the contract that
/// `applyHighlights` sets `.backgroundColor` on EXACTLY the ranges carrying
/// `.markID` and nowhere else, inserting ZERO characters into the string.
@Suite("MarkdownAttributedStringBuilder.applyHighlights")
struct ApplyHighlightsTests {

    // MARK: - Red → green

    @Test("applyHighlights sets .backgroundColor only on .markID ranges")
    func highlightedRangesMatchMarkIDRanges() {
        let source = "before <mark>marked text</mark><!-- USER COMMENT 1: note --> after"
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = NSMutableAttributedString(
            attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc)
        )

        let highlightColor = NSColor.systemYellow.withAlphaComponent(0.3)
        MarkdownAttributedStringBuilder.applyHighlights(attr, highlightColor: highlightColor)

        // Collect all ranges that carry .markID.
        var markIDRanges: [NSRange] = []
        attr.enumerateAttribute(.markID, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if value != nil { markIDRanges.append(range) }
        }

        // Collect all ranges that carry .backgroundColor.
        var backgroundRanges: [NSRange] = []
        attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if value != nil { backgroundRanges.append(range) }
        }

        // The union of backgroundRanges must equal the union of markIDRanges.
        let markUnion = markIDRanges.reduce(into: IndexSet()) { $0.insert(integersIn: $1.location..<($1.location + $1.length)) }
        let bgUnion = backgroundRanges.reduce(into: IndexSet()) { $0.insert(integersIn: $1.location..<($1.location + $1.length)) }

        #expect(!markIDRanges.isEmpty, "test doc must have at least one marked range")
        #expect(markUnion == bgUnion, "highlighted ranges must exactly match markID ranges (no more, no less)")
    }

    @Test("applyHighlights inserts zero characters — string unchanged")
    func noCharsInserted() {
        let source = "a <mark>b</mark><!-- USER COMMENT 1: n --> c"
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = NSMutableAttributedString(
            attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc)
        )
        let before = attr.string

        MarkdownAttributedStringBuilder.applyHighlights(attr, highlightColor: .systemYellow)

        // The 1:1 invariant: applyHighlights must not insert any characters.
        #expect(attr.string == before, "applyHighlights must not modify the string content")
        #expect(attr.length == before.utf16.count, "applyHighlights must not change the attributed string length")
    }

    @Test("applyHighlights sets no .backgroundColor on plain (non-marked) text")
    func noHighlightOnPlainText() {
        let source = "Hello **world** — no marks here."
        let doc = AttributedMarkdownBuilder.build(source)
        let attr = NSMutableAttributedString(
            attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc)
        )

        MarkdownAttributedStringBuilder.applyHighlights(attr, highlightColor: .systemYellow)

        attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            #expect(value == nil, "expected no .backgroundColor on plain text; found one at \(range)")
        }
    }

    @Test("re-applying clears stale highlights from a previous render")
    func reapplyClearsPrevious() {
        // First apply with a source that has a mark.
        let sourceWithMark = "x <mark>y</mark><!-- USER COMMENT 1: n --> z"
        let doc1 = AttributedMarkdownBuilder.build(sourceWithMark)
        let attr = NSMutableAttributedString(
            attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc1)
        )
        MarkdownAttributedStringBuilder.applyHighlights(attr, highlightColor: .systemYellow)

        // Verify it highlighted something.
        var firstPassBG = 0
        attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if value != nil { firstPassBG += 1 }
        }
        #expect(firstPassBG > 0, "first pass must set some highlights")

        // Now remove all .markID attributes from the string (simulating a doc reload
        // where the mark was removed) and re-apply.
        attr.removeAttribute(.markID, range: NSRange(location: 0, length: attr.length))
        MarkdownAttributedStringBuilder.applyHighlights(attr, highlightColor: .systemYellow)

        var secondPassBG = 0
        attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if value != nil { secondPassBG += 1 }
        }
        // After clearing markID, re-apply must leave no highlights.
        #expect(secondPassBG == 0, "re-apply after removing .markID must clear all highlights")
    }
}

// MARK: - Bigfoot: CommentBadgeOverlay pill geometry (INT-562)

/// The pill is a DRAWN decoration placed after the trailing edge of a mark's last
/// glyph. `pillRect(afterTrailingRect:)` is the pure geometry — given the last
/// glyph's rect (in text-view/overlay space) it returns where the `•••` pill draws.
/// These tests pin the trailing-edge anchoring and vertical centring without a live
/// view tree (the screen→view conversion is the only part that needs a window, and
/// that is exercised by the human re-smoke).
@Suite("CommentBadgeOverlay pill geometry")
@MainActor
struct CommentBadgePillGeometryTests {

    @Test("annotation accessibility label omits a missing ordinal")
    func accessibilityLabelWithoutOrdinal() {
        #expect(CommentBadgeOverlay.pillAccessibilityLabel(displayNumber: nil, isAddPill: false) == "Comment")
        #expect(CommentBadgeOverlay.pillAccessibilityLabel(displayNumber: nil, isAddPill: true) == "Add comment")
        #expect(CommentBadgeOverlay.pillAccessibilityLabel(displayNumber: 2, isAddPill: false) == "Comment 2")
    }

    @Test("disabled pill accessibility press does not claim success")
    func disabledAccessibilityPressDoesNotClaimSuccess() {
        let element = PillAccessibilityElement()
        var didPress = false
        element.onPress = { didPress = true }
        element.setAccessibilityEnabled(false)

        #expect(element.accessibilityPerformPress() == false)
        #expect(didPress == false)
    }

    @Test("pill sits immediately after the trailing edge of the glyph rect")
    func pillIsAfterTrailingEdge() {
        let trailing = NSRect(x: 100, y: 40, width: 8, height: 16)
        let pill = CommentBadgeOverlay.pillRect(afterTrailingRect: trailing)
        // Pill's left edge must be to the RIGHT of the glyph's trailing edge — never
        // at line-end and never before the text.
        #expect(
            pill.minX > trailing.maxX,
            "pill left edge \(pill.minX) must be right of trailing edge \(trailing.maxX)")
    }

    @Test("pill is vertically centred on the glyph rect (flipped-space safe)")
    func pillIsVerticallyCentred() {
        let trailing = NSRect(x: 100, y: 40, width: 8, height: 16)
        let pill = CommentBadgeOverlay.pillRect(afterTrailingRect: trailing)
        // midY must match within a sub-pixel — the pill rides the line, not the
        // pane top/bottom. This is the invariant that breaks if the overlay's flip
        // doesn't match the text view's.
        #expect(
            abs(pill.midY - trailing.midY) < 0.01,
            "pill midY \(pill.midY) must equal trailing midY \(trailing.midY)")
    }

    @Test("pill rect has positive size")
    func pillHasPositiveSize() {
        let pill = CommentBadgeOverlay.pillRect(afterTrailingRect: NSRect(x: 0, y: 0, width: 10, height: 16))
        #expect(pill.width > 0)
        #expect(pill.height > 0)
    }

    @Test("higher line (smaller Y in flipped space) → pill placed higher, not at bottom")
    func pillTracksLineHeightOrder() {
        // In the text view's flipped space, a span near the document TOP has a
        // smaller Y than one further down. The pill must preserve that ordering;
        // the original bug inverted it (top text → bottom pill).
        let topGlyph = NSRect(x: 50, y: 20, width: 8, height: 16)
        let bottomGlyph = NSRect(x: 50, y: 900, width: 8, height: 16)
        let topPill = CommentBadgeOverlay.pillRect(afterTrailingRect: topGlyph)
        let bottomPill = CommentBadgeOverlay.pillRect(afterTrailingRect: bottomGlyph)
        #expect(
            topPill.midY < bottomPill.midY,
            "a top-of-document mark's pill must have a smaller Y than a lower mark's")
    }

    @Test("glyphTrailingRectInTextView returns nil for an empty range")
    func trailingRectNilForEmptyRange() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let rect = CommentBadgeOverlay.glyphTrailingRectInTextView(
            lastCharOf: NSRange(location: 0, length: 0), in: tv
        )
        #expect(rect == nil, "empty selection/range must yield no trailing rect (no add pill)")
    }

    @Test("screen rect conversion returns text-view coordinates")
    func convertsScreenRectToTextViewSpace() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let tv = NSTextView(frame: NSRect(x: 40, y: 30, width: 200, height: 120))
        window.contentView?.addSubview(tv)

        let expectedInTextView = NSRect(x: 24, y: 36, width: 12, height: 18)
        let screenRect = window.convertToScreen(tv.convert(expectedInTextView, to: nil))

        let converted = CommentBadgeOverlay.textViewRect(fromScreenRect: screenRect, in: tv)

        #expect(converted == expectedInTextView)
    }
}

// MARK: - Scroll anchor restore (INT-567)

/// Headless TextKit 2 check that restoring to a mid-paragraph byte lands on the
/// wrapped LINE containing it, not the paragraph's top. A TextKit 2 layout
/// fragment spans the whole paragraph, so this is exactly the case where
/// fragment-level scrolling silently degrades to "snap to paragraph start".
@Suite("Scroll anchor restore (INT-567)")
@MainActor
struct ScrollAnchorRestoreTests {

    @Test("restore to a mid-paragraph byte scrolls below the paragraph top")
    func midParagraphRestoreScrollsToWrappedLine() {
        // One long paragraph → one RenderedRun → one layout fragment, many lines.
        let source = (1...300).map { "word\($0)" }.joined(separator: " ")
        let doc = AttributedMarkdownBuilder.build(source)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        // Headless: width tracking only engages via live window layout, so pin the
        // container width explicitly and size the frame manually below — otherwise
        // layout happens at unbounded width (one unwrapped line) and NSTextView's
        // own vertical sizing pins the frame too short for the clip view to scroll.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        let coordinator = MarkdownTextViewCoordinator(selectedSourceSpan: .constant(nil))
        coordinator.textView = textView
        coordinator.lastDoc = doc
        let attr = NSMutableAttributedString(
            attributedString: MarkdownAttributedStringBuilder.attributedString(for: doc)
        )
        coordinator.currentAttr = attr
        textView.textStorage?.setAttributedString(attr)
        guard let layoutManager = textView.textLayoutManager else {
            Issue.record("expected a TextKit 2 text view")
            return
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // Size the document view to its laid-out height so the clip view can scroll.
        let usage = layoutManager.usageBoundsForTextContainer
        textView.setFrameSize(NSSize(width: 260, height: usage.height + 40))
        #expect(usage.height > 400, "test premise: the paragraph must wrap into many lines")

        coordinator.scrollToSourceOffset(source.utf8.count / 2)

        // The paragraph's FIRST line restores to inset(20) - 4 = 16. A mid-paragraph
        // byte must land on a later wrapped line, i.e. scroll well past that.
        #expect(
            scrollView.contentView.bounds.origin.y > 100,
            "mid-paragraph restore must scroll to the containing wrapped line, not the paragraph top")
    }
}
