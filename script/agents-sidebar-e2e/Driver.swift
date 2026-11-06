import AwesoMuxCore
import AwesoMuxBridgeProtocol
import Foundation

@main
struct AgentsSidebarScenarios {
    @MainActor static func main() {
        let permission = UUID(), question = UUID(), waiting = UUID(), finished = UUID(), failed = UUID(), shell = UUID()
        let session = UUID()
        func snapshot(
            _ id: UUID, _ execution: AgentExecutionState, _ reason: AttentionReason? = nil, unread: Int = 0, kind: AgentKind = .claudeCode
        ) -> PaneAgentSnapshot {
            PaneAgentSnapshot(
                paneID: id, agentKind: kind, state: AgentDisplayState(executionState: execution, attentionReason: reason), unread: unread,
                needsAcknowledgement: reason != nil, attentionReason: reason, executionState: execution)
        }
        let roster = AgentActivityRoster.build([
            .init(
                sessionID: session,
                panes: [
                    snapshot(permission, .waiting, .permissionPrompt), snapshot(question, .waiting, .userInputRequired),
                    snapshot(waiting, .waiting, unread: 1), snapshot(finished, .done, unread: 1),
                    snapshot(failed, .error, .processError), snapshot(shell, .idle, kind: .shell),
                ])
        ])
        precondition(AgentActivityRoster.actionablePaneIDs(sessions: []) == [])
        let rows = roster.rows
        precondition(rows.count == 5 && !rows.contains { $0.paneID == shell })
        precondition(rows.first { $0.paneID == permission }?.section == .needsYou)
        precondition(rows.first { $0.paneID == question }?.attentionReason == .userInputRequired)
        precondition(rows.first { $0.paneID == waiting }?.section == .settled)
        precondition(rows.first { $0.paneID == waiting }?.executionState == .waiting)
        precondition(rows.first { $0.paneID == finished }?.section == .settled)
        precondition(rows.first { $0.paneID == failed }?.section == .needsYou)
        precondition(roster.nextNeedingAttention(after: permission, orderedPaneIDs: [question, permission, failed])?.paneID == failed)
        precondition(roster.nextNeedingAttention(after: UUID(), orderedPaneIDs: [question, permission, failed])?.paneID == question)
        precondition(AgentActivityRoster.build([]).nextNeedingAttention(after: nil, orderedPaneIDs: []) == nil)
        let unknown = AgentActivityRoster.build([.init(sessionID: session, panes: [snapshot(UUID(), .running, .unknown)])]).rows[0]
        precondition(unknown.section == .needsYou && unknown.detail == "Needs your attention")
        let genericQuestion = rows.first { $0.paneID == question }!
        precondition(genericQuestion.detail == "Needs your attention")
        let denied = AgentActivityRoster.build([.init(sessionID: session, panes: [snapshot(UUID(), .error)])]).rows[0]
        precondition(denied.detail == "Error")
        let staleDone = AgentActivityRoster.build([.init(sessionID: session, panes: [snapshot(UUID(), .done, .bell)])]).rows[0]
        precondition(staleDone.section == .settled && staleDone.detail == "Finished")
        let shellAttention = snapshot(shell, .idle, .bell, kind: .shell)
        precondition(AgentActivityRoster.build([.init(sessionID: session, panes: [shellAttention])], includingShells: true).rows.count == 1)
        let untaggedPrompt = snapshot(shell, .waiting, .permissionPrompt, kind: .shell)
        precondition(AgentActivityRoster.build([.init(sessionID: session, panes: [untaggedPrompt])]).rows.count == 1)
        print("PASS: pane-grain sections, conservative waiting, neutral notifications, shell exclusion and live next-target projection")

        var workspace = TerminalSession(title: "My custom task", workingDirectory: "/tmp")
        workspace.layout = workspace.layout.mappingPanes { pane in
            var pane = pane
            pane.agentKind = .claudeCode
            pane.agentExecutionState = .waiting
            pane.attentionReason = .permissionPrompt
            pane.unreadNotificationCount = 2
            return pane
        }
        for kind in [AgentKind.shell, .claudeCode] {
            for execution in [AgentExecutionState.idle, .running, .thinking, .output, .waiting, .done, .error] {
                for reason in [nil, .permissionPrompt, .userInputRequired, .unknown, .processError, .bell] as [AttentionReason?] {
                    var candidate = workspace
                    candidate.layout = candidate.layout.mappingPanes { pane in
                        var pane = pane
                        pane.agentKind = kind
                        pane.agentExecutionState = execution
                        pane.attentionReason = reason
                        return pane
                    }
                    let expected = AgentActivityRoster.build(sessions: [candidate]).rows.filter { $0.section == .needsYou }.map(\.paneID)
                    precondition(AgentActivityRoster.actionablePaneIDs(sessions: [candidate]) == expected)
                }
            }
        }
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [workspace])])
        precondition(AgentActivityRoster.actionablePaneIDs(sessions: [workspace]) == [workspace.activePaneID])
        let paneID = workspace.activePaneID
        store.selectedSessionID = workspace.id
        store.setActivePane(id: paneID, in: workspace.id)
        precondition(store.session(id: workspace.id)?.activePane?.attentionReason == .permissionPrompt)
        store.markPaneSeen(sessionID: workspace.id, paneID: paneID)
        precondition(store.session(id: workspace.id)?.activePane?.attentionReason == .permissionPrompt)
        precondition(store.session(id: workspace.id)?.unreadNotificationCount == 0)
        precondition(store.actionableAgentPaneIDs.contains(paneID))
        precondition(store.session(id: workspace.id)?.title == "My custom task")
        store.markPaneSeen(sessionID: UUID(), paneID: UUID())
        precondition(store.actionableAgentPaneIDs.contains(paneID))
        store.markWorkspaceSeen(id: workspace.id)
        precondition(store.session(id: workspace.id)?.activePane?.attentionReason == .permissionPrompt)
        let order = store.actionableAgentPaneIDs
        store.renameSession(id: workspace.id, title: "Renamed task")
        precondition(store.actionableAgentPaneIDs == order)
        store.selectedSessionID = workspace.id
        precondition(store.actionableAgentPaneIDs == order)
        store.markAgentActivityObserved(id: workspace.id, paneID: paneID)
        precondition(store.actionableAgentPaneIDs == order)
        _ = store.splitActivePane(orientation: .vertical, in: workspace.id)
        guard let movedID = store.movePaneToNewWorkspace(id: paneID, in: workspace.id) else {
            preconditionFailure("Expected a split agent pane to move")
        }
        store.markPaneSeen(sessionID: workspace.id, paneID: paneID)
        precondition(store.session(id: movedID)?.layout.pane(id: paneID)?.attentionReason == .permissionPrompt)
        precondition(store.sessionIDContainingPane(paneID) == movedID)
        store.dismissAgentAttentionReminder(paneID: paneID)
        precondition(
            store.session(id: movedID)?.layout.pane(id: paneID)?.attentionReason == .permissionPrompt,
            "A live or unverified explicit request cannot be dismissed as a reminder")
        store.acknowledgeAllSessions()
        precondition(store.session(id: movedID)?.layout.pane(id: paneID)?.attentionReason == nil)
        precondition(!store.actionableAgentPaneIDs.contains(paneID))
        store.closeSession(id: movedID, captureRecentlyClosed: false)
        precondition(store.sessionIDContainingPane(paneID) == nil)
        store.markPaneSeen(sessionID: movedID, paneID: paneID)
        let bridgeWorkspace = TerminalSession(title: "Bridge", workingDirectory: "/tmp", agentKind: .claudeCode)
        let bridgeStore = SessionStore(groups: [SessionGroup(name: "Bridge", sessions: [bridgeWorkspace])])
        let bridgePaneID = bridgeWorkspace.activePaneID
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: 1, hasPending: true)
        bridgeStore.markPaneSeen(sessionID: bridgeWorkspace.id, paneID: bridgePaneID)
        bridgeStore.markSessionNeedsAttention(id: bridgeWorkspace.id, paneID: bridgePaneID)
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: -1, hasPending: false)
        precondition(
            bridgeStore.session(id: bridgeWorkspace.id)?.unreadNotificationCount == 1,
            "A seen permission must not debit a newer notification")
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: 1, hasPending: true)
        bridgeStore.markPaneSeen(sessionID: bridgeWorkspace.id, paneID: bridgePaneID)
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: 1, hasPending: true)
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: -1, hasPending: true)
        precondition(
            bridgeStore.session(id: bridgeWorkspace.id)?.unreadNotificationCount == 1,
            "An older seen prompt must not consume a newer prompt's unread unit")
        bridgeStore.updatePermissionPromptAttention(sessionID: bridgeWorkspace.id, paneID: bridgePaneID, countDelta: -1, hasPending: false)
        precondition(bridgeStore.session(id: bridgeWorkspace.id)?.unreadNotificationCount == 0)
        let mixed = TerminalSession(title: "Mixed", workingDirectory: "/tmp", agentKind: .claudeCode)
        let mixedStore = SessionStore(groups: [SessionGroup(name: "Mixed", sessions: [mixed])])
        _ = mixedStore.splitActivePane(orientation: .vertical, in: mixed.id)
        let mixedIDs = mixedStore.session(id: mixed.id)!.panes.map(\.id)
        precondition(mixedIDs.count == 2)
        mixedStore.updatePermissionPromptAttention(sessionID: mixed.id, paneID: mixedIDs[0], countDelta: 2, hasPending: true)
        mixedStore.markSessionNeedsAttention(id: mixed.id, paneID: mixedIDs[1])
        let mixedTotal = mixedStore.session(id: mixed.id)!.unreadNotificationCount
        precondition(mixedTotal >= 3 && mixedStore.unreadNotificationTotal == mixedTotal)
        mixedStore.markWorkspaceSeen(id: mixed.id)
        precondition(mixedStore.unreadNotificationTotal == 0)
        precondition(mixedStore.session(id: mixed.id)!.unreadNotificationCount == 0)
        precondition(mixedStore.session(id: mixed.id)!.layout.pane(id: mixedIDs[0])!.attentionReason == .permissionPrompt)
        precondition(!mixedStore.canMarkWorkspaceSeen(id: mixed.id))
        mixedStore.markWorkspaceSeen(id: mixed.id)
        precondition(mixedStore.unreadNotificationTotal == 0)
        mixedStore.markSessionNeedsAttention(id: mixed.id, paneID: mixedIDs[1])
        mixedStore.updatePermissionPromptAttention(sessionID: mixed.id, paneID: mixedIDs[0], countDelta: -2, hasPending: false)
        precondition(mixedStore.unreadNotificationTotal == 1)
        precondition(mixedStore.session(id: mixed.id)!.unreadNotificationCount == 1)
        mixedStore.acknowledgeAllSessions()
        precondition(mixedStore.unreadNotificationTotal == 0)
        precondition(mixedStore.session(id: mixed.id)!.panes.allSatisfy { $0.attentionReason == nil })
        let reviewWorkspace = TerminalSession(title: "Turn to review", workingDirectory: "/tmp", agentKind: .claudeCode)
        let reviewStore = SessionStore(groups: [SessionGroup(name: "Review", sessions: [reviewWorkspace])])
        reviewStore.needsInputSectionEnabled = true
        for (execution, phase) in [(AgentExecutionState.thinking, AgentRuntimePhase.sessionStart), (.waiting, .notification)] {
            reviewStore.applyAgentRuntimeEvent(
                .init(
                    source: .claudeCode, executionState: execution, phase: phase, eventID: UUID().uuidString,
                    providerSessionID: "fixture-review-turn", timestamp: Date()), to: reviewWorkspace.id,
                paneID: reviewWorkspace.activePaneID)
        }
        precondition(reviewStore.unansweredTurnPaneIDs.contains(reviewWorkspace.activePaneID))
        precondition(
            reviewStore.canMarkWorkspaceSeen(id: reviewWorkspace.id),
            "Turn-review-only reminders must enable every workspace mark-seen entry point")
        let reviewRoster = AgentActivityRoster.build(
            sessions: reviewStore.groups.flatMap(\.sessions), unansweredTurnPaneIDs: reviewStore.unansweredTurnPaneIDs)
        precondition(reviewRoster.rows.first?.section == .settled)
        precondition(reviewStore.actionableAgentPaneIDs.isEmpty)
        precondition(reviewRoster.nextNeedingAttention(after: nil, orderedPaneIDs: []) == nil)
        reviewStore.markWorkspaceSeen(id: reviewWorkspace.id)
        precondition(
            !reviewStore.unansweredTurnPaneIDs.contains(reviewWorkspace.activePaneID),
            "An explicit mark-seen must clear a nonblocking turn-review reminder")
        precondition(!reviewStore.canMarkWorkspaceSeen(id: reviewWorkspace.id))
        print("PASS: navigation/seen preserve requests, heartbeat ordering, moved ownership, explicit dismissal and closed targets")
    }
}
