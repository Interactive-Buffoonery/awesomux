import Foundation
import Testing
@testable import AwesoMuxCore

// INT-748: each document tab stores the terminal pane its send/stage actions
// target. These tests pin the association lifecycle: captured at open, immune
// to dedup, per-tab across closes, and following a recycled pane's new id.
@Suite struct DocumentTabAssociationTests {
    private func makeTwoTerminalSession() -> (session: TerminalSession, t1: TerminalPane, t2: TerminalPane) {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp")
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp")
        var session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t1),
                second: .pane(t2)
            ))
        )
        session.activePaneID = t1.id
        return (session, t1, t2)
    }

    private func openTab(
        _ path: String,
        associatedWith paneID: TerminalPane.ID?,
        in session: TerminalSession
    ) -> (session: TerminalSession, newTabID: DocumentPane.ID)? {
        PaneLayoutReducer.openDocumentTab(
            fileURL: URL(fileURLWithPath: path),
            associatedTerminalPaneID: paneID,
            in: session,
            now: Date()
        )
    }

    @Test func tabsRetainTheirOwnAssociationsAcrossOpens() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let (second, tabB) = try #require(openTab("/tmp/b.md", associatedWith: t2.id, in: first))

        let group = try #require(second.layout.firstDocumentGroup)
        #expect(group.tab(id: tabA)?.associatedTerminalPaneID == t1.id)
        #expect(group.tab(id: tabB)?.associatedTerminalPaneID == t2.id)
    }

    @Test func remoteSnapshotTabUsesRemoteFileNameAsTitle() throws {
        let (session, t1, _) = makeTwoTerminalSession()

        let (opened, tabID) = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: URL(fileURLWithPath: "/tmp/3a70fb49e7a91c2.md"),
            associatedTerminalPaneID: t1.id,
            remoteSnapshotOrigin: "devbox:/srv/skills/network-hosts/SKILL.md",
            in: session,
            now: Date()
        ))

        let group = try #require(opened.layout.firstDocumentGroup)
        #expect(group.tab(id: tabID)?.title == "SKILL.md")
    }

    @Test func reopeningRemoteSnapshotRepairsCacheHashTitle() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let url = URL(fileURLWithPath: "/tmp/3a70fb49e7a91c2.md")
        let (opened, tabID) = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: url,
            associatedTerminalPaneID: t1.id,
            in: session,
            now: Date()
        ))

        let (reopened, reopenedTabID) = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: url,
            associatedTerminalPaneID: t1.id,
            remoteSnapshotOrigin: "devbox:/srv/skills/network-hosts/SKILL.md",
            in: opened,
            now: Date()
        ))

        let group = try #require(reopened.layout.firstDocumentGroup)
        #expect(reopenedTabID == tabID)
        #expect(group.tab(id: tabID)?.title == "SKILL.md")
    }

    @Test func localReopenOfSnapshotCacheFilePreservesReadOnlyOrigin() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let url = URL(fileURLWithPath: "/tmp/3a70fb49e7a91c2.md")
        let origin = "devbox:/srv/skills/network-hosts/SKILL.md"
        let (opened, tabID) = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: url,
            associatedTerminalPaneID: t1.id,
            remoteSnapshotOrigin: origin,
            in: session,
            now: Date()
        ))

        // Opening the same cache file through a local (nil-origin) path must not
        // strip the snapshot's read-only provenance and turn it writable.
        let (reopened, reopenedTabID) = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: url,
            associatedTerminalPaneID: t1.id,
            in: opened,
            now: Date()
        ))

        #expect(reopenedTabID == tabID)
        let group = try #require(reopened.layout.firstDocumentGroup)
        #expect(group.tab(id: tabID)?.remoteSnapshotOrigin == origin)
        #expect(group.tab(id: tabID)?.title == "SKILL.md")
    }

    @Test func selectingTabNeverMutatesActivePane() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let (second, _) = try #require(openTab("/tmp/b.md", associatedWith: t2.id, in: first))
        #expect(second.activePaneID == t1.id)

        let selected = try #require(PaneLayoutReducer.selectDocumentTab(tabID: tabA, in: second))
        #expect(selected.activePaneID == t1.id, "tab selection must not move terminal focus")
        let group = try #require(selected.layout.firstDocumentGroup)
        #expect(group.selectedTabID == tabA)
    }

    @Test func selectingUnknownOrAlreadySelectedTabIsNoOp() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let (opened, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))

        #expect(PaneLayoutReducer.selectDocumentTab(tabID: tabA, in: opened) == nil)
        #expect(PaneLayoutReducer.selectDocumentTab(tabID: DocumentPane.ID(), in: opened) == nil)
    }

    @Test func closingOneTabLeavesOtherAssociationIdentical() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let (second, tabB) = try #require(openTab("/tmp/b.md", associatedWith: t2.id, in: first))

        let closed = try #require(
            PaneLayoutReducer.closeDocumentTab(tabID: tabA, in: second, now: Date())
        )
        let group = try #require(closed.layout.firstDocumentGroup)
        #expect(group.tab(id: tabB)?.associatedTerminalPaneID == t2.id)
        #expect(closed.activePaneID == t1.id)
    }

    @Test func closingLastTabRestoresPreOpenLayout() throws {
        let (session, t1, _) = makeTwoTerminalSession()

        let (opened, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let closed = try #require(
            PaneLayoutReducer.closeDocumentTab(tabID: tabA, in: opened, now: Date())
        )
        #expect(closed.layout == session.layout)
    }

    @Test func dedupDoesNotOverwriteLiveAssociation() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        // Reopen the same file "from" the other terminal.
        let (second, reopenedID) = try #require(openTab("/tmp/a.md", associatedWith: t2.id, in: first))

        #expect(reopenedID == tabA)
        let group = try #require(second.layout.firstDocumentGroup)
        #expect(
            group.tab(id: tabA)?.associatedTerminalPaneID == t1.id,
            "reopening an open file must not silently retarget a LIVE association"
        )
    }

    @Test func dedupHealsDeadAssociation() throws {
        let (session, _, t2) = makeTwoTerminalSession()

        // The tab's terminal is gone (a pane id that no longer exists in the
        // layout) — reopening from a live terminal repairs the routing instead
        // of leaving the send button permanently fail-closed.
        let deadPaneID = TerminalPane.ID()
        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: deadPaneID, in: session))
        let (second, reopenedID) = try #require(openTab("/tmp/a.md", associatedWith: t2.id, in: first))

        #expect(reopenedID == tabA)
        let group = try #require(second.layout.firstDocumentGroup)
        #expect(
            group.tab(id: tabA)?.associatedTerminalPaneID == t2.id,
            "a dead association heals to the incoming live pane"
        )
    }

    @Test func openWithoutSelectingAppendsInBackground() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let result = try #require(PaneLayoutReducer.openDocumentTab(
            fileURL: URL(fileURLWithPath: "/tmp/b.md"),
            associatedTerminalPaneID: t2.id,
            in: first,
            now: Date(),
            selectingNewTab: false
        ))

        let group = try #require(result.session.layout.firstDocumentGroup)
        #expect(group.tabs.count == 2)
        #expect(
            group.selectedTabID == tabA,
            "deferred selection keeps the current tab (open during comment compose)"
        )
        #expect(group.tab(id: result.newTabID)?.associatedTerminalPaneID == t2.id)
    }

    @MainActor
    @Test func facadeWithNilAssociationCapturesActivePaneAtOpen() throws {
        let (session, _, t2) = makeTwoTerminalSession()
        var focused = session
        focused.activePaneID = t2.id
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [focused])],
            selectedSessionID: focused.id
        )

        let tabID = try #require(
            store.openDocumentPane(fileURL: URL(fileURLWithPath: "/tmp/a.md"), in: focused.id)
        )

        let group = try #require(store.session(id: focused.id)?.layout.firstDocumentGroup)
        #expect(
            group.tab(id: tabID)?.associatedTerminalPaneID == t2.id,
            "nil association captures the session's activePaneID at open time"
        )
    }

    @MainActor
    @Test func facadeCanPreserveNilAssociationForDocumentLinkOpens() throws {
        let (session, _, t2) = makeTwoTerminalSession()
        var focused = session
        focused.activePaneID = t2.id
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [focused])],
            selectedSessionID: focused.id
        )

        let tabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                in: focused.id,
                associationPolicy: .preserveNil
            )
        )

        let group = try #require(store.session(id: focused.id)?.layout.firstDocumentGroup)
        #expect(
            group.tab(id: tabID)?.associatedTerminalPaneID == nil,
            "document-to-document opens must not silently capture activePaneID when no safe source association exists"
        )
    }

    @MainActor
    @Test func facadePreservesExistingNilAssociationOnDocumentLinkDedup() throws {
        let (session, _, t2) = makeTwoTerminalSession()
        var focused = session
        focused.activePaneID = t2.id
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [focused])],
            selectedSessionID: focused.id
        )

        let firstTabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                in: focused.id,
                associationPolicy: .preserveNil
            )
        )
        let reopenedTabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                in: focused.id,
                associationPolicy: .preserveNil
            )
        )

        let group = try #require(store.session(id: focused.id)?.layout.firstDocumentGroup)
        #expect(reopenedTabID == firstTabID)
        #expect(
            group.tab(id: firstTabID)?.associatedTerminalPaneID == nil,
            "document-to-document dedup with no safe source association must not heal nil to activePaneID"
        )
    }

    @Test func recycleRewritesMatchingAssociationsToReplacementPane() throws {
        let (session, t1, t2) = makeTwoTerminalSession()

        let (first, tabA) = try #require(openTab("/tmp/a.md", associatedWith: t1.id, in: session))
        let (second, tabB) = try #require(openTab("/tmp/b.md", associatedWith: t2.id, in: first))

        // t1 is the active pane; recycle it.
        let result = try #require(PaneLayoutReducer.recycleActivePane(in: second, now: Date()))
        #expect(result.discardedPaneID == t1.id)
        let newPaneID = result.session.activePaneID

        let group = try #require(result.session.layout.firstDocumentGroup)
        #expect(
            group.tab(id: tabA)?.associatedTerminalPaneID == newPaneID,
            "tabs associated with the recycled pane follow it to the replacement id"
        )
        #expect(
            group.tab(id: tabB)?.associatedTerminalPaneID == t2.id,
            "other tabs' associations are untouched"
        )
    }

    @Test func documentSendTargetUsesLiveStoredAssociation() throws {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp/one")
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp/two")
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: t2.id
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(t2),
            second: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t1),
                second: .documentGroup(group)
            ))
        ))

        #expect(layout.documentSendTarget(for: doc.id)?.id == t2.id)
    }

    @Test func documentSendTargetUsesDirectSiblingForNilAssociation() throws {
        let terminal = TerminalPane(title: "t1", workingDirectory: "/tmp/one")
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: nil
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group)
        ))

        #expect(layout.documentSendTarget(for: doc.id)?.id == terminal.id)
    }

    @Test func documentSendTargetFailsClosedForAmbiguousNilAssociationSibling() throws {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp/one")
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp/two")
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: nil
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(t1),
                second: .pane(t2)
            )),
            second: .documentGroup(group)
        ))

        #expect(layout.documentSendTarget(for: doc.id) == nil)
    }

    @Test func documentSendTargetFailsClosedForStaleExplicitAssociation() throws {
        let terminal = TerminalPane(title: "t1", workingDirectory: "/tmp/one")
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: TerminalPane.ID()
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group)
        ))

        #expect(layout.documentSendTarget(for: doc.id) == nil)
    }
}
