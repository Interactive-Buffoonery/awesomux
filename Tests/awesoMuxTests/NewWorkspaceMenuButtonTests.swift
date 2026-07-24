import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
struct NewWorkspaceMenuButtonTests {
    @Test("equatable gate ignores closures but tracks size, fill, and group list")
    func equatableGateTracksMeaningfulInputsOnly() {
        let groupID = UUID()
        let base = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )

        // Same values, freshly-allocated closures — this is exactly what
        // every unrelated SidebarView re-render produces. Must compare
        // equal, or the `.equatable()` gate at the call site never
        // actually suppresses anything.
        let sameInputsNewClosures = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base == sameInputsNewClosures)

        let differentSize = NewWorkspaceMenuButton(
            size: 32,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentSize)

        let differentFill = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .black,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentFill)

        let differentGroupName = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Beta")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentGroupName)

        let differentGroupCount = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha"), (id: UUID(), name: "Gamma")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentGroupCount)
    }

    @Test("equatable gate holds for the real production fill color")
    func equatableGateHoldsForProductionFill() {
        // The trivial static colors above (.clear/.black) don't prove the
        // gate survives the actual call site's dynamic, opacity-derived
        // fill (SidebarView.swift's collapsedSearchHeader passes
        // Color.aw.surface.elevated.opacity(0.6)) — confirm two
        // independently-constructed views with that real color still
        // compare equal, the property the whole gate depends on.
        let productionFill = Color.aw.surface.elevated.opacity(0.6)
        let groupID = UUID()
        let first = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: productionFill,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        let second = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: productionFill,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(first == second)
    }
}
