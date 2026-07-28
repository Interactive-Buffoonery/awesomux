import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore undo")
struct SessionStoreUndoTests {
    @Test("color change undoes and redoes with its action name")
    func colorUndoRedo() {
        let group = SessionGroup(name: "Group", sessions: [])
        let (store, undoManager) = makeStore(groups: [group])

        performGesture(using: undoManager) {
            #expect(store.setGroupColor(id: group.id, color: .pink))
        }

        #expect(store.groups[0].color == .pink)
        #expect(undoManager.undoActionName == "Set Group Color")
        undoManager.undo()
        #expect(store.groups[0].color == nil)
        #expect(undoManager.redoActionName == "Set Group Color")
        undoManager.redo()
        #expect(store.groups[0].color == .pink)
    }

    @Test("rename undoes and redoes with its action name")
    func renameUndoRedo() {
        let group = SessionGroup(name: "Original", sessions: [])
        let (store, undoManager) = makeStore(groups: [group])

        performGesture(using: undoManager) {
            #expect(store.renameGroup(id: group.id, to: "  Renamed  "))
        }

        #expect(store.groups[0].name == "Renamed")
        #expect(undoManager.undoActionName == "Rename Group")
        undoManager.undo()
        #expect(store.groups[0].name == "Original")
        #expect(undoManager.redoActionName == "Rename Group")
        undoManager.redo()
        #expect(store.groups[0].name == "Renamed")
    }

    @Test("group reorder undoes and redoes clamped destinations")
    func groupMoveUndoRedo() {
        let groups = ["One", "Two", "Three"].map { SessionGroup(name: $0, sessions: []) }
        let (store, undoManager) = makeStore(groups: groups)

        performGesture(using: undoManager) {
            store.moveGroup(from: 0, to: 99)
        }

        #expect(store.groups.map(\.name) == ["Two", "Three", "One"])
        #expect(undoManager.undoActionName == "Move Group")
        undoManager.undo()
        #expect(store.groups.map(\.name) == ["One", "Two", "Three"])
        #expect(undoManager.redoActionName == "Move Group")
        undoManager.redo()
        #expect(store.groups.map(\.name) == ["Two", "Three", "One"])
    }

    @Test("cross-group workspace move restores its original group and index")
    func crossGroupMoveUndo() {
        let first = makeSession("First")
        let moved = makeSession("Moved")
        let destination = makeSession("Destination")
        let sourceGroup = SessionGroup(name: "Source", sessions: [first, moved])
        let destinationGroup = SessionGroup(name: "Destination", sessions: [destination])
        let (store, undoManager) = makeStore(groups: [sourceGroup, destinationGroup])

        performGesture(using: undoManager) {
            store.moveSession(id: moved.id, toGroupID: destinationGroup.id, atIndex: 0)
        }

        #expect(store.groups[1].sessions.map(\.id) == [moved.id, destination.id])
        #expect(undoManager.undoActionName == "Move Workspace")
        undoManager.undo()
        #expect(store.groups[0].sessions.map(\.id) == [first.id, moved.id])
        #expect(undoManager.redoActionName == "Move Workspace")
    }

    @Test("same-group workspace move undoes and redoes")
    func sameGroupMoveUndoRedo() {
        let sessions = [makeSession("One"), makeSession("Two"), makeSession("Three")]
        let group = SessionGroup(name: "Group", sessions: sessions)
        let (store, undoManager) = makeStore(groups: [group])

        performGesture(using: undoManager) {
            store.moveSession(id: sessions[0].id, toGroupID: group.id, atIndex: 2)
        }

        #expect(store.groups[0].sessions.map(\.id) == [sessions[1].id, sessions[2].id, sessions[0].id])
        undoManager.undo()
        #expect(store.groups[0].sessions.map(\.id) == sessions.map(\.id))
        undoManager.redo()
        #expect(store.groups[0].sessions.map(\.id) == [sessions[1].id, sessions[2].id, sessions[0].id])
    }

