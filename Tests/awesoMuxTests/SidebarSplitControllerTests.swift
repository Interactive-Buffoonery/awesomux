import CoreGraphics
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite("SidebarSplitController clamp")
@MainActor
struct SidebarSplitControllerTests {
    @Test("rail-zone widths snap while expanded widths are preserved")
    func preservesInRange() {
        #expect(
            SidebarSplitController.clampedWidth(187, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
        #expect(
            SidebarSplitController.clampedWidth(245, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
        #expect(SidebarSplitController.clampedWidth(287, maxWidth: 1000) == 287)
    }

    @Test("below-floor clamps up to the collapsed floor")
    func clampsFloor() {
        #expect(
            SidebarSplitController.clampedWidth(10, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("above the dynamic max clamps down to it")
    func clampsDynamicCeiling() {
        // The ceiling models windowWidth - terminalMinimum.
        #expect(SidebarSplitController.clampedWidth(900, maxWidth: 500) == 500)
    }

    @Test("non-finite falls back to the floor")
    func nonFiniteFallsBack() {
        #expect(
            SidebarSplitController.clampedWidth(.infinity, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("inverted range (max below floor, narrow window) still returns the floor")
    func invertedRangeReturnsFloor() {
        #expect(
            SidebarSplitController.clampedWidth(700, maxWidth: 40)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("restoring a wide stored width onto a narrow window snaps to the rail")
    func restoreWideWidthOntoNarrowWindow() {
        // Minimum window (720) with the 480 terminal floor leaves a 240 sidebar
        // max. A stored 600 (dragged on a wider window earlier) must snap to the
        // tight rail because the dynamic max sits in the no-wide-rail zone.
        let maxAtMinWindow = ContentView.minimumWindowWidth - ContentView.terminalMinimumWidth
        #expect(maxAtMinWindow == 240)
        #expect(
            SidebarSplitController.clampedWidth(600, maxWidth: maxAtMinWindow)
                == SidebarWidthPolicy.collapsedWidth
        )
    }
}

@Suite("SidebarSplitController reclamp action")
@MainActor
struct SidebarSplitControllerReclampTests {
    typealias Action = SidebarSplitController.ReclampAction

    // Sidebar sitting at the rail, window now has room, user didn't choose the rail.
    @Test("restore-on-grow fires when not dragging")
    func restoreWhenNotDragging() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: false,
                isDraggingDivider: false
            ) == .restoreExpanded(296)
        )
    }

    // The regression: dragging from expanded toward the rail must NOT spring back.
    @Test("restore-on-grow is suppressed during a divider drag")
    func noRestoreWhileDragging() {
        let action = SidebarSplitController.reclampAction(
            currentWidth: 120, // below the rail threshold, mid-drag
            maxWidth: 1000,
            lastExpandedWidth: 296,
            userChoseRail: false,
            isDraggingDivider: true
        )
        // 120 is in the no-wide-rail dead zone, so the live clamp tightens it to the
        // rail — but it must NOT be a restore-to-expanded.
        #expect(action == .clamp(SidebarWidthPolicy.collapsedWidth))
        if case .restoreExpanded = action {
            Issue.record("restore-on-grow fired mid-drag — the #206 regression")
        }
    }

    // A window shrink concurrent with a drag must still pull the sidebar in so the
    // terminal can't be stranded below its minimum.
    @Test("terminal-starvation clamp still fires during a drag")
    func clampFiresWhileDragging() {
        // Wide sidebar, but the window shrank so maxWidth is now 240 (rail zone).
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: 600,
                maxWidth: 240,
                lastExpandedWidth: 600,
                userChoseRail: false,
                isDraggingDivider: true
            ) == .clamp(SidebarWidthPolicy.collapsedWidth)
        )
    }

    // A deliberate rail (⌘\ or drag-to-rail) must not auto-expand on a window grow.
    @Test("user-chosen rail is left alone on grow")
    func userChosenRailNotRestored() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: true,
                isDraggingDivider: false
            ) == .none
        )
    }

    // A settled expanded width that needs no correction is a no-op.
    @Test("settled width within bounds is a no-op")
    func settledWidthIsNoOp() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: 296,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: false,
                isDraggingDivider: false
            ) == .none
        )
    }
}
