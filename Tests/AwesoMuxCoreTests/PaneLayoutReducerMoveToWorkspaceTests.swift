import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Pane move to workspace")
struct PaneLayoutReducerMoveToWorkspaceTests {
    @Test("moving a middle pane preserves pane chrome and repairs the source")
    func movesMiddlePane() throws {
        let a = pane("a", "/a")
        let b = pane("b", "/b")
        let c = pane("c", "/c")
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/b",
            isTitleUserEdited: true,
            notificationsMuted: true,
            layout: split(.pane(a), split(.pane(b), .pane(c))),
            activePaneID: b.id
        )

        let result = try #require(PaneLayoutReducer.movePaneToNewWorkspace(id: b.id, from: session))
        #expect(result.source.layout.paneIDs == [a.id, c.id])
        #expect(result.source.layout.pane(id: result.source.activePaneID) != nil)
        #expect(result.moved.layout == .pane(b))
        #expect(result.moved.notificationsMuted)
        #expect(!result.moved.isTitleUserEdited)
        #expect(result.moved.title == b.title)
        #expect(result.moved.workingDirectory == b.workingDirectory)
    }

    @Test("move refuses single, missing, and remote panes")
    func refusesInvalidMoves() {
        let local = pane("local", "/local")
        let remote = TerminalPane(
            title: "remote",
            workingDirectory: "/remote",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(user: "ed", host: "box")!))
        )
        let single = TerminalSession(title: "single", workingDirectory: "~", layout: .pane(local))
        let mixed = TerminalSession(
            title: "mixed",
            workingDirectory: "~",
            layout: split(.pane(local), .pane(remote))
        )
        #expect(PaneLayoutReducer.movePaneToNewWorkspace(id: local.id, from: single) == nil)
        #expect(PaneLayoutReducer.movePaneToNewWorkspace(id: UUID(), from: mixed) == nil)
        #expect(PaneLayoutReducer.movePaneToNewWorkspace(id: remote.id, from: mixed) == nil)
    }

    @Test(
        "origin records all four parent edges and fractions",
        arguments: [
            (TerminalSplitOrientation.vertical, true, PaneMoveEdge.left),
            (.vertical, false, .right),
            (.horizontal, true, .up),
            (.horizontal, false, .down),
        ])
    func recordsEdges(orientation: TerminalSplitOrientation, first: Bool, edge: PaneMoveEdge) throws {
        let moved = pane("moved", "/m")
        let sibling = pane("sibling", "/s")
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: orientation,
                first: first ? .pane(moved) : .pane(sibling),
                second: first ? .pane(sibling) : .pane(moved),
                firstFraction: 0.37
            ))
        let origin = try #require(layout.moveOrigin(of: moved.id))
        #expect(origin.sibling == .pane(sibling.id))
        #expect(origin.parentSplitID == layout.rootSplitID)
        #expect(origin.edge == edge)
        #expect(origin.fraction == 0.37)
    }

    @Test("return restores an exact sibling subtree")
    func restoresSiblingSubtree() throws {
        let a = pane("a", "/a")
        let b = pane("b", "/b")
        let c = pane("c", "/c")
        let original = split(.pane(a), split(.pane(b), .pane(c), fraction: 0.31), fraction: 0.64)
        let source = TerminalSession(title: "source", workingDirectory: "/a", layout: original)
        let moved = try #require(PaneLayoutReducer.movePaneToNewWorkspace(id: a.id, from: source))
        #expect(moved.moved.moveOrigin?.sibling == siblingID(of: original))
        let returned = try #require(PaneLayoutReducer.returnPane(from: moved.moved, to: moved.source))
        #expect(returned.layout.isStructurallyEquivalent(to: original))
        #expect(returned.layout.split(id: siblingSplitID(of: original))?.firstFraction == 0.31)
        guard case let .split(returnedRoot) = returned.layout else {
            Issue.record("Expected restored root split")
            return
        }
        #expect(returnedRoot.id == original.rootSplitID)
        #expect(returnedRoot.firstFraction == 0.64)
    }

    @Test("return refuses a replacement sole pane")
    func refusesReplacementPane() throws {
        let original = pane("original", "/original")
        let sibling = pane("sibling", "/sibling")
        let replacement = pane("replacement", "/replacement")
        let source = TerminalSession(
            title: "source", workingDirectory: "/original",
            layout: split(.pane(original), .pane(sibling))
        )
        let result = try #require(
            PaneLayoutReducer.movePaneToNewWorkspace(id: original.id, from: source)
        )
        var moved = result.moved
        moved.layout = .pane(replacement)

        #expect(PaneLayoutReducer.returnPane(from: moved, to: result.source) == nil)
    }

    @Test("out-of-order returns preserve nested split identities and fractions")
    func returnsNestedMovesOutOfOrder() throws {
        let p = pane("p", "/p")
        let q = pane("q", "/q")
        let r = pane("r", "/r")
        let inner = TerminalSplit(
            orientation: .horizontal,
            first: .pane(p),
            second: .pane(q),
            firstFraction: 0.31
        )
        let outer = TerminalSplit(
            orientation: .vertical,
            first: .split(inner),
            second: .pane(r),
            firstFraction: 0.64
        )
        let original = TerminalPaneLayout.split(outer)
        let session = TerminalSession(title: "source", workingDirectory: "/p", layout: original)

        let movedR = try #require(
            PaneLayoutReducer.movePaneToNewWorkspace(id: r.id, from: session)
        )
        let movedP = try #require(
            PaneLayoutReducer.movePaneToNewWorkspace(id: p.id, from: movedR.source)
        )
        let withP = try #require(
            PaneLayoutReducer.returnPane(from: movedP.moved, to: movedP.source)
        )
        let restored = try #require(
            PaneLayoutReducer.returnPane(from: movedR.moved, to: withP)
        )

        #expect(restored.layout.isStructurallyEquivalent(to: original))
        let restoredOuter = try #require(restored.layout.split(id: outer.id))
        let restoredInner = try #require(restored.layout.split(id: inner.id))
        #expect(restoredOuter.firstFraction == 0.64)
        #expect(restoredInner.firstFraction == 0.31)
    }

    @Test("document siblings restore without terminal-only traversal")
    func restoresDocumentSibling() throws {
        let pane = pane("pane", "/p")
        let document = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/note.md"), title: "note")
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let other = self.pane("other", "/o")
        let original = split(
            split(.pane(pane), .documentGroup(group), fraction: 0.61),
            .pane(other)
        )
        let source = TerminalSession(title: "source", workingDirectory: "/p", layout: original)
        let moved = try #require(PaneLayoutReducer.movePaneToNewWorkspace(id: pane.id, from: source))
        #expect(moved.moved.moveOrigin?.sibling == .documentGroup(group.id))
        let returned = try #require(PaneLayoutReducer.returnPane(from: moved.moved, to: moved.source))
        #expect(returned.layout.isStructurallyEquivalent(to: original))
        #expect(returned.layout.firstDocumentGroup?.id == group.id)
    }

    @Test("return falls back to active pane and refuses changed or self-referential rows")
    func returnValidationAndFallback() throws {
        let a = pane("a", "/a")
        let b = pane("b", "/b")
        let c = pane("c", "/c")
        let source = TerminalSession(title: "source", workingDirectory: "/a", layout: split(.pane(a), .pane(b)))
        var moved = try #require(PaneLayoutReducer.movePaneToNewWorkspace(id: a.id, from: source)).moved
        let changedSource = TerminalSession(id: source.id, title: "source", workingDirectory: "/c", layout: .pane(c))
        #expect(PaneLayoutReducer.returnPane(from: moved, to: changedSource)?.layout.paneIDs == [a.id, c.id])

        moved.layout = split(.pane(a), .pane(b))
        #expect(PaneLayoutReducer.returnPane(from: moved, to: changedSource) == nil)

        var selfReferenced = TerminalSession(id: moved.id, title: "self", workingDirectory: "/a", layout: .pane(a))
        selfReferenced.moveOrigin = PaneMoveOrigin(
            sourceSessionID: moved.id,
            paneID: a.id,
            parentSplitID: UUID(),
            sibling: .pane(c.id),
            edge: .left,
            fraction: 0.5
        )
        let selfSource = TerminalSession(id: moved.id, title: "self", workingDirectory: "/c", layout: .pane(c))
        #expect(PaneLayoutReducer.returnPane(from: selfReferenced, to: selfSource) == nil)
    }

    @Test("return mints a fresh parent id when the recorded one is already live in the source")
    func returnAvoidsDuplicateParentSplitID() throws {
        let a = pane("a", "/a")
        let b = pane("b", "/b")
        let c = pane("c", "/c")
        let source = TerminalSession(title: "source", workingDirectory: "/a", layout: split(.pane(a), .pane(b)))
        let result = try #require(PaneLayoutReducer.movePaneToNewWorkspace(id: a.id, from: source))
        let parentID = try #require(result.moved.moveOrigin?.parentSplitID)
        // A reopened or re-minted source that reused the parent id under a
        // different shape: Return must not produce two splits with one id.
        let collidingSource = TerminalSession(
            id: source.id,
            title: "source",
            workingDirectory: "/b",
            layout: .split(TerminalSplit(id: parentID, orientation: .horizontal, first: .pane(b), second: .pane(c)))
        )
        let returned = try #require(PaneLayoutReducer.returnPane(from: result.moved, to: collidingSource))
        var splitIDs: [TerminalSplit.ID] = []
        func collect(_ layout: TerminalPaneLayout) {
            if case let .split(split) = layout {
                splitIDs.append(split.id)
                collect(split.first)
                collect(split.second)
            }
        }
        collect(returned.layout)
        #expect(Set(splitIDs).count == splitIDs.count)
        #expect(
            returned.layout.paneIDs.sorted(by: { $0.uuidString < $1.uuidString })
                == [a.id, b.id, c.id].sorted(by: { $0.uuidString < $1.uuidString }))
    }

    private func pane(_ title: String, _ directory: String) -> TerminalPane {
        TerminalPane(title: title, workingDirectory: directory, executionPlan: .local)
    }

    private func split(
        _ first: TerminalPaneLayout,
        _ second: TerminalPaneLayout,
        fraction: Double = 0.5
    ) -> TerminalPaneLayout {
        .split(
            TerminalSplit(
                orientation: .vertical,
                first: first,
                second: second,
                firstFraction: fraction
            ))
    }

    private func siblingID(of layout: TerminalPaneLayout) -> PaneMoveOrigin.Sibling? {
        guard case let .split(root) = layout, case let .split(sibling) = root.second else { return nil }
        return .split(sibling.id)
    }

    private func siblingSplitID(of layout: TerminalPaneLayout) -> TerminalSplit.ID {
        guard case let .split(root) = layout, case let .split(sibling) = root.second else {
            preconditionFailure("fixture must contain a sibling split")
        }
        return sibling.id
    }
}

private extension TerminalPaneLayout {
    var rootSplitID: TerminalSplit.ID? {
        guard case let .split(split) = self else { return nil }
        return split.id
    }
}
