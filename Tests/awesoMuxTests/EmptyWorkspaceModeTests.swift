import Testing

@testable import awesoMux

/// Closing the last workspace group is allowed because the place it lands the
/// user is a designed empty state, not a blank pane. That claim had no test —
/// these pin it.
@Suite("Empty workspace mode")
struct EmptyWorkspaceModeTests {

    /// The destination after closing the last group. If this ever returned
    /// `.noSelection`, the user would get "pick a workspace" with nothing to
    /// pick from and no way forward.
    @Test("an empty tree is the first-launch state")
    func emptyTreeIsFirstLaunch() {
        #expect(
            EmptyWorkspaceMode.resolve(hasRecoveryWarning: false, hasAnyGroup: false)
                == .firstLaunch)
    }

    /// The distinction this exists to draw: a returning user sitting between
    /// workspaces must not be greeted as new (INT-166).
    @Test("groups but no selection is a returning user, not a new one")
    func groupsWithoutSelectionIsNoSelection() {
        #expect(
            EmptyWorkspaceMode.resolve(hasRecoveryWarning: false, hasAnyGroup: true)
                == .noSelection)
    }

    /// Recovery outranks both — a user whose session failed to restore needs
    /// to hear that before anything else, empty tree or not.
    @Test("a recovery warning wins over both other states")
    func recoveryWarningWins() {
        #expect(
            EmptyWorkspaceMode.resolve(hasRecoveryWarning: true, hasAnyGroup: false) == .recovered)
        #expect(
            EmptyWorkspaceMode.resolve(hasRecoveryWarning: true, hasAnyGroup: true) == .recovered)
    }
}
