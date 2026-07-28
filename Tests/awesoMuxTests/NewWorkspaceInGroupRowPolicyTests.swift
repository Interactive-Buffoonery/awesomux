import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("NewWorkspaceInGroupRowPolicy")
struct NewWorkspaceInGroupRowPolicyTests {
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

    /// An empty group has no tiles, so the list delegate's resolver returns
    /// nil and deliberately holds the drop — the row must own a delegate or
    /// nothing in the group accepts. A populated group's list delegate
    /// already resolves anything below the last tile to append, which is
    /// exactly where the row sits; a second delegate there would fight the
    /// first for the same drop and flip-flop the insertion feedback.
    @Test("only an empty group's row owns its own drop delegate")
    func onlyEmptyGroupOwnsDropDelegate() {
        #expect(NewWorkspaceInGroupRowPolicy.ownsDropDelegate(isGroupEmpty: true))
        #expect(!NewWorkspaceInGroupRowPolicy.ownsDropDelegate(isGroupEmpty: false))
    }
}
