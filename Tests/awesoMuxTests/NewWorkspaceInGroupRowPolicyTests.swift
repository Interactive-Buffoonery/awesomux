import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("NewWorkspaceInGroupRowPolicy")
struct NewWorkspaceInGroupRowPolicyTests {
    /// The row is the empty group's only always-visible removal path, so it
    /// keeps the X there. A populated group already has the header's hover X —
    /// two pointer paths to the same destructive action is one too many.
    @Test("only an empty group shows the row's remove button")
    func onlyEmptyGroupShowsRemoveButton() {
        #expect(
            NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: true,
                canRemoveGroup: true
            )
        )
        #expect(
            !NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: false,
                canRemoveGroup: true
            )
        )
        // An empty group that cannot be removed (the store refuses to remove
        // the last group) still gets no dead control.
        #expect(
            !NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: true,
                canRemoveGroup: false
            )
        )
    }

    /// The dashed border is the empty group's "there's nothing here" cue. Once
    /// there are tiles above it, one dashed box per group reads as noise, so the
    /// row rests borderless and lights up only under an active drag.
    @Test("only an empty group shows a resting border")
    func onlyEmptyGroupShowsRestingBorder() {
        #expect(NewWorkspaceInGroupRowPolicy.showsRestingBorder(isGroupEmpty: true))
        #expect(!NewWorkspaceInGroupRowPolicy.showsRestingBorder(isGroupEmpty: false))
    }

    /// The row sits at the BOTTOM of a populated group, so its drop has to
    /// append — index 0 would contradict where the row visually is. An empty
    /// group has no tiles, so 0 and append are the same position; 0 is used
    /// there because it matches the existing shipped behavior.
    @Test("drop index matches where the row sits")
    func dropIndexMatchesRowPosition() {
        #expect(NewWorkspaceInGroupRowPolicy.dropInsertionIndex(isGroupEmpty: true) == 0)
        #expect(
            NewWorkspaceInGroupRowPolicy.dropInsertionIndex(isGroupEmpty: false)
                == SessionStore.appendIndex
        )
    }
}
