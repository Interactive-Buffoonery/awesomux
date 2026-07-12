import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite
struct PaneTitleCommitResolutionTests {
    @Test
    func nonEmptyDifferentTextRenames() {
        let result = PaneTitleBarView.resolveCommit(
            input: "My Backend", current: "claude", isUserEdited: false
        )
        #expect(result == .rename("My Backend"))
    }

    @Test
    func blankInputResets() {
        let result = PaneTitleBarView.resolveCommit(
            input: "   ", current: "My Backend", isUserEdited: true
        )
        #expect(result == .reset)
    }

    @Test
    func unchangedFrozenTitleIsNoChange() {
        let result = PaneTitleBarView.resolveCommit(
            input: "My Backend", current: "My Backend", isUserEdited: true
        )
        #expect(result == .noChange)
    }

    @Test
    func sameTextButNotYetFrozenRenamesToPin() {
        // Committing the live title verbatim should still pin it (freeze).
        let result = PaneTitleBarView.resolveCommit(
            input: "claude", current: "claude", isUserEdited: false
        )
        #expect(result == .rename("claude"))
    }
}
