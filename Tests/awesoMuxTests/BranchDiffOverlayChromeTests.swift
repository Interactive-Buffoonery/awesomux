import AppKit
import AwesoMuxCore
import Testing

@testable import awesoMux

@Suite("Branch diff overlay chrome")
struct BranchDiffOverlayChromeTests {

    /// Headless TextKit 2 text view with an unbounded container and layout
    /// forced, so fragment geometry exists without a window.
    @MainActor
    private func makeOverlay(
        _ source: String, collapsed: Set<String> = [], width: CGFloat = 400,
        proseWrapWidth: CGFloat? = nil
    ) -> (CommentBadgeOverlay, NSTextView, NSAttributedString, BranchDiffSectionIndex) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let doc = AttributedMarkdownBuilder.build(source)
        let index = BranchDiffSectionIndex(document: doc)
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc, textColor: .white, sectionIndex: index)
        textView.textStorage?.setAttributedString(attr)
        if let proseWrapWidth, let storage = textView.textStorage {
            // The wrap width is stamped by the coordinator, not the builder, so a
            // geometry assertion has to run the same pass the live view runs.
            _ = MarkdownTextViewCoordinator(selectedSourceSpan: .constant(nil))
                .applyProseWrapWidth(to: storage, in: textView, clipWidth: proseWrapWidth)
        }
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.sectionCounts = Dictionary(
            uniqueKeysWithValues: index.sections.map { ($0.key, ($0.added, $0.removed)) })
        overlay.sectionTitles = Dictionary(
            uniqueKeysWithValues: index.sections.map { ($0.key, $0.title) })
        overlay.foldableKeys = Set(index.sections.filter(\.isFoldable).map(\.key))
        overlay.collapsedSections = collapsed
        // Cached remounts render with annotations non-interactive (no snapshot);
        // folding must not depend on that gate.
        overlay.annotationsInteractive = false
        overlay.updateBadges(attr: attr, textView: textView)
        return (overlay, textView, attr, index)
    }

    private let twoFiles = "## a.swift\n\n```diff\n@@ -1 +1 @@\n+x\n-y\n```\n\n## b.swift\n\n```diff\n+z\n```\n"

    @Test("resolving section chrome for a 200-section document stays under one frame")
    @MainActor
    func chromeGeometryIsCheapEnoughForLayout() {
        let source = (0..<200).map { "## f\($0).swift\n\n```diff\n+a\n-b\n```\n" }.joined()
        let (overlay, textView, attr, _) = makeOverlay(source)
        #expect(overlay.sectionChrome.count == 200)
        // A fresh instance, not `attr`: makeOverlay already ran updateBadges
        // with that one, so re-passing it would measure a heading-range cache
        // hit and leave the per-run enumerate outside the measurement.
        let fresh = NSAttributedString(attributedString: attr)
        let elapsed = ContinuousClock().measure {
            overlay.updateBadges(attr: fresh, textView: textView)
        }
        #expect(elapsed < .milliseconds(16), "updateBadges took \(elapsed)")
    }

    @Test("one chrome entry per section, in document order, with counts and fold state")
    @MainActor
    func chromePerSection() {
        let (overlay, _, _, _) = makeOverlay(twoFiles, collapsed: ["b.swift"])
        #expect(overlay.sectionChrome.map(\.key) == ["a.swift", "b.swift"])
        #expect(overlay.sectionChrome[0].added == 1 && overlay.sectionChrome[0].removed == 1)
        #expect(overlay.sectionChrome[0].collapsed == false)
        #expect(overlay.sectionChrome[1].collapsed == true)
        #expect(overlay.sectionChrome[0].rowRect.minY < overlay.sectionChrome[1].rowRect.minY)
        #expect(overlay.sectionChrome.allSatisfy { $0.rowRect.minX == 0 && $0.rowRect.width == 400 })
    }

    @Test("the heading row hit-tests to the overlay and a click toggles that key; body rows pass through")
    @MainActor
    func headingRowClickToggles() {
        let (overlay, textView, _, _) = makeOverlay(twoFiles)
        var toggled: [String] = []
        overlay.onSectionToggled = { toggled.append($0) }
        let row = overlay.sectionChrome[1].rowRect
        let inside = NSPoint(x: row.midX, y: row.midY)
        #expect(overlay.hitTest(textView.convert(inside, from: overlay)) === overlay)
        overlay.simulateClick(at: inside)
        #expect(toggled == ["b.swift"])
        let between = NSPoint(x: 10, y: overlay.sectionChrome[0].rowRect.maxY + 30)
        #expect(overlay.hitTest(textView.convert(between, from: overlay)) == nil)
    }

    @Test("a fence-less section keeps its chrome entry but is inert: no click target, no fold state")
    @MainActor
    func fenceLessSectionIsNotFoldable() throws {
        let (overlay, textView, _, _) = makeOverlay(
            "## renamed.txt\n\n## b.swift\n\n```diff\n+z\n```\n")
        #expect(overlay.sectionChrome.map(\.key) == ["renamed.txt", "b.swift"])
        #expect(overlay.sectionChrome[0].foldable == false)
        #expect(overlay.sectionChrome[1].foldable == true)

        var toggled: [String] = []
        overlay.onSectionToggled = { toggled.append($0) }
        let row = overlay.sectionChrome[0].rowRect
        let inside = NSPoint(x: row.midX, y: row.midY)
        #expect(overlay.hitTest(textView.convert(inside, from: overlay)) == nil)
        overlay.simulateClick(at: inside)
        #expect(toggled.isEmpty)

        let elements = overlay.sectionAccessibilityChildrenForTesting()
        #expect(elements.count == 2)
        #expect(elements[0].accessibilityLabel() == "renamed.txt, 0 added, 0 removed")
        #expect(elements[0].accessibilityValue() == nil)
        #expect(elements[0].accessibilityRole() == .staticText)
        #expect(elements[0].accessibilityPerformPress() == false)
        #expect(toggled.isEmpty)
        #expect(elements[1].accessibilityRole() == .button)
        #expect(elements[1].accessibilityValue() as? String == "expanded")
    }

    @Test("the counts badge stays inside the visible x range after a horizontal scroll")
    @MainActor
    func countsBadgeFollowsHorizontalScroll() throws {
        let (overlay, textView, _, _) = makeOverlay(twoFiles)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scrollView.documentView = textView
        // The clip clamps a scroll to the document's frame, so widen the text
        // view: without room to scroll, and without scrolling far enough that
        // the pre-fix x (measured from the clip WIDTH, ignoring its origin)
        // lands left of the visible range, the assertion passes on the bug.
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        scrollView.contentView.scroll(to: NSPoint(x: 300, y: 0))
        let clip = scrollView.contentView.bounds
        #expect(clip.origin.x == 300)
        let badges = overlay.sectionBadgeRects
        #expect(badges.count == 2)
        for badge in badges {
            #expect(
                badge.rect.minX >= clip.minX && badge.rect.maxX <= clip.maxX,
                "badge \(badge.key) at \(badge.rect) is outside visible x range \(clip.minX)…\(clip.maxX)"
            )
        }
    }

    @Test("a section-only document reflows its heading rows on a plain relayout")
    @MainActor
    func sectionOnlyDocumentRelayoutsOnResize() {
        let (overlay, _, _, _) = makeOverlay(twoFiles)
        #expect(overlay.sectionChrome.allSatisfy { $0.rowRect.width == 400 })
        var changes = 0
        overlay.onSectionChromeChanged = { changes += 1 }
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: overlay.frame.height)
        overlay.layout()
        #expect(overlay.sectionChrome.count == 2)
        #expect(overlay.sectionChrome.allSatisfy { $0.rowRect.width == 600 })
        #expect(changes == 1)
    }

    @Test("counts badge text uses a real minus and always shows both numbers")
    func badgeText() {
        #expect(CommentBadgeOverlay.countsBadgeText(added: 38, removed: 2) == "+38 \u{2212}2")
        #expect(CommentBadgeOverlay.countsBadgeText(added: 0, removed: 0) == "+0 \u{2212}0")
    }

    @Test("accessibility children include one enabled button per section with label and value, even with annotations off")
    @MainActor
    func accessibilityButtons() throws {
        let (overlay, _, _, _) = makeOverlay(twoFiles, collapsed: ["a.swift"])
        let elements = overlay.sectionAccessibilityChildrenForTesting()
        #expect(elements.count == 2)
        #expect(elements[0].accessibilityLabel() == "a.swift, 1 added, 1 removed")
        #expect(elements[0].accessibilityValue() as? String == "collapsed")
        #expect(elements[1].accessibilityValue() as? String == "expanded")
        #expect(elements[0].accessibilityRole() == .button)
        #expect(elements[0].isAccessibilityEnabled())
        var pressed: String?
        overlay.onSectionToggled = { pressed = $0 }
        _ = elements[1].accessibilityPerformPress()
        #expect(pressed == "b.swift")
    }

    @Test("hunk rows report a rule rect at the row top")
    @MainActor
    func hunkRule() throws {
        let (_, textView, _, _) = makeOverlay(twoFiles)
        let rules = CommentBadgeOverlay.diffHunkRuleRows(
            intersecting: NSRect(x: 0, y: 0, width: 400, height: 4000), in: textView, width: 400)
        #expect(rules.count == 1)
        #expect(rules[0].height == 1 && rules[0].width == 400)
        let tints = CommentBadgeOverlay.diffTintRows(
            intersecting: NSRect(x: 0, y: 0, width: 400, height: 4000), in: textView, width: 400)
        #expect(tints.contains { abs($0.rect.minY - rules[0].minY) < 0.5 })
    }

    @Test("a long path heading wraps before the counts badge instead of running under it")
    @MainActor
    func longHeadingWrapsBeforeTheCountsBadge() throws {
        let path = (0..<20).map { "segment\($0)" }.joined(separator: "/")
        #expect(path.count >= 120)
        let (overlay, textView, _, _) = makeOverlay(
            "## \(path)\n\n```diff\n+x\n```\n", width: 300, proseWrapWidth: 300)
        let heading = try #require(overlay.sectionChrome.first)
        let limit =
            300 - textView.textContainerInset.width
            - MarkdownAttributedStringBuilder.sectionHeadingTrailingReserve + 1
        #expect(heading.headingRect.maxX <= limit, "headingRect \(heading.headingRect) exceeds \(limit)")
    }

    @Test("chrome changes notify the sticky-header observer only when the computed value moves")
    @MainActor
    func chromeChangeNotifies() {
        let (overlay, textView, attr, _) = makeOverlay(twoFiles)
        var changes = 0
        overlay.onSectionChromeChanged = { changes += 1 }
        overlay.updateBadges(attr: attr, textView: textView)
        #expect(changes == 0)
        overlay.collapsedSections = ["a.swift"]
        overlay.updateBadges(attr: attr, textView: textView)
        #expect(changes == 1)
    }
}
