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

    @Test("a heading exactly at the top edge is not pinned (it is already visible in place)")
    func headingAtTopIsInPlace() {
        // Pinning a heading whose own row is fully visible would draw it twice.
        #expect(
            BranchDiffStickyHeaderView.placement(visibleTop: 100, rows: rows, headerHeight: 30)?.index == 0)
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 99, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the view starts hidden, shows with a model, and is not a separate accessibility element")
    @MainActor
    func viewModelAndAccessibility() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        #expect(view.isHidden)  // set in init, not only in model.didSet (didSet never fires for the initial nil)
        view.model = .init(key: "a.swift", title: "a.swift", added: 3, removed: 1, collapsed: false)
        #expect(!view.isHidden)
        #expect(view.isAccessibilityElement() == false)
        var activated: String?
        view.onActivate = { activated = $0 }
        view.simulateClick()
        #expect(activated == "a.swift")
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
}
