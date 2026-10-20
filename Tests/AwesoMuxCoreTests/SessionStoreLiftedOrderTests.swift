import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

/// Arrival order for the Needs Input section: first to ask sits at the top, new
/// arrivals append at the bottom, and nothing already in the section ever moves.
/// Group order would let a new arrival insert ABOVE an existing row and shove it
/// down under the user's pointer — the displacement class this section exists to
/// avoid.
@MainActor
@Suite struct SessionStoreLiftedOrderTests {
    /// A store whose selection sits on an untouched calm anchor, so no test here
    /// arms the selection dwell or captures a sticky by accident.
    private func makeStore(
        groupOne: [TerminalSession],
        groupTwo: [TerminalSession] = []
    ) -> (store: SessionStore, anchor: TerminalSession) {
        let anchor = TerminalSession(title: "anchor", workingDirectory: "~")
        var groups = [SessionGroup(name: "One", sessions: [anchor] + groupOne)]
        if !groupTwo.isEmpty {
            groups.append(SessionGroup(name: "Two", sessions: groupTwo))
        }
        let store = SessionStore(groups: groups)
        store.needsInputSectionEnabled = true
        return (store, anchor)
    }

    /// Raises a permission prompt on a workspace's active pane — the real
    /// producer path, so this exercises the same commit the app does.
    private func askForInput(_ store: SessionStore, _ id: TerminalSession.ID) throws {
        let paneID = try #require(store.session(id: id)?.activePaneID)
        store.updatePermissionPromptAttention(
            sessionID: id,
            paneID: paneID,
            countDelta: 1,
            hasPending: true
        )
    }

    /// Claude Code hook shapes, hand-built the way
    /// `WaitingAnnouncementRuntimeEventTests` does: `AgentHookEventMapper` owns
    /// the hook-name-to-shape mapping and its own suite pins it, so this suite
    /// asserts only what Core does with each shape once it arrives.
    private func claudeEvent(
        executionState: AgentExecutionState?,
        phase: AgentRuntimePhase,
        at timestamp: Date = Date(),
        providerSessionID: String? = nil
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .claudeCode,
            executionState: executionState,
            phase: phase,
            eventID: UUID().uuidString,
            providerSessionID: providerSessionID,
            timestamp: timestamp
        )
    }

    /// `idle_prompt`: the only mapping asserting `.waiting` on a notification.
    private func idlePrompt(
        at timestamp: Date = Date(),
        providerSessionID: String? = nil
    ) -> AgentRuntimeEvent {
        claudeEvent(
            executionState: .waiting,
            phase: .notification,
            at: timestamp,
            providerSessionID: providerSessionID
        )
    }

    /// A nested same-kind agent — `claude` run as a tool call inside a Claude
    /// Code pane — inherits the pane's event file and submits its own prompts
    /// through it. The reducer accepts them, so a pane-only mark would let the
    /// child's first prompt answer the parent's turn on the parent's behalf.
    /// Permanently: `idle_prompt` fires at most once per turn.
    @Test(arguments: [false, true])
    func aNestedSessionsPromptDoesNotAnswerTheParentsTurn(ownPrompt: Bool) throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha])
        let paneID = try #require(store.session(id: alpha.id)?.activePaneID)
        let parent = UUID().uuidString
        let child = UUID().uuidString
        let base = Date()

        #expect(
            store.applyAgentRuntimeEvent(
                idlePrompt(at: base, providerSessionID: parent),
                to: alpha.id,
                paneID: paneID
            ))
        #expect(store.liftedSessionIDs == [alpha.id])

        let applied = store.applyAgentRuntimeEvent(
            claudeEvent(
                executionState: .thinking,
                phase: .promptSubmit,
                at: base.addingTimeInterval(1),
                providerSessionID: ownPrompt ? parent.lowercased() : child
            ),
            to: alpha.id,
            paneID: paneID
        )

        if ownPrompt { #expect(applied) }
        #expect(store.liftedSessionIDs == (ownPrompt ? [] : [alpha.id]))
    }

    @Test func pinningALiftedWorkspaceRemovesItFromTheSection() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta])

        try askForInput(store, alpha.id)
        try askForInput(store, beta.id)
        #expect(store.liftedSessionIDs == [alpha.id, beta.id])

        store.togglePin(sessionID: alpha.id)
        #expect(store.liftedSessionIDs == [beta.id])

        // Unpinning re-enters the section as a fresh arrival: it appends.
        store.togglePin(sessionID: alpha.id)
        #expect(store.liftedSessionIDs == [beta.id, alpha.id])
    }

    @Test func closingAWorkspaceDropsItFromTheOrder() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta])

        try askForInput(store, beta.id)
        try askForInput(store, alpha.id)
        #expect(store.liftedSessionIDs == [beta.id, alpha.id])

        store.closeSession(id: beta.id)
        #expect(store.liftedSessionIDs == [alpha.id])
    }

    enum Event: CaseIterable, Sendable {
        case idlePrompt, stop, submit, toolStart, acknowledgeAll, jump, acknowledge, reset, deadProcess, sessionEnd
    }

    @Test("unanswered turns lift until answered or made unanswerable", arguments: Event.allCases)
    func liftLifecycle(event: Event) throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha], groupTwo: [beta])
        let paneID = alpha.activePaneID
        let base = Date()
        if event != .stop {
            #expect(store.applyAgentRuntimeEvent(idlePrompt(at: base), to: alpha.id, paneID: paneID))
            #expect(store.liftedSessionIDs == [alpha.id])
        }
        switch event {
        case .idlePrompt:
            #expect(store.session(id: alpha.id)?.agentRollup().state == .waiting)
            #expect(store.session(id: alpha.id)?.needsAcknowledgement == false)
            #expect(store.session(id: alpha.id)?.unreadNotificationCount == 0)
        case .stop, .submit, .toolStart, .sessionEnd:
            let phase: AgentRuntimePhase
            let state: AgentExecutionState
            switch event {
            case .stop: phase = .stop; state = .waiting
            case .submit: phase = .promptSubmit; state = .thinking
            case .toolStart: phase = .toolStart; state = .thinking
            default: phase = .sessionEnd; state = .idle
            }
            let applied = store.applyAgentRuntimeEvent(
                claudeEvent(executionState: state, phase: phase, at: base.addingTimeInterval(1)), to: alpha.id, paneID: paneID)
            if event != .toolStart { #expect(applied) }
            if event == .stop { #expect(store.session(id: alpha.id)?.agentRollup().state == .waiting) }
        case .acknowledgeAll:
            #expect(store.applyAgentRuntimeEvent(idlePrompt(), to: beta.id, paneID: beta.activePaneID))
            #expect(store.liftedSessionIDs.count == 2)
            store.acknowledgeAllSessions()
        case .jump:
            store.acknowledgeSession(id: alpha.id, answersUnansweredTurn: false)
        case .acknowledge:
            store.acknowledgeSession(id: alpha.id)
        case .reset:
            #expect(store.resetPaneAgentChromeToShell(sessionID: alpha.id, paneID: paneID))
        case .deadProcess:
            #expect(store.recordPaneProcessError(in: alpha.id, paneID: paneID, terminalIsFocused: false))
        }
        let lifted = event == .idlePrompt || event == .toolStart || event == .jump
        #expect(store.liftedSessionIDs == (lifted ? [alpha.id] : []))
        #expect(store.unansweredTurnPaneIDs == (lifted ? [paneID] : []))
    }
}
