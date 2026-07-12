import CoreGraphics
import Testing
@testable import AwesoMuxCore

@Suite("Sidebar width policy")
struct SidebarWidthPolicyTests {
    @Test("width constants match the sidebar modes")
    func widthConstants() {
        #expect(SidebarWidthPolicy.expandedWidth == 296)
        #expect(SidebarWidthPolicy.collapsedWidth == 60)
        #expect(SidebarWidthPolicy.defaultWidth == SidebarWidthPolicy.expandedWidth)
    }

    @Test("mode is two-way for free-drag: full rows or rail")
    func modeDerivation() {
        let t = SidebarWidthPolicy.railThreshold
        #expect(SidebarWidthPolicy.mode(for: 80) == .collapsed)
        #expect(SidebarWidthPolicy.mode(for: t - 1) == .collapsed) // rail zone, no textless middle
        #expect(SidebarWidthPolicy.mode(for: t + 100) == .expanded)
    }

    @Test("toggle collapses and restores the last non-collapsed width")
    func toggleRestore() {
        let restore = SidebarWidthPolicy.railThreshold + 46 // a free width above the rail
        #expect(
            SidebarWidthPolicy.toggleWidth(
                currentWidth: SidebarWidthPolicy.expandedWidth,
                lastNonCollapsedWidth: restore
            ) == SidebarWidthPolicy.collapsedWidth
        )
        #expect(
            SidebarWidthPolicy.toggleWidth(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                lastNonCollapsedWidth: restore
            ) == restore
        )
    }

    @Test("toggle restore falls back to expanded when the persisted restore width is collapsed or missing")
    func toggleRestoreFallback() {
        #expect(
            SidebarWidthPolicy.toggleWidth(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                lastNonCollapsedWidth: nil
            ) == SidebarWidthPolicy.expandedWidth
        )
        #expect(
            SidebarWidthPolicy.toggleWidth(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                lastNonCollapsedWidth: SidebarWidthPolicy.collapsedWidth
            ) == SidebarWidthPolicy.expandedWidth
        )
    }

    @Test("last non-collapsed width preserves the exact free width, ignores collapsed current widths")
    func lastNonCollapsedUpdate() {
        // Free-drag: a non-collapsed current width is preserved exactly, NOT snapped
        // to a canonical — so the next ⌘\ restores what the user dragged to (INT-535).
        let free = SidebarWidthPolicy.railThreshold + 60
        #expect(
            SidebarWidthPolicy.updatedLastNonCollapsedWidth(
                currentWidth: free,
                previousLastNonCollapsedWidth: SidebarWidthPolicy.expandedWidth
            ) == free
        )
        #expect(
            SidebarWidthPolicy.updatedLastNonCollapsedWidth(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                previousLastNonCollapsedWidth: SidebarWidthPolicy.expandedWidth
            ) == SidebarWidthPolicy.expandedWidth
        )
    }

    // MARK: - Free-drag band model (INT-535)

    @Test("mode is rail below the threshold, full rows above (two modes only)")
    func bandLayoutThresholds() {
        let t = SidebarWidthPolicy.railThreshold
        #expect(SidebarWidthPolicy.mode(for: 60) == .collapsed)
        #expect(SidebarWidthPolicy.mode(for: t - 1) == .collapsed)    // rail zone
        #expect(SidebarWidthPolicy.mode(for: t) == .expanded)         // full rows resume
        #expect(SidebarWidthPolicy.mode(for: t + 50) == .expanded)
        // Free width beyond the old canonical cap still reads as expanded.
        #expect(SidebarWidthPolicy.mode(for: 800) == .expanded)
    }

    @Test("rail-zone widths settle to the tight collapsed width")
    func railZoneSnaps() {
        let t = SidebarWidthPolicy.railThreshold
        #expect(SidebarWidthPolicy.committedWidth(for: 100) == SidebarWidthPolicy.collapsedWidth)
        #expect(SidebarWidthPolicy.committedWidth(for: t - 1) == SidebarWidthPolicy.collapsedWidth)
        #expect(SidebarWidthPolicy.committedWidth(for: t) == t) // first full-rows width preserved
    }

    @Test("committed width preserves the exact dragged width above the rail threshold")
    func committedWidthPreservesArbitrary() {
        let t = SidebarWidthPolicy.railThreshold
        #expect(SidebarWidthPolicy.committedWidth(for: t + 37) == t + 37)
        #expect(SidebarWidthPolicy.committedWidth(for: 600) == 600) // no upper clamp here
    }

    @Test("committed width clamps to the collapsed floor")
    func committedWidthClampsFloor() {
        #expect(SidebarWidthPolicy.committedWidth(for: 10) == SidebarWidthPolicy.collapsedWidth)
        #expect(SidebarWidthPolicy.committedWidth(for: -5) == SidebarWidthPolicy.collapsedWidth)
        #expect(SidebarWidthPolicy.committedWidth(for: .infinity) == SidebarWidthPolicy.defaultWidth)
    }

    @Test("live constrained width respects dynamic max and snaps the rail zone")
    func constrainedLiveWidth() {
        #expect(SidebarWidthPolicy.constrainedLiveWidth(for: 600, maxWidth: 240) == 60)
        #expect(SidebarWidthPolicy.constrainedLiveWidth(for: 600, maxWidth: 500) == 500)
        #expect(SidebarWidthPolicy.constrainedLiveWidth(for: 245, maxWidth: 1000) == 60)
        #expect(SidebarWidthPolicy.constrainedLiveWidth(for: .infinity, maxWidth: 1000) == 60)
    }

    @Test("restore-on-grow fires only for a window-forced rail, not a user-chosen one")
    func shouldRestoreExpanded() {
        // At the rail, window now wide enough, user didn't choose it -> restore.
        #expect(SidebarWidthPolicy.shouldRestoreExpanded(
            currentWidth: 60, maxWidth: 900, userChoseRail: false) == true)
        // At the rail but the user chose it (⌘\ / drag) -> leave it collapsed.
        #expect(SidebarWidthPolicy.shouldRestoreExpanded(
            currentWidth: 60, maxWidth: 900, userChoseRail: true) == false)
        // Window still too narrow for any expanded width -> don't restore yet.
        #expect(SidebarWidthPolicy.shouldRestoreExpanded(
            currentWidth: 60, maxWidth: 240, userChoseRail: false) == false)
        // Already expanded -> nothing to restore.
        #expect(SidebarWidthPolicy.shouldRestoreExpanded(
            currentWidth: 296, maxWidth: 900, userChoseRail: false) == false)
    }

    @Test("toggle restores the exact free width, not a snapped canonical")
    func toggleRestoresFreeWidth() {
        // The INT-535 correction: ⌘\ from a collapsed sidebar must return to the
        // user's exact free width, not snap to a canonical.
        let free = SidebarWidthPolicy.railThreshold + 60
        #expect(SidebarWidthPolicy.normalizedLastNonCollapsedWidth(free) == free)
        #expect(
            SidebarWidthPolicy.toggleWidth(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                lastNonCollapsedWidth: free
            ) == free
        )
    }
}
