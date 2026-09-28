import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore bridge process errors")
struct SessionStoreBridgeProcessErrorTests {
    @Test("records bridge loss as a pane error, not generic attention")
    func recordsBridgeLossAsPaneError() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let pane = store.selectedSession?.layout.pane(id: session.activePaneID)
        #expect(recorded)
        #expect(pane?.agentExecutionState == .error)
        #expect(pane?.attentionReason == nil)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("focused bridge loss does not bump unread")
    func focusedBridgeLossDoesNotBumpUnread() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    /// A dead process cannot answer the prompt it raised, so the error record has
    /// to retract it. Without an authoritative clear the reason survives the
    /// `awaitsExplicitAnswer` guard, the pane resolves to `.needsAttention`
    /// instead of `.error`, and the workspace paints peach — holding a Needs
    /// Input slot for a prompt nobody can answer and hiding the recovery hint.
    @Test("bridge loss retracts the prompt the dead process can no longer answer")
    func bridgeLossRetractsPendingPrompt() {
        var session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .running
        )
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        let pane = store.selectedSession?.layout.pane(id: session.activePaneID)
        #expect(recorded)
        #expect(pane?.attentionReason == nil)
        #expect(pane?.agentExecutionState == .error)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.needsUserInput == false)
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}

@MainActor
@Suite("SessionStore sibling pane exit errors")
struct SessionStoreSiblingPaneExitErrorTests {
    @Test("increments unread count when terminal is unfocused")
    func incrementsUnreadCountWhenUnfocused() {
        let session = makeSession(state: .running, unreadNotificationCount: 2)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.unreadNotificationCount == 3)
        // Pins the latent fix: the app-wide total must follow the per-session
        // bump. The pre-extraction monolith updated the session count but left
        // `unreadNotificationTotal` stale until the next structural rebuild.
        #expect(store.unreadNotificationTotal == 3)
    }

    @Test("records the exit error on the exiting pane before it is removed")
    func recordsExitErrorOnExitingPaneBeforeRemoval() {
        // M2 (INT-504 review): pane B exits non-zero in a 2-pane split. The exit
        // handler now RECORDS the error on B while it is still in the layout,
        // BEFORE closePane removes it (record-before-removal, maintainer decision) — the
        // prior close-first ordering no-oped because the dead pane was already
        // gone. The badge lands on the correct (exiting) pane and never on the
        // innocent survivor A.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
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
            activePaneID: paneB.id
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

    @Test("badges the exiting pane when it is still held in the layout")
    func badgesExitingPaneWhenStillPresent() {
        // Forward-compat with INT-506: when the exiting pane is still in the
        // layout (a held-dead pane), the error attaches to IT, never a sibling.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
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
            activePaneID: paneA.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason == .processError
        )
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

    private func makeSession(
        state: AgentState,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: state,
            unreadNotificationCount: unreadNotificationCount
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
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
        #expect(store.groups == originalGroups)
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

        #expect(store.provisionallyRestore(entry, daemonID: daemonID) == nil)
        #expect(store.groups == originalGroups)
        #expect(store.recentlyClosed == [entry])
    }

    @Test("abandoned daemon recovery commits and can roll back")
    func abandonedDaemonRecovery() throws {
        let existing = TerminalSession(title: "existing", workingDirectory: "/tmp")
        let originalGroups = [SessionGroup(name: "main", sessions: [existing])]
        let store = SessionStore(groups: originalGroups, selectedSessionID: existing.id)
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
        #expect(store.groups == originalGroups)
        #expect(store.selectedSessionID == existing.id)
    }

    @Test("recovery rollback preserves a newer valid selection")
    func recoveryRollbackPreservesNewerSelection() throws {
        let first = TerminalSession(title: "first", workingDirectory: "/tmp")
        let second = TerminalSession(title: "second", workingDirectory: "/tmp")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [first, second])],
            selectedSessionID: first.id
        )
        let recovery = try #require(
            store.recoverDaemon(
                id: .generate(),
                metadata: DaemonRecoveryMetadata(
                    workspaceTitle: "Build", paneTitle: "Codex", groupID: nil,
                    groupName: "Recovered", groupRemote: nil, agentKind: .codex
                ),
                cwd: "/tmp"
            ))
        store.selectedSessionID = second.id

        store.rollbackDaemonRecovery(recovery)

        #expect(store.selectedSessionID == second.id)
    }

    @Test("amx metadata fails closed for unknown payloads")
    func amxAttachDisposition() {
        #expect(TerminalBackendMetadata.empty.amxAttachDisposition == .createOrAttach)
        #expect(
            TerminalBackendMetadata(rawValue: "amx:v1:established").amxAttachDisposition
                == .createOrAttach)
        #expect(
            TerminalBackendMetadata(rawValue: "amx:v1:existing-only").amxAttachDisposition
                == .existingOnly)
        #expect(
            TerminalBackendMetadata(rawValue: "amx:v99:surprise").amxAttachDisposition
                == .existingOnly)
    }

}
