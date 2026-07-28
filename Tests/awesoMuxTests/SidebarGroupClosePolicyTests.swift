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
        totalGroupCount: Int = 2,
        isGroupCollapsed: Bool = false,
        isDragActive: Bool = false
    ) -> Bool {
        SidebarGroupClosePolicy.showsCloseButton(
            isHeaderHovered: isHeaderHovered,
            displayMode: displayMode,
            isFiltering: isFiltering,
            hasResolvedGroupIndex: hasResolvedGroupIndex,
            isGroupEmpty: isGroupEmpty,
            totalGroupCount: totalGroupCount,
            isGroupCollapsed: isGroupCollapsed,
            isDragActive: isDragActive
        )
    }

    @Test("hovered non-empty group shows the close X")
    func hoveredNonEmptyGroupShowsCloseButton() {
        #expect(Self.shows())
    }

    @Test("sole empty group hides the X — the store refuses to remove the last group")
    func soleEmptyGroupHidesCloseButton() {
        #expect(!Self.shows(isGroupEmpty: true, totalGroupCount: 1))
    }

    @Test("sole non-empty group shows the X — closing empties it, which is meaningful")
    func soleNonEmptyGroupShowsCloseButton() {
        #expect(Self.shows(totalGroupCount: 1))
    }

    @Test("no hover, no X")
    func unhoveredHidesCloseButton() {
        #expect(!Self.shows(isHeaderHovered: false))
    }

    /// The whole point of dropping the `+ new workspace` row's duplicate X:
    /// an expanded empty group's body already shows it is empty, so the count
    /// badge says nothing and the X rests in that slot without needing hover.
    /// Also the surviving half of INT-770 — an empty group among others is
    /// closable at all, unlike the sole empty group below.
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

    /// The sole empty group cannot be closed at all, so the resting clause
    /// must not conjure a dead X — the count badge stays as the slot's only
    /// occupant, which is also the only thing left to render there.
    @Test("sole empty group rests nothing — the close would be a dead control")
    func soleExpandedEmptyGroupRestsNothing() {
        #expect(!Self.shows(isHeaderHovered: false, isGroupEmpty: true, totalGroupCount: 1))
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

    @Test("defensive zero group count also counts as sole — X hidden")
    func zeroGroupCountHidesCloseButton() {
        #expect(!Self.shows(isGroupEmpty: true, totalGroupCount: 0))
    }

    @Test("dead-control clause: only the sole (or fewer) empty group")
    func closeIsDeadControlTruthTable() {
        #expect(SidebarGroupClosePolicy.closeIsDeadControl(isGroupEmpty: true, totalGroupCount: 1))
        #expect(SidebarGroupClosePolicy.closeIsDeadControl(isGroupEmpty: true, totalGroupCount: 0))
        #expect(!SidebarGroupClosePolicy.closeIsDeadControl(isGroupEmpty: true, totalGroupCount: 2))
        #expect(!SidebarGroupClosePolicy.closeIsDeadControl(isGroupEmpty: false, totalGroupCount: 1))
    }
}
