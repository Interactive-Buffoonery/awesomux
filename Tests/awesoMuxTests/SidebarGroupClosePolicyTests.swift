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
        totalGroupCount: Int = 2
    ) -> Bool {
        SidebarGroupClosePolicy.showsCloseButton(
            isHeaderHovered: isHeaderHovered,
            displayMode: displayMode,
            isFiltering: isFiltering,
            hasResolvedGroupIndex: hasResolvedGroupIndex,
            isGroupEmpty: isGroupEmpty,
            totalGroupCount: totalGroupCount
        )
    }

    @Test("hovered non-empty group shows the close X")
    func hoveredNonEmptyGroupShowsCloseButton() {
        #expect(Self.shows())
    }

    @Test("empty group among others shows the close X on hover (INT-770)")
    func emptyGroupAmongOthersShowsCloseButton() {
        #expect(Self.shows(isGroupEmpty: true, totalGroupCount: 2))
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
