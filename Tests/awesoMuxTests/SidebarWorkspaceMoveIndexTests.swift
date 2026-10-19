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

    @Test(arguments: [
        ("a", 1, ["a", "b"], ["pinned", "a", "b"], 2),
        ("c", 0, ["a", "b", "c"], ["pinned", "a", "needs", "b", "c"], 1),
        ("a", 1, ["a", "b", "c"], ["pinned", "a", "needs", "b", "c"], 3),
        ("a", 1, ["a", "b"], ["a", "needs", "b", "pinned"], 2),
        ("a", 0, ["a", "b"], ["a", "pinned", "b"], 0),
        ("a", 0, ["a"], ["pinned", "a", "needs"], 1),
        ("incoming", 1, ["a", "b"], ["pinned", "a", "needs", "b"], 3),
        ("incoming", 0, [], ["pinned", "needs"], 2),
    ])
    func workspaceMoveIndex(source: String, target: Int, visible: [String], stored: [String], expected: Int) {
        #expect(
            SidebarInsertionResolver.storedWorkspaceTargetIndex(
                sourceID: source, visibleTargetIndex: target,
                visibleIDs: visible, storedIDs: stored) == expected)
    }

}
