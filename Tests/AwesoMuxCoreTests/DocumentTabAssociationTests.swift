import Foundation
import Testing
@testable import AwesoMuxCore

// INT-748: each document tab stores the terminal pane its send/stage actions
// target. Keep sends scoped to a live association and preserve read-only provenance.
@Suite struct DocumentTabAssociationTests {
    private let remoteIdentity = ResourceIdentity(
        location: .remote(RemoteTarget(parsing: "devbox")!),
        path: ResourcePath(rawValue: "/srv/skills/network-hosts/SKILL.md")
    )

    private func makeTwoTerminalSession() -> (session: TerminalSession, t1: TerminalPane, t2: TerminalPane) {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp", executionPlan: .local)
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
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

    private enum SendCase: CaseIterable { case storedAssociation, directSibling, ambiguousSibling, staleAssociation }

    @Test(arguments: SendCase.allCases)
    private func sendTarget(scenario: SendCase) {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp/one", executionPlan: .local)
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp/two", executionPlan: .local)
        let association: TerminalPane.ID? = scenario == .storedAssociation ? t2.id : scenario == .staleAssociation ? TerminalPane.ID() : nil
        let doc = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/a.md"), title: "a.md", associatedTerminalPaneID: association)
        let group = TerminalPaneLayout.documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
        let layout: TerminalPaneLayout
        switch scenario {
        case .storedAssociation:
            layout = .split(
                TerminalSplit(
                    orientation: .vertical, first: .pane(t2),
                    second: .split(TerminalSplit(orientation: .vertical, first: .pane(t1), second: group))))
        case .ambiguousSibling:
            layout = .split(
                TerminalSplit(
                    orientation: .vertical, first: .split(TerminalSplit(orientation: .horizontal, first: .pane(t1), second: .pane(t2))),
                    second: group))
        case .directSibling, .staleAssociation:
            layout = .split(TerminalSplit(orientation: .vertical, first: .pane(t1), second: group))
        }
        let expected = scenario == .storedAssociation ? t2.id : scenario == .directSibling ? t1.id : nil
        #expect(layout.documentSendTarget(for: doc.id)?.id == expected)
    }

    private enum NudgeCase: CaseIterable { case local, ssh, remoteSnapshot }

    @Test(arguments: NudgeCase.allCases)
    private func nudgeTarget(scenario: NudgeCase) {
        let target = RemoteTarget(user: "alice", host: "remote.example")!
        let terminal = TerminalPane(
            title: scenario == .local ? "alice@remote:~/repo" : scenario == .ssh ? "local-looking-title" : "local",
            workingDirectory: scenario == .ssh ? "/Users/alice/repo" : "/tmp",
            remoteHost: scenario == .local ? "remote.example" : nil,
            remoteSSHTarget: scenario == .local ? "remote-alias" : nil,
            executionPlan: scenario == .ssh ? .ssh(SSHExecution(target: target)) : .local
        )
        let doc = DocumentPane(
            fileURL: URL(
                fileURLWithPath: scenario == .ssh ? "/Users/alice/repo/a.md" : scenario == .remoteSnapshot ? "/tmp/cache.md" : "/tmp/a.md"),
            title: scenario == .remoteSnapshot ? "README.md" : "a.md", associatedTerminalPaneID: terminal.id,
            remoteResourceIdentity: scenario == .remoteSnapshot ? remoteIdentity : nil
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(orientation: .vertical, first: .pane(terminal), second: .documentGroup(group)))
        switch scenario {
        case .local: #expect(layout.documentNudgeTarget(for: doc.id) == .available(terminal))
        case .ssh: #expect(layout.documentNudgeTarget(for: doc.id) == .unavailable(.requiresLocalTerminal))
        case .remoteSnapshot: #expect(layout.documentNudgeTarget(for: doc.id) == .unavailable(.readOnlyRemoteSnapshot))
        }
    }

    @Test func localReopenOfSnapshotCacheFilePreservesReadOnlyOrigin() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let url = URL(fileURLWithPath: "/tmp/3a70fb49e7a91c2.md")
        let (opened, tabID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: url,
                associatedTerminalPaneID: t1.id,
                remoteResourceIdentity: remoteIdentity,
                in: session,
                now: Date()
            ))

        // Opening the same cache file through a local (nil-origin) path must not
        // strip the snapshot's read-only provenance and turn it writable.
        let (reopened, reopenedTabID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: url,
                associatedTerminalPaneID: t1.id,
                in: opened,
                now: Date()
            ))

        #expect(reopenedTabID == tabID)
        let group = try #require(reopened.layout.firstDocumentGroup)
        #expect(group.tab(id: tabID)?.remoteResourceIdentity == remoteIdentity)
        #expect(group.tab(id: tabID)?.title == "SKILL.md")
    }

    @Test func samePathOnLocalAndTwoHostsStaysDistinct() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let localURL = URL(fileURLWithPath: "/repo/README.md")
        let cacheURL = URL(fileURLWithPath: "/tmp/remote-cache.md")
        let hostA = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "host-a")!),
            path: ResourcePath(rawValue: "/repo/README.md")
        )
        let hostB = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "host-b")!),
            path: ResourcePath(rawValue: "/repo/README.md")
        )

        let (localOpened, localID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: localURL,
                associatedTerminalPaneID: t1.id,
                in: session,
                now: Date()
            ))
        let (hostAOpened, hostAID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: cacheURL,
                associatedTerminalPaneID: t1.id,
                remoteResourceIdentity: hostA,
                in: localOpened,
                now: Date()
            ))
        let (hostBOpened, hostBID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: cacheURL,
                associatedTerminalPaneID: t1.id,
                remoteResourceIdentity: hostB,
                in: hostAOpened,
                now: Date()
            ))

        #expect(Set([localID, hostAID, hostBID]).count == 3)
        #expect(hostBOpened.layout.firstDocumentGroup?.tabs.count == 3)
    }

    @Test func remoteSnapshotCannotBeReplacedInPlace() throws {
        let (session, t1, _) = makeTwoTerminalSession()
        let (opened, tabID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: "/tmp/cache.md"),
                associatedTerminalPaneID: t1.id,
                remoteResourceIdentity: remoteIdentity,
                in: session,
                now: Date()
            ))

        #expect(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: tabID,
                fileURL: URL(fileURLWithPath: "/tmp/local.md"),
                in: opened
            ) == nil)
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
        let reopenedTabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                in: focused.id,
                associationPolicy: .preserveNil
            )
        )

        let reopenedGroup = try #require(store.session(id: focused.id)?.layout.firstDocumentGroup)
        #expect(reopenedTabID == tabID)
        #expect(
            reopenedGroup.tab(id: tabID)?.associatedTerminalPaneID == nil,
            "document-to-document dedup with no safe source association must not heal nil to activePaneID"
        )
    }

}
