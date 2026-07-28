import AwesoMuxCore
import Testing
@testable import awesoMux

struct SidebarGroupClosePolicyTests {
    @Test("group close controls share one action label")
    func groupCloseControlsShareActionLabel() {
        #expect(SidebarGroupClosePolicy.actionLabel == "Close Group")
    }

    /// All gates open: hovered, expanded, unfiltered, resolved, non-empty.
    private static func shows(
        isHeaderHovered: Bool = true,
        displayMode: SidebarWidthMode = .expanded,
        isFiltering: Bool = false,
        hasResolvedGroupIndex: Bool = true,
        isGroupEmpty: Bool = false,
        isGroupCollapsed: Bool = false,
        isDragActive: Bool = false
    ) -> Bool {
        SidebarGroupClosePolicy.showsCloseButton(
            isHeaderHovered: isHeaderHovered,
            displayMode: displayMode,
            isFiltering: isFiltering,
            hasResolvedGroupIndex: hasResolvedGroupIndex,
            isGroupEmpty: isGroupEmpty,
            isGroupCollapsed: isGroupCollapsed,
            isDragActive: isDragActive
        )
    }

    @Test("hovered non-empty group shows the close X")
    func hoveredNonEmptyGroupShowsCloseButton() {
        #expect(Self.shows())
    }

    @Test("no hover, no X")
    func unhoveredHidesCloseButton() {
        #expect(!Self.shows(isHeaderHovered: false))
    }

    /// The whole point of dropping the `+ new workspace` row's duplicate X:
    /// an expanded empty group's body already shows it is empty, so the count
    /// badge says nothing and the X rests in that slot without needing hover.
    /// Group count no longer enters into it — the store accepts removing the
    /// last group, so there is no dead-control case left to carve out.
    @Test("expanded empty group rests its X visible without hover")
    func expandedEmptyGroupRestsCloseButtonVisible() {
        #expect(Self.shows(isHeaderHovered: false, isGroupEmpty: true))
    }

    /// The resting clause is subordinate to every other gate, and the
    /// collapsed rail is the one that has nowhere to put an X at all — it
    /// renders no count badge, so there is no slot to morph.
    @Test("collapsed rail rests nothing for an empty group either")
    func collapsedRailRestsNothingForEmptyGroup() {
        #expect(!Self.shows(isHeaderHovered: false, displayMode: .collapsed, isGroupEmpty: true))
    }

    /// A drag is aiming at drop targets — an empty group's whole body is one —
    /// so the resting X steps out of the flight path until the drag ends. The
    /// hover path is covered separately: `SidebarGroupHeaderRow` zeroes its
    /// hover flag when a drag starts, because tracking-area exits stop being
    /// delivered mid-drag.
    @Test("an in-flight drag suppresses the resting X")
    func dragSuppressesRestingCloseButton() {
        #expect(!Self.shows(isHeaderHovered: false, isGroupEmpty: true, isDragActive: true))
    }

    /// Collapsed, the body is hidden, so the count is the ONLY signal of what
    /// is inside — it keeps the slot and the X goes back to a hover reveal.
    @Test("collapsed empty group keeps the count and hides the X until hover")
    func collapsedEmptyGroupKeepsCountUntilHover() {
        #expect(!Self.shows(isHeaderHovered: false, isGroupEmpty: true, isGroupCollapsed: true))
        #expect(Self.shows(isHeaderHovered: true, isGroupEmpty: true, isGroupCollapsed: true))
    }

    /// A populated group always shows its count, expanded or not — the resting
    /// X is strictly an empty-group affordance.
    @Test("an expanded populated group still needs hover")
    func expandedPopulatedGroupStillNeedsHover() {
        #expect(!Self.shows(isHeaderHovered: false, isGroupEmpty: false))
    }

    /// The carve-out this replaces: the sole empty group used to rest nothing,
    /// because `removeGroup` refused the last group and the X would have been
    /// a dead control. It now rests like any other empty group. Group count is
    /// no longer an input at all, so this asserts the *absence* of the old
    /// distinction rather than inverting it.
    @Test("group count does not change what an empty group rests")
    func groupCountDoesNotAffectRestingCloseButton() {
        #expect(Self.shows(isHeaderHovered: false, isGroupEmpty: true))
        #expect(Self.shows(isGroupEmpty: false))
    }

    @Test("collapsed rail renders no badge, so no X")
    func collapsedRailHidesCloseButton() {
        #expect(!Self.shows(displayMode: .collapsed))
    }

    @Test("filtering suppresses the X — header reflects only the matched subset")
    func filteringHidesCloseButton() {
        #expect(!Self.shows(isFiltering: true))
        #expect(!Self.shows(isFiltering: true, isGroupEmpty: true))
    }

    @Test("unresolved group index suppresses the X")
    func unresolvedGroupIndexHidesCloseButton() {
        #expect(!Self.shows(hasResolvedGroupIndex: false))
        #expect(!Self.shows(hasResolvedGroupIndex: false, isGroupEmpty: true))
    }

}
