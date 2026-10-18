import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Sidebar visible workspace move indices")
struct SidebarWorkspaceMoveIndexTests {
    @Test @MainActor func removingHiddenPrefixBeforeAMoveUsesCurrentStoredOrder() throws {
        let pinned = TerminalSession(title: "pinned", workingDirectory: "~")
        let a = TerminalSession(title: "a", workingDirectory: "~")
        let b = TerminalSession(title: "b", workingDirectory: "~")
        let c = TerminalSession(title: "c", workingDirectory: "~")
        let group = SessionGroup(name: "work", sessions: [pinned, a, b, c])
        let store = SessionStore(groups: [group])
        store.closeSession(id: pinned.id, captureRecentlyClosed: false)
        let index = try #require(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: a.id, visibleTargetIndex: 1,
                visibleIDs: [a.id, b.id, c.id], storedIDs: store.groups[0].sessions.map(\.id)))
        store.moveSession(id: a.id, toGroupID: group.id, atIndex: index)
        #expect(store.groups[0].sessions.map(\.id) == [b.id, a.id, c.id])
    }

    @Test func pinnedPrefixDoesNotTurnADownwardMoveIntoANoOp() {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "a", visibleTargetIndex: 1,
                visibleIDs: ["a", "b"], storedIDs: ["pinned", "a", "b"]
            ) == 2)
    }

    @Test func hiddenAttentionRowsDoNotShiftUpwardOrMiddleDestinations() {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "c", visibleTargetIndex: 0,
                visibleIDs: ["a", "b", "c"], storedIDs: ["pinned", "a", "needs", "b", "c"]
            ) == 1)
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "a", visibleTargetIndex: 1,
                visibleIDs: ["a", "b", "c"], storedIDs: ["pinned", "a", "needs", "b", "c"]
            ) == 3)
    }

    @Test func lastVisibleDestinationStaysBeforeTrailingHiddenRows() {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "a", visibleTargetIndex: 1,
                visibleIDs: ["a", "b"], storedIDs: ["a", "needs", "b", "pinned"]
            ) == 2)
    }

    @Test func unchangedVisiblePositionDoesNotReorderHiddenSiblings() {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "a", visibleTargetIndex: 0,
                visibleIDs: ["a", "b"], storedIDs: ["a", "pinned", "b"]
            ) == 0)
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "a", visibleTargetIndex: 0,
                visibleIDs: ["a"], storedIDs: ["pinned", "a", "needs"]
            ) == 1)
    }

    @Test func incomingWorkspaceUsesVisibleAnchorsAndEmptyProjectionAppends() {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "incoming", visibleTargetIndex: 1,
                visibleIDs: ["a", "b"], storedIDs: ["pinned", "a", "needs", "b"]
            ) == 3)
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: "incoming", visibleTargetIndex: 0,
                visibleIDs: [String](), storedIDs: ["pinned", "needs"]
            ) == 2)
    }
}
