import AppKit
import Testing

@testable import awesoMux

@Suite("Branch diff sticky header placement")
struct BranchDiffStickyHeaderTests {
    // rows: heading row rects in document space (minY, maxY), document order
    private let rows: [(minY: CGFloat, maxY: CGFloat)] = [(100, 124), (500, 524), (900, 924)]

    @Test("nothing pins while the first heading is still below the top edge")
    func nothingAboveTop() {
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 50, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the last heading above the top edge pins with no push")
    func pinsCurrentSection() throws {
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 300, rows: rows, headerHeight: 30)
                == .init(index: 0, pushOffset: 0))
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 700, rows: rows, headerHeight: 30)
                == .init(index: 1, pushOffset: 0))
    }

    @Test("the next heading pushes the pinned header up as it approaches, and takes over once it passes")
    func pushesOut() throws {
        // next heading at 500; visible top 480 → 20pt of room for a 30pt header → pushed up 10
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 480, rows: rows, headerHeight: 30)
                == .init(index: 0, pushOffset: -10))
        // heading exactly at the top edge → it is now the pinned one
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 500, rows: rows, headerHeight: 30)
                == .init(index: 1, pushOffset: 0))
    }

    @Test("a heading exactly at the top edge counts as pinned (the drawn header covers it exactly)")
    func headingAtTopEdgeCountsAsPinned() {
        // minY == visibleTop pins: the header sits on top of the in-place
        // heading, so nothing reads twice. One point above it, nothing pins.
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 100, rows: rows, headerHeight: 30)?.index == 0)
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 99, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the counts label is wide enough for both numbers") @MainActor
    func countsLabelFitsBothNumbers() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        view.model = .init(key: "a", title: "a", added: 170, removed: 5, collapsed: false, foldable: true)
        view.layoutSubtreeIfNeeded()
        #expect(view.countsFrameForTesting.width >= view.countsRequiredWidthForTesting)
        #expect(view.countsFrameForTesting.maxX <= 400)
    }

    @Test("the view starts hidden, shows with a model, and is not a separate accessibility element")
    @MainActor
    func viewModelAndAccessibility() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        #expect(view.isHidden)  // set in init, not only in model.didSet (didSet never fires for the initial nil)
        view.model = .init(
            key: "a.swift", title: "a.swift", added: 3, removed: 1, collapsed: false,
            foldable: true)
        #expect(!view.isHidden)
        #expect(view.isAccessibilityElement() == false)
        var activated: String?
        view.onActivate = { activated = $0 }
        view.simulateClick()
        #expect(activated == "a.swift")
    }

    @Test("a fence-less section's pinned header drops the chevron but still activates")
    @MainActor
    func nonFoldableHeaderHidesTheChevron() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        view.model = .init(
            key: "renamed.txt", title: "renamed.txt", added: 0, removed: 0, collapsed: false,
            foldable: false)
        #expect(view.isChevronHidden)
        var activated: String?
        view.onActivate = { activated = $0 }
        view.simulateClick()
        #expect(activated == "renamed.txt")

        // The foldable sibling still draws one, so the hide is the model's doing.
        view.model = .init(
            key: "b.swift", title: "b.swift", added: 1, removed: 0, collapsed: false,
            foldable: true)
        #expect(!view.isChevronHidden)
    }

    @Test("the last heading pins with no next row to push it out")
    func lastSectionHasNoPush() {
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 5_000, rows: rows, headerHeight: 30)
                == .init(index: 2, pushOffset: 0))
    }

    @Test("no rows means nothing pins")
    func emptyRows() {
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 500, rows: [], headerHeight: 30) == nil)
    }

    @Test("a wrapped heading taller than the bar pins only once the bar would cover it")
    func tallHeadingPinsWhenCovered() {
        // A two-line heading: 52pt tall against a 30pt bar. Pinning at minY drew
        // it twice — once in place, once in the bar (review).
        let tall: [(minY: CGFloat, maxY: CGFloat)] = [(100, 152), (500, 524)]
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 100, rows: tall, headerHeight: 30) == nil)
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 121, rows: tall, headerHeight: 30) == nil)
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 122, rows: tall, headerHeight: 30)
                == .init(index: 0, pushOffset: 0))
        // The push-out uses the NEXT row's pin point too, so the hand-off is
        // continuous: full push exactly where that row takes over.
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 480, rows: tall, headerHeight: 30)
                == .init(index: 0, pushOffset: -10))
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 500, rows: tall, headerHeight: 30)
                == .init(index: 1, pushOffset: 0))
    }

    @Test("the whole bar takes the click, including the chevron its image view sits under")
    @MainActor
    func hitTestCoversTheChevron() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        container.addSubview(view)
        // Hidden (no model) it must stay transparent to clicks.
        #expect(view.hitTest(NSPoint(x: 30, y: 15)) == nil)

        view.model = .init(
            key: "a.swift", title: "a.swift", added: 3, removed: 1, collapsed: false,
            foldable: true)
        view.layoutSubtreeIfNeeded()
        let chevron = view.chevronFrameForTesting
        #expect(chevron.width > 0 && chevron.height > 0)
        let onChevron = view.convert(NSPoint(x: chevron.midX, y: chevron.midY), to: container)
        #expect(view.hitTest(onChevron) === view)
        // And a point outside the bar still falls through.
        #expect(view.hitTest(NSPoint(x: 150, y: 100)) == nil)
    }
}
