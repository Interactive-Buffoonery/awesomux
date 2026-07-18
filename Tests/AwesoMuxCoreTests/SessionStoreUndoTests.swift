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
        #expect(store.removeGroup(id: target.id))

        undoManager.undo()

        #expect(!undoManager.canRedo)
        #expect(store.groups.map(\.id) == [survivor.id])
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
