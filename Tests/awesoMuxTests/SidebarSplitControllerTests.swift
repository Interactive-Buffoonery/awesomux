import CoreGraphics
import AppKit
import AwesoMuxConfig
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite("SidebarSplitController clamp", .serialized)
@MainActor
struct SidebarSplitControllerTests {
    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeController(width: CGFloat = 1_200) -> (SidebarSplitController, NSViewController, NSViewController) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, sidebar, detail)
    }

    private func hostInFixedWindow(_ controller: SidebarSplitController) -> NSWindow {
        controller.loadViewIfNeeded()
        let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        let contentView = NSView(frame: frame)
        window.contentView = contentView
        controller.view.frame = contentView.bounds
        contentView.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    @Test("sidebar geometry mirrors across the pane extent")
    func mirroredGeometry() {
        let extent: CGFloat = 1_199
        #expect(SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .left) == 300)
        #expect(SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .right) == 899)
        #expect(SidebarSplitController.sidebarWidth(forDividerCoordinate: 300, paneExtent: extent, position: .left) == 300)
        #expect(SidebarSplitController.sidebarWidth(forDividerCoordinate: 899, paneExtent: extent, position: .right) == 300)
    }

    @Test("sidebar geometry stays finite for invalid pane extents")
    func invalidGeometry() {
        for extent in [CGFloat.zero, -10, .infinity, .nan] {
            let coordinate = SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .right)
            let width = SidebarSplitController.sidebarWidth(forDividerCoordinate: 300, paneExtent: extent, position: .right)
            #expect(coordinate.isFinite)
            #expect(width.isFinite)
            #expect(coordinate >= 0)
            #expect(width >= 0)
        }
    }

    @Test("changing sides preserves semantic width and child identities")
    func changingSides() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        let sidebarView = sidebar.view
        let detailView = detail.view

        controller.setSidebarPosition(.right)

        #expect(sidebar.view === sidebarView)
        #expect(detail.view === detailView)
        #expect(controller.view.subviews.first === detailView)
        #expect(abs(sidebarView.frame.width - 300) < 1)
    }

    @Test("changing sides preserves a child first responder")
    func changingSidesPreservesFirstResponder() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        let window = NSWindow(contentViewController: controller)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(sentinel))

        controller.setSidebarPosition(.right)

        #expect(window.firstResponder === sentinel)
    }

    @Test("right sidebar uses semantic width for max and resize reclamp")
    func rightSideMaxAndReclamp() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarPosition(.right)
        controller.setSidebarWidth(600)
        #expect(controller.maxSidebarWidth == 719)

        controller.view.frame.size.width = 720
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)
    }

    @Test("hide suppresses callbacks and reveal restores width")
    func hideAndReveal() {
        let sidebar = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        var live: [CGFloat] = []
        var commits: [CGFloat] = []
        controller.onLiveWidthChange = { live.append($0) }
        controller.onCommitWidth = { commits.append($0) }

        controller.setSidebarHidden(true)
        #expect(sidebar.view.frame.width == 0)
        #expect(live.isEmpty)
        #expect(commits.isEmpty)

        controller.setSidebarHidden(false)
        #expect(abs(sidebar.view.frame.width - 300) < 1)
    }

    @Test("hiding hands sidebar focus off before applying hidden geometry")
    func hidingHandsSidebarFocusOff() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let detail = NSViewController()
        let destination = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(destination)
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        let window = hostInFixedWindow(controller)
        #expect(window.makeFirstResponder(sentinel))
        var handoffCount = 0
        var widthDuringHandoff: CGFloat?
        controller.onSidebarFocusHandoff = {
            handoffCount += 1
            widthDuringHandoff = sidebar.view.frame.width
            return window.makeFirstResponder(destination)
        }

        controller.setSidebarHidden(true)

        #expect(handoffCount == 1)
        #expect((widthDuringHandoff ?? 0) > 0)
        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === destination)
        #expect(window.firstResponder !== sentinel)
    }

    @Test("hiding leaves a detail first responder alone")
    func hidingLeavesDetailFocusAlone() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        let window = hostInFixedWindow(controller)
        #expect(window.makeFirstResponder(sentinel))
        var handoffCount = 0
        controller.onSidebarFocusHandoff = {
            handoffCount += 1
            return false
        }

        controller.setSidebarHidden(true)

        #expect(handoffCount == 0)
        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === sentinel)
    }

    @Test("failed sidebar focus handoff clears first responder")
    func failedSidebarFocusHandoffClearsFirstResponder() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        let window = hostInFixedWindow(controller)
        #expect(window.makeFirstResponder(sentinel))
        controller.onSidebarFocusHandoff = { false }

        controller.setSidebarHidden(true)

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder !== sentinel)
    }

    @Test("layout while hidden stays hidden without restoring expanded width")
    func hiddenResizeDoesNotRestore() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.view.frame.size.width = 1_600
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == 0)
    }

    @Test("persisted hidden state survives the first live window layout")
    func persistedHiddenColdLaunch() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let sidebar = NSViewController()
            let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
            controller.setSidebarPosition(position)
            controller.setSidebarHidden(true)

            let window = NSWindow(contentViewController: controller)
            window.setContentSize(CGSize(width: 1_200, height: 800))
            window.makeKeyAndOrderFront(nil)
            controller.view.layoutSubtreeIfNeeded()

            #expect(window.isVisible)
            #expect(sidebar.view.frame.width == 0)
            window.orderOut(nil)
        }
    }

    @Test("hidden drag completion cannot commit zero width")
    func hiddenDragDoesNotCommit() {
        let (controller, _, _) = makeController()
        var commits: [CGFloat] = []
        controller.onCommitWidth = { commits.append($0) }
        controller.setSidebarHidden(true)

        controller.simulateDividerDragCompletionForTesting()

        #expect(commits.isEmpty)
    }

    @Test("setting width while hidden records reveal width without showing")
    func hiddenWidthRequest() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setSidebarWidth(420)
        #expect(sidebar.view.frame.width == 0)
        controller.setSidebarHidden(false)

        #expect(abs(sidebar.view.frame.width - 420) < 1)
    }

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
            currentWidth: 120,  // below the rail threshold, mid-drag
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