    /// Closing an EMPTY group takes neither confirmation branch — no live
    /// sessions to warn about — so a mis-clicked close is otherwise silent and
    /// final. Undo must bring back the whole group value, not just its name:
    /// the color and the SSH creation default are what make it the group the
    /// user built, and `SessionGroup` carries both.
    @Test("closing an empty group undoes and redoes, restoring its whole value and slot")
    func removeGroupUndoRedo() {
        let target = SessionGroup(
            name: "Target",
            color: .pink,
            remote: RemoteTarget(user: "ed", host: "example.test"),
            sessions: []
        )
        let (store, undoManager) = makeStore(groups: [
            SessionGroup(name: "Before", sessions: []),
            target,
            SessionGroup(name: "After", sessions: []),
        ])

        performGesture(using: undoManager) {
            #expect(store.removeGroup(id: target.id))
        }

        #expect(store.groups.map(\.name) == ["Before", "After"])
        #expect(undoManager.undoActionName == "Close Group")
        undoManager.undo()

        #expect(store.groups.map(\.name) == ["Before", "Target", "After"])
        #expect(store.groups[1].id == target.id)
        #expect(store.groups[1].color == .pink)
        #expect(store.groups[1].remote == target.remote)

        #expect(undoManager.redoActionName == "Close Group")
        undoManager.redo()
        #expect(store.groups.map(\.name) == ["Before", "After"])
    }

