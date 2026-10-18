import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore sibling pane exit errors")
struct SessionStoreSiblingPaneExitErrorTests {

    @Test("exit errors stay on their pane and update unread totals", arguments: [(true, 0), (true, 2), (false, 0)])
    func recordsExitErrorOnExitingPaneBeforeRemoval(exitingIsActive: Bool, unread: Int) {
        // M2 (INT-504 review): pane B exits non-zero in a 2-pane split. The exit
        // handler now RECORDS the error on B while it is still in the layout,
        // BEFORE closePane removes it (record-before-removal, maintainer decision) — the
        // prior close-first ordering no-oped because the dead pane was already
        // gone. The badge lands on the correct (exiting) pane and never on the
        // innocent survivor A.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            unreadNotificationCount: unread, executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(paneA),
                    second: .pane(paneB)
                )),
            activePaneID: exitingIsActive ? paneB.id : paneA.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        // Record FIRST, while B is still present (mirrors the corrected
        // exit-handler ordering: record before the dead pane is removed).
        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.session(id: session.id)?.unreadNotificationCount == unread + 1)
        #expect(store.unreadNotificationTotal == unread + 1)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason
                == .processError
        )
        // The survivor is never badged.
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)

        // Then closePane removes B and collapses the split onto A.
        _ = store.closePane(id: paneB.id, in: session.id)
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

}

@MainActor
@Suite("SessionStore terminal backend metadata")
struct SessionStoreTerminalBackendMetadataTests {
    @Test("provisional restore keeps recovery entry and marks every pane existing-only")
    func provisionalRestoreIsNonDestructiveAndExistingOnly() throws {
        let first = TerminalPane(
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "amx:v1:established"),
            title: "first", workingDirectory: "/tmp", executionPlan: .local
        )
        let second = TerminalPane(
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "amx:v1:established"),
            title: "second", workingDirectory: "/tmp", executionPlan: .local
        )
        let sessionID = UUID()
        let groupID = UUID()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(first), second: .pane(second)
            ))
        let entry = RecentlyClosedWorkspace(
            sessionID: sessionID, title: "restored", isTitleUserEdited: true,
            agentKind: .shell, layout: layout, activePaneID: first.id,
            groupID: groupID, groupName: "work", groupRemote: nil,
            indexInGroup: 0, closedAt: Date()
        )
        let existing = TerminalSession(title: "existing", workingDirectory: "/tmp")
        let originalGroups = [SessionGroup(name: "main", sessions: [existing])]
        let store = SessionStore(
            groups: originalGroups,
            selectedSessionID: existing.id,
            recentlyClosed: [entry]
        )
        let initialGroups = store.groups

        let restored = try #require(
            store.provisionallyRestore(
                entry, daemonID: first.terminalSessionID
            ))
        let panes = try #require(store.session(id: restored.sessionID)?.panes)

        #expect(store.recentlyClosed == [entry])
        #expect(panes.count == 2)
        #expect(panes.allSatisfy { $0.terminalBackendMetadata.amxAttachDisposition == .existingOnly })

        store.rollbackDaemonRecovery(restored)
        #expect(store.session(id: restored.sessionID) == nil)
        #expect(store.recentlyClosed == [entry])
        #expect(store.groups == initialGroups)
        #expect(store.selectedSessionID == existing.id)
    }

    @Test("stale rollback cannot remove a later reopen with the same session ID")
    func staleRollbackPreservesLaterReopen() throws {
        let pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(), title: "restored", isTitleUserEdited: true,
            agentKind: .shell, layout: .pane(pane), activePaneID: pane.id,
            groupID: UUID(), groupName: "work", groupRemote: nil,
            indexInGroup: 0, closedAt: Date()
        )
        let store = SessionStore(recentlyClosed: [entry])
        let recovery = try #require(
            store.provisionallyRestore(entry, daemonID: pane.terminalSessionID)
        )

        store.closeSession(id: recovery.sessionID)
        let reopened = try #require(store.reopen(entry))
        #expect(!store.completeDaemonRecovery(recovery))
        store.rollbackDaemonRecovery(recovery)

        #expect(store.session(id: reopened) != nil)
    }

    @Test("mismatched daemon cannot partially restore a workspace")
    func mismatchedDaemonDoesNotMutateStore() {
        let pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(), title: "restored", isTitleUserEdited: true,
            agentKind: .shell, layout: .pane(pane), activePaneID: pane.id,
            groupID: UUID(), groupName: "work", groupRemote: nil,
            indexInGroup: 0, closedAt: Date()
        )
        let store = SessionStore(recentlyClosed: [entry])

        #expect(store.provisionallyRestore(entry, daemonID: .generate()) == nil)
        #expect(store.groups.isEmpty)
        #expect(store.recentlyClosed == [entry])
    }

    @Test("daemon identity collision cannot partially publish a provisional restore")
    func daemonIdentityCollisionDoesNotMutateStore() {
        let daemonID = TerminalSessionID.generate()
        let existing = TerminalSession(
            title: "existing", workingDirectory: "/tmp",
            layout: .pane(
                TerminalPane(
                    terminalSessionID: daemonID, title: "live", workingDirectory: "/tmp",
                    executionPlan: .local
                ))
        )
        let entryPane = TerminalPane(
            terminalSessionID: daemonID, title: "closed", workingDirectory: "/tmp",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(), title: "restored", isTitleUserEdited: true,
            agentKind: .shell, layout: .pane(entryPane), activePaneID: entryPane.id,
            groupID: UUID(), groupName: "work", groupRemote: nil,
            indexInGroup: 0, closedAt: Date()
        )
        let originalGroups = [SessionGroup(name: "main", sessions: [existing])]
        let store = SessionStore(groups: originalGroups, recentlyClosed: [entry])
        let initialGroups = store.groups

        #expect(store.provisionallyRestore(entry, daemonID: daemonID) == nil)
        #expect(store.groups == initialGroups)
        #expect(store.recentlyClosed == [entry])
    }

    @Test("abandoned daemon recovery commits and can roll back")
    func abandonedDaemonRecovery() throws {
        let existing = TerminalSession(title: "existing", workingDirectory: "/tmp")
        let originalGroups = [SessionGroup(name: "main", sessions: [existing])]
        let store = SessionStore(groups: originalGroups, selectedSessionID: existing.id)
        let initialGroups = store.groups
        let daemonID = TerminalSessionID.generate()
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "Build", paneTitle: "Codex", groupID: nil,
            groupName: "Recovered", groupRemote: nil, agentKind: .codex
        )

        let recovery = try #require(
            store.recoverDaemon(id: daemonID, metadata: metadata, cwd: NSHomeDirectory())
        )

        #expect(store.selectedSessionID == recovery.sessionID)
        #expect(store.session(id: recovery.sessionID)?.activePaneID == recovery.paneID)
        store.rollbackDaemonRecovery(recovery)
        #expect(store.groups == initialGroups)
        #expect(store.selectedSessionID == existing.id)
    }


    @Test(
        "amx metadata fails closed for unknown payloads",
        arguments: [
            ("", AmxAttachDisposition.createOrAttach),
            ("amx:v1:established", .createOrAttach),
            ("amx:v1:existing-only", .existingOnly),
            ("amx:v99:surprise", .existingOnly),
        ])
    func amxAttachDisposition(payload: String, expected: AmxAttachDisposition) {
        #expect(TerminalBackendMetadata(rawValue: payload).amxAttachDisposition == expected)
    }

}
