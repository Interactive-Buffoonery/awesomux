import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore pane move to workspace")
struct SessionStoreMoveToWorkspaceTests {
    @Test("move inserts after source, inherits pin, and selects moved row")
    func moveTransaction() throws {
        let other = TerminalSession(title: "other", workingDirectory: "~")
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(
            title: "source",
            workingDirectory: "~",
            layout: split(.pane(first), .pane(movedPane)),
            activePaneID: movedPane.id
        )
        let tail = TerminalSession(title: "tail", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "work", sessions: [other, source, tail])],
            pinnedSessionIDs: [other.id, source.id, tail.id]
        )

        let movedID = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))
        #expect(store.groups[0].sessions.map(\.id) == [other.id, source.id, movedID, tail.id])
        #expect(store.pinnedSessionIDs == [other.id, source.id, movedID, tail.id])
        #expect(store.selectedSessionID == movedID)
    }

    @Test("return removes only the moved row, selects source, and prunes its independent pin")
    func returnTransaction() throws {
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(
            title: "source",
            workingDirectory: "~",
            layout: split(
                .pane(first), .pane(movedPane), orientation: .horizontal, fraction: 0.37
            )
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "work", sessions: [source])],
            pinnedSessionIDs: [source.id]
        )
        let movedID = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))
        store.togglePin(sessionID: source.id)
        #expect(store.pinnedSessionIDs == [movedID])

        #expect(store.returnPaneToSourceWorkspace(sessionID: movedID))
        #expect(store.groups[0].sessions.map(\.id) == [source.id])
        #expect(store.selectedSessionID == source.id)
        #expect(store.pinnedSessionIDs.isEmpty)
        #expect(store.session(id: source.id)?.layout.paneIDs == [first.id, movedPane.id])
        let root = try #require(store.session(id: source.id)?.layout.rootSplit)
        #expect(root.orientation == .horizontal)
        #expect(root.firstFraction == 0.37)
    }

    @Test("move survives snapshot restore and returns with its original shape")
    func snapshotRestoreThenReturn() throws {
        let p = pane("p")
        let q = pane("q")
        let original = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(p),
                second: .pane(q),
                firstFraction: 0.37
            )
        )
        let source = TerminalSession(title: "source", workingDirectory: "~", layout: original)
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        let movedID = try #require(store.movePaneToNewWorkspace(id: p.id, in: source.id))
        let snapshot = SessionSnapshot(
            groups: store.groups,
            selectedSessionID: store.selectedSessionID,
            pinnedSessionIDs: store.pinnedSessionIDs
        )
        let decoded = try SessionSnapshot.decode(from: JSONEncoder().encode(snapshot))
        let restored = SessionStore(restoring: decoded)

        #expect(restored.returnPaneToSourceWorkspace(sessionID: movedID))
        let layout = try #require(restored.session(id: source.id)?.layout)
        #expect(layout.isStructurallyEquivalent(to: original))
        let root = try #require(layout.rootSplit)
        #expect(root.orientation == .horizontal)
        #expect(root.firstFraction == 0.37)
    }

    @Test("restore drops origins pointing at duplicated incoming session ids")
    func restoreDropsAmbiguousDuplicateSourceOrigin() throws {
        let duplicateID = UUID()
        let firstSource = TerminalSession(id: duplicateID, title: "first", workingDirectory: "~")
        let secondSource = TerminalSession(id: duplicateID, title: "second", workingDirectory: "~")
        var moved = TerminalSession(title: "moved", workingDirectory: "~")
        moved.moveOrigin = PaneMoveOrigin(
            sourceSessionID: duplicateID,
            paneID: moved.activePaneID,
            parentSplitID: UUID(),
            sibling: .pane(firstSource.activePaneID),
            edge: .left,
            fraction: 0.5
        )
        let store = SessionStore(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "work", sessions: [firstSource, secondSource, moved])],
                selectedSessionID: moved.id
            )
        )

        #expect(store.session(id: moved.id)?.moveOrigin == nil)
    }

    @Test("restore drops origins whose pane or split ids were duplicated in the snapshot")
    func restoreDropsOriginsWithDuplicatedLayoutIDs() throws {
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(title: "source", workingDirectory: "~", layout: split(.pane(first), .pane(movedPane)))
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        let movedID = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))
        // A stranger row that reuses the moved pane's id: restore re-mints one
        // of them, so the origin's paneID no longer names a single pane.
        let stranger = TerminalSession(
            title: "stranger",
            workingDirectory: "~",
            layout: .pane(TerminalPane(id: movedPane.id, title: "stranger", workingDirectory: "~", executionPlan: .local))
        )
        var groups = store.groups
        groups[0].sessions.append(stranger)
        let restored = SessionStore(
            restoring: SessionSnapshot(groups: groups, selectedSessionID: movedID)
        )
        #expect(restored.session(id: movedID)?.moveOrigin == nil)
        #expect(!restored.canReturnPaneToSourceWorkspace(sessionID: movedID))
    }

    @Test("return never reuses a parent split id that another workspace holds")
    func returnAvoidsCrossWorkspaceSplitID() throws {
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(title: "source", workingDirectory: "~", layout: split(.pane(first), .pane(movedPane)))
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        let movedID = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))
        let parentID = try #require(store.session(id: movedID)?.moveOrigin?.parentSplitID)
        let other = TerminalSession(
            title: "other",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(id: parentID, orientation: .horizontal, first: .pane(pane("x")), second: .pane(pane("y"))))
        )
        store.insertSession(other, groupName: "work", select: false)

        #expect(store.returnPaneToSourceWorkspace(sessionID: movedID))
        guard case let .split(sourceRoot)? = store.session(id: source.id)?.layout else {
            Issue.record("source should be a split after return")
            return
        }
        #expect(sourceRoot.id != parentID)
        #expect(store.session(id: source.id)?.layout.paneIDs == [first.id, movedPane.id])
    }

    @Test("return disables after source closes")
    func sourceClosed() throws {
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(title: "source", workingDirectory: "~", layout: split(.pane(first), .pane(movedPane)))
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        let movedID = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))
        store.closeSession(id: source.id)
        #expect(!store.canReturnPaneToSourceWorkspace(sessionID: movedID))
        #expect(!store.returnPaneToSourceWorkspace(sessionID: movedID))
    }

    @Test("snapshot restore keeps valid origin and drops self-reference")
    func restoreOrigins() throws {
        let sibling = pane("sibling")
        let validSource = TerminalSession(title: "source", workingDirectory: "~")
        let valid = TerminalSession(
            title: "valid",
            workingDirectory: "~",
            moveOrigin: PaneMoveOrigin(
                sourceSessionID: validSource.id,
                paneID: sibling.id,
                parentSplitID: UUID(),
                sibling: .pane(sibling.id),
                edge: .right,
                fraction: 0.4
            )
        )
        var selfReferenced = TerminalSession(title: "bad", workingDirectory: "~")
        selfReferenced.moveOrigin = PaneMoveOrigin(
            sourceSessionID: selfReferenced.id,
            paneID: selfReferenced.activePaneID,
            parentSplitID: UUID(),
            sibling: .pane(sibling.id),
            edge: .left,
            fraction: 0.5
        )
        let store = SessionStore(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "work", sessions: [validSource, valid, selfReferenced])],
                selectedSessionID: valid.id
            ))
        #expect(store.session(id: valid.id)?.moveOrigin == valid.moveOrigin)
        #expect(store.session(id: selfReferenced.id)?.moveOrigin == nil)
    }

    @Test("stale source runtime event does not erase moved pane state")
    func staleRuntimeEventPreservesState() throws {
        let first = pane("first")
        let movedPane = pane("moved")
        let source = TerminalSession(title: "source", workingDirectory: "~", layout: split(.pane(first), .pane(movedPane)))
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        store.runtimeEventReducer.stateByPaneID[movedPane.id] = .init()
        _ = try #require(store.movePaneToNewWorkspace(id: movedPane.id, in: source.id))

        #expect(
            !store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(source: .claudeCode, state: .thinking),
                to: source.id,
                paneID: movedPane.id
            ))
        #expect(store.runtimeEventReducer.stateByPaneID[movedPane.id] != nil)
    }

    private func pane(_ title: String) -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "~", executionPlan: .local)
    }

    private func split(
        _ first: TerminalPaneLayout,
        _ second: TerminalPaneLayout,
        orientation: TerminalSplitOrientation = .vertical,
        fraction: Double = 0.5
    ) -> TerminalPaneLayout {
        .split(
            TerminalSplit(
                orientation: orientation,
                first: first,
                second: second,
                firstFraction: fraction
            )
        )
    }
}

private extension TerminalPaneLayout {
    var rootSplit: TerminalSplit? {
        guard case let .split(split) = self else { return nil }
        return split
    }
}