    /// Closing down to an empty tree and walking all the way back out.
    ///
    /// The redo direction is the reason this exists. `restoreRemovedGroup`
    /// registers its inverse as `removeGroup`, so redoing the *last* group's
    /// close re-enters the guard this change relaxed. While the reducer
    /// refused the last group that redo was silently a no-op — undo would
    /// bring the group back and redo could not take it away again — and no
    /// test could reach it, because the close it inverts was itself refused.
    @Test("closing every group undoes and redoes through the empty tree")
    func closingEveryGroupUndoesAndRedoesThroughEmpty() {
        let first = SessionGroup(name: "First", sessions: [])
        let second = SessionGroup(name: "Second", sessions: [])
        let (store, undoManager) = makeStore(groups: [first, second])

        performGesture(using: undoManager) { #expect(store.removeGroup(id: first.id)) }
        performGesture(using: undoManager) { #expect(store.removeGroup(id: second.id)) }
        #expect(store.groups.isEmpty)

        undoManager.undo()
        #expect(store.groups.map(\.name) == ["Second"])
        undoManager.undo()
        #expect(store.groups.map(\.name) == ["First", "Second"])

        undoManager.redo()
        #expect(store.groups.map(\.name) == ["Second"], "redo must remove the first group again")
        undoManager.redo()
        #expect(store.groups.isEmpty, "redo must be able to empty the tree again")
    }

    /// The reducer refuses non-empty groups and unknown ids. A refused
    /// removal changed nothing, so it must not leave an inverse behind that
    /// would resurrect a group on the next ⌘Z.
    @Test("refused removals do not register undo")
    func refusedRemovalsDoNotRegisterUndo() {
        let session = makeSession("Only")
        let populated = SessionGroup(name: "Populated", sessions: [session])
        let (store, undoManager) = makeStore(groups: [populated])

        #expect(!store.removeGroup(id: populated.id))
        #expect(!store.removeGroup(id: UUID()))

        #expect(!undoManager.canUndo)
    }

    @Test("multiple gestures undo in reverse order")
    func multipleGesturesUndoInOrder() {
        let group = SessionGroup(name: "Original", sessions: [])
        let (store, undoManager) = makeStore(groups: [group])

        performGesture(using: undoManager) {
            store.renameGroup(id: group.id, to: "Renamed")
        }
        performGesture(using: undoManager) {
            store.setGroupColor(id: group.id, color: .blue)
        }

        undoManager.undo()
        #expect(store.groups[0].name == "Renamed")
        #expect(store.groups[0].color == nil)
        undoManager.undo()
        #expect(store.groups[0].name == "Original")
    }

    @Test("same-value writes do not register undo")
    func sameValueWritesDoNotRegisterUndo() {
        let group = SessionGroup(name: "Group", color: .teal, sessions: [])
        let (store, undoManager) = makeStore(groups: [group])

        #expect(store.renameGroup(id: group.id, to: "Group"))
        #expect(store.setGroupColor(id: group.id, color: .teal))

        #expect(!undoManager.canUndo)
    }

    @Test("rejected and same-position moves do not register undo")
    func rejectedMovesDoNotRegisterUndo() {
        let session = makeSession("Only")
        let group = SessionGroup(name: "Group", sessions: [session])
        let (store, undoManager) = makeStore(groups: [group])

        store.moveGroup(from: 0, to: 0)
        store.moveGroup(from: 99, to: 0)
        store.moveSession(id: session.id, toGroupID: group.id, atIndex: 0)
        store.moveSession(id: UUID(), toGroupID: group.id, atIndex: 0)

        #expect(!undoManager.canUndo)
    }

    @Test("stale inverse is refused without creating redo")
    func staleInverseDoesNotCreateRedo() {
        let target = SessionGroup(name: "Target", sessions: [])
        let survivor = SessionGroup(name: "Survivor", sessions: [])
        let (store, undoManager) = makeStore(groups: [target, survivor])

        performGesture(using: undoManager) {
            store.renameGroup(id: target.id, to: "Renamed")
        }
        // Removed with registration off so the rename's inverse is the top of
        // the stack: this test is about an inverse whose subject is gone, not
        // about the removal's own inverse (`removeGroupUndoRedo` owns that).
        undoManager.disableUndoRegistration()
        #expect(store.removeGroup(id: target.id))
        undoManager.enableUndoRegistration()

        undoManager.undo()

        #expect(!undoManager.canRedo)
        #expect(store.groups.map(\.id) == [survivor.id])
    }

    @Test("group move undo tracks the moved group by ID across structure changes")
    func groupMoveUndoTracksGroupByID() {
        let groups = ["One", "Two", "Three"].map { SessionGroup(name: $0, sessions: []) }
        let (store, undoManager) = makeStore(groups: groups)

        performGesture(using: undoManager) {
            store.moveGroup(from: 0, to: 2)
        }
        #expect(store.groups.map(\.name) == ["Two", "Three", "One"])

        // Removing a group shifts every index below it. Undo must still
        // restore "One" (tracked by ID), not whatever group now sits at the
        // captured post-move index. Registration is off for the removal so the
        // move's inverse stays the top of the stack — the structural change is
        // the point here, not the removal's own undo.
        undoManager.disableUndoRegistration()
        #expect(store.removeGroup(id: store.groups[0].id))
        undoManager.enableUndoRegistration()
        #expect(store.groups.map(\.name) == ["Three", "One"])

        undoManager.undo()
        #expect(store.groups.map(\.name) == ["One", "Three"])
    }

    @Test("replaceState clears registered undo history")
    func replaceStateClearsUndoHistory() {
        let group = SessionGroup(name: "Original", sessions: [makeSession("Session")])
        let (store, undoManager) = makeStore(groups: [group])

        performGesture(using: undoManager) {
            store.renameGroup(id: group.id, to: "Renamed")
        }
        #expect(undoManager.canUndo)

        // Same group ID, different values — surviving registrations would
        // "revert" restored state to pre-restore values.
        let restored = SessionGroup(id: group.id, name: "Restored", sessions: group.sessions)
        store.replaceState(
            restoring: SessionSnapshot(groups: [restored], selectedSessionID: nil)
        )

        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
    }

    @Test("rebinding clears the old manager's actions")
    func rebindingClearsOldManager() {
        let group = SessionGroup(name: "Group", sessions: [])
        let (store, oldManager) = makeStore(groups: [group])
        let newManager = UndoManager()
        newManager.groupsByEvent = false

        performGesture(using: oldManager) {
            store.renameGroup(id: group.id, to: "Renamed")
        }
        store.undoManager = newManager

        #expect(!oldManager.canUndo)
        #expect(store.undoManager === newManager)
    }

    private func makeStore(groups: [SessionGroup]) -> (SessionStore, UndoManager) {
        let store = SessionStore(groups: groups)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        return (store, undoManager)
    }

    private func makeSession(_ title: String) -> TerminalSession {
        TerminalSession(title: title, workingDirectory: "~", agentKind: .shell)
    }

    private func performGesture(using undoManager: UndoManager, _ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }
}
