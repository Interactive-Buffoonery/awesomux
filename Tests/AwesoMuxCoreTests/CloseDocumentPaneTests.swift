import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite struct CloseDocumentPaneTests {
    private func makeDoc() -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "int562-\(UUID().uuidString).md"),
            title: "notes.md"
        )
    }

    private func makeGroup(_ tabs: [DocumentPane], selected: DocumentPane.ID? = nil) -> DocumentGroup {
        DocumentGroup(tabs: tabs, selectedTabID: selected ?? tabs[0].id)
    }

    @Test("closing the last tab removes the viewer and leaves activePaneID unchanged")
    func closingLastTabRemovesViewerKeepsTerminal() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let doc = makeDoc()
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(makeGroup([doc]))
            )),
            activePaneID: terminal.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        let prePaneIDs = session.layout.paneIDs

        store.closeDocumentPane(documentID: doc.id, in: session.id)

        let updated = try #require(store.session(id: session.id))
        // Layout collapses to a bare terminal pane
        guard case let .pane(survivor) = updated.layout else {
            Issue.record("Expected collapsed layout to be a single terminal pane")
            return
        }
        #expect(survivor.id == terminal.id)
        // activePaneID is untouched
        #expect(updated.activePaneID == terminal.id)
        // paneIDs (terminal enumeration) is unchanged
        #expect(updated.layout.paneIDs == prePaneIDs)
    }

    @Test("closing one tab keeps the group, other tabs, and their associations intact")
    func closingOneTabPreservesOthers() throws {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp")
        var docA = makeDoc()
        docA.associatedTerminalPaneID = t1.id
        var docB = makeDoc()
        let otherTerminalID = TerminalPane.ID()
        docB.associatedTerminalPaneID = otherTerminalID
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t1),
                second: .documentGroup(makeGroup([docA, docB], selected: docA.id))
            )),
            activePaneID: t1.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        store.closeDocumentPane(documentID: docA.id, in: session.id)

        let updated = try #require(store.session(id: session.id))
        let group = try #require(updated.layout.firstDocumentGroup)
        #expect(group.tabs.count == 1)
        #expect(group.tab(id: docA.id) == nil)
        let survivor = try #require(group.tab(id: docB.id))
        #expect(
            survivor.associatedTerminalPaneID == otherTerminalID,
            "closing one tab must not corrupt another tab's terminal association"
        )
        #expect(group.selectedTabID == docB.id, "closing the selected tab selects its neighbor")
        #expect(updated.activePaneID == t1.id)
    }

    @Test("closing an unselected tab keeps the current selection")
    func closingUnselectedTabKeepsSelection() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let docA = makeDoc()
        let docB = makeDoc()
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(makeGroup([docA, docB], selected: docB.id))
            )),
            activePaneID: terminal.id
        )

        let updated = try #require(
            PaneLayoutReducer.closeDocumentTab(tabID: docA.id, in: session, now: Date())
        )
        let group = try #require(updated.layout.firstDocumentGroup)
        #expect(group.selectedTabID == docB.id)
        #expect(group.tabs.count == 1)
    }

    @Test("closing the selected middle tab selects the tab that took its index")
    func closingSelectedMiddleTabSelectsNeighbor() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let docA = makeDoc()
        let docB = makeDoc()
        let docC = makeDoc()
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(makeGroup([docA, docB, docC], selected: docB.id))
            )),
            activePaneID: terminal.id
        )

        let updated = try #require(
            PaneLayoutReducer.closeDocumentTab(tabID: docB.id, in: session, now: Date())
        )
        let group = try #require(updated.layout.firstDocumentGroup)
        #expect(group.selectedTabID == docC.id, "min(closedIndex, remaining-1) picks the successor")
    }

    @Test("closeDocumentPane with unknown id is a no-op")
    func closeDocumentPaneUnknownIDIsNoOp() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let doc = makeDoc()
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(makeGroup([doc]))
            )),
            activePaneID: terminal.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        store.closeDocumentPane(documentID: DocumentPane.ID(), in: session.id)

        let unchanged = try #require(store.session(id: session.id))
        #expect(unchanged.layout == session.layout)
        #expect(unchanged.activePaneID == terminal.id)
    }
}
