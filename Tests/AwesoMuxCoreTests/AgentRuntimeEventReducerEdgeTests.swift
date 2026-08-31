import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("AgentRuntimeEventReducer edge cases")
struct AgentRuntimeEventReducerEdgeTests {
    @Test("nil session leaves cleanup to prune and returns nil")
    func nilSessionPreservesState() {
        let paneID = UUID()
        var reducer = AgentRuntimeEventReducer()
        reducer.stateByPaneID[paneID] = AgentRuntimeEventReducer.RuntimeEventState()

        let decision = reducer.decision(
            for: AgentRuntimeEvent(source: .claudeCode, state: .thinking),
            currentSession: nil,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date()
        )
        #expect(decision == nil)
        #expect(reducer.stateByPaneID[paneID] != nil)
    }

    @Test(
        "shell session infers kind from source when event has no kind",
        arguments: [
            (AgentRuntimeSource.claudeCode, AgentKind.claudeCode),
            (.codex, .codex),
            (.openCode, .openCode),
            (.pi, .pi),
            (.grok, .grok)
        ]
    )
    func shellSessionInfersKind(source: AgentRuntimeSource, kind: AgentKind) {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        var reducer = AgentRuntimeEventReducer()

        let decision = reducer.decision(
            for: AgentRuntimeEvent(source: source, state: .thinking),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: false,
            now: Date()
        )
        #expect(decision != nil)
        #expect(decision?.update.agentKind == kind)
    }

    @Test("non-shell session preserves existing kind when event has no kind")
    func nonShellSessionPreservesKind() {
        let session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        var reducer = AgentRuntimeEventReducer()

        let decision = reducer.decision(
            for: AgentRuntimeEvent(source: .claudeCode, state: .thinking),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: false,
            now: Date()
        )
        #expect(decision != nil)
        #expect(decision?.update.agentKind == nil)
    }

    @Test("focused terminal suppresses unread delta even on attention transition")
    func focusedTerminalSuppressesUnread() {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        var reducer = AgentRuntimeEventReducer()

        let decision = reducer.decision(
            for: AgentRuntimeEvent(source: .claudeCode, attentionReason: .processError),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: true,
            now: Date()
        )
        #expect(decision != nil)
        #expect(decision?.update.unreadNotificationDelta == 0)
    }

    @Test("unfocused terminal gets unread delta on attention transition")
    func unfocusedTerminalGetsUnreadDelta() {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        var reducer = AgentRuntimeEventReducer()

        let decision = reducer.decision(
            for: AgentRuntimeEvent(source: .claudeCode, attentionReason: .processError),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: false,
            now: Date()
        )
        #expect(decision != nil)
        #expect(decision?.update.unreadNotificationDelta == 1)
    }

    @Test("recentEventIDs capacity overflow preserves most recent entries")
    func recentEventIDsCapacityOverflow() {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()
        let capacity = AgentRuntimeEventReducer.RuntimeEventState.recentEventIDCapacity

        for i in 0...capacity {
            _ = reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    state: .thinking,
                    eventID: "evt-\(i)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(i))
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: TimeInterval(i) + 1)
            )
        }

        let state = reducer.stateByPaneID[paneID]!
        #expect(state.recentEventIDs.count <= capacity)
        let lastKey = "evt-\(capacity)|\(TimeInterval(capacity))"
        #expect(state.recentEventIDs.contains(lastKey))
    }

    @Test("turn-end Stop rests on waiting: unfocused increments unread")
    func turnEndStopUnfocusedIncrementsUnread() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date()
        )
        let decision = try #require(result)
        #expect(decision.update.unreadNotificationDelta == 1)
        #expect(decision.update.attentionReason == nil)

        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: decision.update, now: Date())
        #expect(session.agentState == .waiting)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("prompt submit retires the unread badge a background turn-end raised")
    func promptSubmitClearsUnreadRaisedByBackgroundTurnEnd() throws {
        var session = TerminalSession(title: "opencode", workingDirectory: "~", agentKind: .openCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let stop = try #require(stopResult)
        #expect(stop.update.unreadNotificationDelta == 1)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: stop.update, now: Date(timeIntervalSince1970: 11)
        )
        #expect(session.unreadNotificationCount == 1)

        let submitResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "submit",
                timestamp: Date(timeIntervalSince1970: 20)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 21)
        )
        let submit = try #require(submitResult)
        #expect(submit.update.clearsUnreadNotifications)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: submit.update, now: Date(timeIntervalSince1970: 21)
        )
        #expect(session.unreadNotificationCount == 0)
        #expect(session.agentState == .thinking)
    }

    @Test("prompt submit authoritatively resolves a pending input-required reason")
    func promptSubmitAuthoritativelyClearsAwaitedAttentionReason() throws {
        var session = TerminalSession(title: "claude", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .userInputRequired,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == .userInputRequired)
        var reducer = AgentRuntimeEventReducer()

        let submitResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "submit",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 11)
        )
        let submit = try #require(submitResult)
        #expect(submit.update.attentionClearIsAuthoritative)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: submit.update, now: Date(timeIntervalSince1970: 11)
        )
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
    }

    @Test("nested session prompt submit preserves the parent's pending attention")
    func nestedSessionPromptSubmitPreservesParentAttention() throws {
        var session = TerminalSession(title: "claude", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .sessionStart,
                eventID: "parent-start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 2)
        )
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )

        let submitResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "child-submit",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 5)
        )
        let submit = try #require(submitResult)
        #expect(!submit.update.clearsUnreadNotifications)
        #expect(!submit.update.attentionClearIsAuthoritative)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: submit.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == .permissionPrompt)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("tool start authoritatively clears a pending permission prompt")
    func toolStartAuthoritativelyClearsPendingPermissionPrompt() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )
        #expect(session.attentionReason == .permissionPrompt)
        var reducer = AgentRuntimeEventReducer()

        let toolStartResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let toolStart = try #require(toolStartResult)
        #expect(toolStart.update.attentionClearIsAuthoritative)
        #expect(toolStart.update.clearsUnreadNotifications)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: toolStart.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.needsUserInput == false)
    }

    @Test("tool start clears a restored permission prompt before the session latch rebuilds")
    func toolStartClearsRestoredPermissionPromptWithoutSessionLatch() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start-after-restore",
                providerSessionID: "restored-session",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let decision = try #require(result)
        #expect(decision.update.attentionClearIsAuthoritative)
        #expect(decision.update.clearsUnreadNotifications)
    }

    @Test("tool start carrying attention preserves the blocking prompt")
    func toolStartCarryingAttentionPreservesBlockingPrompt() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                attentionReason: .permissionPrompt,
                phase: .toolStart,
                eventID: "tool-start-with-attention",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 5)
        )
        let decision = try #require(result)
        #expect(!decision.update.attentionClearIsAuthoritative)
        #expect(!decision.update.clearsUnreadNotifications)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: decision.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == .permissionPrompt)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("child tool start preserves a parent permission prompt")
    func childToolStartPreservesParentPermissionPrompt() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                kind: .codex,
                executionState: .thinking,
                phase: .sessionStart,
                eventID: "parent-session-start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 2)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 2)
        )
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )

        let childToolStartResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                kind: .codex,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "child-tool-start",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let childToolStart = try #require(childToolStartResult)
        #expect(!childToolStart.update.attentionClearIsAuthoritative)
        #expect(!childToolStart.update.clearsUnreadNotifications)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: childToolStart.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == .permissionPrompt)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("permission replied authoritatively clears a pending permission prompt")
    func permissionRepliedAuthoritativelyClearsPendingPermissionPrompt() throws {
        var session = TerminalSession(title: "opencode", workingDirectory: "~", agentKind: .openCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )
        var reducer = AgentRuntimeEventReducer()

        let repliedResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                phase: .permissionReplied,
                eventID: "permission-replied",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let replied = try #require(repliedResult)
        #expect(replied.update.attentionClearIsAuthoritative)
        #expect(replied.update.clearsUnreadNotifications)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: replied.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
    }

    @Test("permission reply from another provider session preserves the pending prompt")
    func permissionRepliedFromAnotherSessionPreservesPendingPrompt() throws {
        var session = TerminalSession(title: "opencode", workingDirectory: "~", agentKind: .openCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()
        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                executionState: .thinking,
                phase: .sessionStart,
                eventID: "parent-session-start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 2)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 2)
        )
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .permissionPrompt,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                phase: .permissionReplied,
                eventID: "child-permission-replied",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let decision = try #require(result)
        #expect(!decision.update.attentionClearIsAuthoritative)
        #expect(!decision.update.clearsUnreadNotifications)

        let toolStart = reducer.decision(
            for: AgentRuntimeEvent(
                source: .openCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "parent-tool-start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 3.999_999)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let toolStartDecision = try #require(toolStart)
        #expect(toolStartDecision.update.attentionClearIsAuthoritative)
        #expect(toolStartDecision.update.clearsUnreadNotifications)
    }

    @Test("tool start does not clear a pending user-input-required reason")
    func toolStartDoesNotClearPendingUserInputRequired() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                attentionReason: .userInputRequired,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 3)
        )
        var reducer = AgentRuntimeEventReducer()

        let toolStartResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 5)
        )
        let toolStart = try #require(toolStartResult)
        #expect(!toolStart.update.attentionClearIsAuthoritative)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: toolStart.update, now: Date(timeIntervalSince1970: 5)
        )
        #expect(session.attentionReason == .userInputRequired)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("only prompt submits claim the authoritative notification clear")
    func onlyPromptSubmitClaimsAuthoritativeClear() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .openCode)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(source: .openCode, executionState: .waiting, phase: .stop),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: false,
            now: Date()
        )
        let stop = try #require(stopResult)
        #expect(!stop.update.clearsUnreadNotifications)
        #expect(!stop.update.attentionClearIsAuthoritative)

        let toolEndResult = reducer.decision(
            for: AgentRuntimeEvent(source: .openCode, executionState: .thinking, phase: .toolEnd),
            currentSession: session,
            paneID: session.activePaneID,
            terminalIsFocused: false,
            now: Date()
        )
        let toolEnd = try #require(toolEndResult)
        #expect(!toolEnd.update.clearsUnreadNotifications)
        #expect(!toolEnd.update.attentionClearIsAuthoritative)
    }

    @Test("Grok subagent stop with a different session id is dropped")
    func grokSubagentStopWithDifferentSessionIDIsDropped() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let start = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(start != nil)

        let childStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "child-stop",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        #expect(childStop == nil)

        let parentStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "parent-stop",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 14)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )
        let decision = try #require(parentStop)
        #expect(decision.update.agentKind == .grok)
        #expect(decision.update.agentExecutionState == .waiting)
        #expect(decision.update.unreadNotificationDelta == 1)
    }

    @Test("Grok prompt submit can establish the parent session id when start was missed")
    func grokPromptSubmitCanEstablishParentSessionID() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let promptSubmit = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "prompt-submit",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let promptDecision = try #require(promptSubmit)
        #expect(promptDecision.update.agentKind == .grok)
        #expect(promptDecision.update.agentExecutionState == .thinking)

        let childStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "child-stop",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        #expect(childStop == nil)
    }

    @Test("Grok current session id filtering keeps child Stop from driving parent state")
    func grokCurrentSessionIDFilteringDropsChildStop() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let promptSubmit = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "current-prompt-submit",
                providerSessionID: "current-session-id",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(promptSubmit != nil)

        let childStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "child-stop",
                providerSessionID: "child-session-id",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        #expect(childStop == nil)
    }

    @Test("Grok child session start with a different id is dropped")
    func grokChildSessionStartWithDifferentIDIsDropped() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let start = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "parent-start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(start != nil)

        let childStart = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "child-start",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        #expect(childStart == nil)

        let parentStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "parent-stop",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 14)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )
        let decision = try #require(parentStop)
        #expect(decision.update.agentKind == .grok)
        #expect(decision.update.agentExecutionState == .waiting)
    }

    @Test("Grok session start without an id does not clear a latched parent id")
    func grokSessionStartWithoutIDDoesNotClearLatchedParentID() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-without-id",
                providerSessionID: nil,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )

        let childStop = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .waiting,
                phase: .stop,
                eventID: "child-stop",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 14)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )
        #expect(childStop == nil)
    }

    @Test("Grok child lifecycle event with a different session id is dropped")
    func grokChildLifecycleEventWithDifferentSessionIDIsDropped() throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start",
                providerSessionID: "parent",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )

        let childToolStart = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "child-tool-start",
                providerSessionID: "child",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        #expect(childToolStart == nil)
    }

    @Test("turn-end Stop rests on waiting: focused suppresses unread")
    func turnEndStopFocusedSuppressesUnread() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date()
        )
        let decision = try #require(result)
        #expect(decision.update.unreadNotificationDelta == 0)
        #expect(decision.update.attentionReason == nil)

        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: decision.update, now: Date())
        #expect(session.agentState == .waiting)
        #expect(session.unreadNotificationCount == 0)
    }

    @Test("after turn-end, the next prompt retires the waiting unread")
    func turnEndUnreadClearsOnNextPrompt() throws {
        // This test once pinned the opposite contract — unread surviving until
        // an explicit acknowledgement — because Claude Code's keystroke path
        // already cleared `.needsAttention` panes before the event landed. For
        // providers whose turn-ends rest on quiet `.waiting` (OpenCode, Codex,
        // Pi) that left the badge with no clear path at all, so prompt
        // submissions became authoritative acknowledgements; see the
        // `answersPendingNotifications` gate in the reducer.
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let stop = try #require(stopResult)
        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: stop.update, now: Date())
        #expect(session.agentState == .waiting)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 1)

        let promptResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "prompt",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 13)
        )
        let prompt = try #require(promptResult)
        #expect(prompt.update.clearsUnreadNotifications)
        #expect(prompt.update.attentionClearIsAuthoritative)

        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: prompt.update, now: Date())
        #expect(session.agentExecutionState == .thinking)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.agentState == .thinking)
    }

    @Test("session exit resets the tile to quiet shell: idle, no attention, no agent kind")
    func sessionEndResetsToShell() throws {
        // Agent finished a turn and is waiting with an unread badge.
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentExecutionState: .waiting,
                unreadNotificationDelta: 1
            ),
            now: Date(timeIntervalSince1970: 0)
        )
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 20)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 21)
        )
        let decision = try #require(result)
        #expect(decision.update.clearsAttention)
        #expect(decision.update.clearsUnreadNotifications)
        #expect(decision.update.agentKind == .shell)

        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: decision.update, now: Date())
        #expect(session.agentState == .idle)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.agentKind == .shell)
    }

    @Test("session exit applies even when its timestamp is not newer than a recent event")
    func sessionEndBypassesStalenessGuard() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        // A turn-end Stop lands first at t=10.
        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )

        // SessionEnd with an equal/older timestamp must still apply — exit is terminal.
        let endResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let end = try #require(endResult)
        #expect(end.update.clearsAttention)
        #expect(end.update.agentKind == .shell)
    }

    @Test("a delayed end from a stopped lifecycle cannot reset a newer lifecycle without session ids")
    func delayedSessionEndDoesNotResetNewerLifecycleWithoutSessionIDs() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        for event in [
            AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "old-start",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .pi,
                executionState: .waiting,
                phase: .stop,
                eventID: "old-stop",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "new-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            let result = reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 20)
            )
            #expect(result != nil)
        }

        let delayedEnd = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "old-end",
                timestamp: Date(timeIntervalSince1970: 13)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(delayedEnd == nil)
    }

    @Test("provider session ids reject an old end after a stopped pane starts a new lifecycle")
    func providerSessionIDRejectsDelayedOldEnd() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .grok)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        for event in [
            AgentRuntimeEvent(
                source: .grok,
                executionState: .idle,
                phase: .sessionStart,
                providerSessionID: "old-session",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .grok,
                executionState: .waiting,
                phase: .stop,
                providerSessionID: "old-session",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .grok,
                executionState: .idle,
                phase: .sessionStart,
                providerSessionID: "new-session",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            let result = reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 20)
            )
            #expect(result != nil)
        }

        let delayedEnd = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                executionState: .idle,
                phase: .sessionEnd,
                providerSessionID: "old-session"
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(delayedEnd == nil)
    }

    @Test("a clock-skewed lifecycle start does not roll the ordering watermark backward")
    func clockSkewedLifecycleStartPreservesTimestampWatermark() {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .waiting,
                phase: .stop,
                timestamp: Date(timeIntervalSince1970: 100)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 200)
        )
        #expect(reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionStart,
                timestamp: Date(timeIntervalSince1970: 90)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 200)
        ) != nil)

        let staleTool = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .thinking,
                phase: .toolStart,
                timestamp: Date(timeIntervalSince1970: 95)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(staleTool == nil)
    }

    @Test("missing timestamps still preserve a newer lifecycle and its own end after Stop")
    func missingTimestampsUseLifecycleOrdering() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        for event in [
            AgentRuntimeEvent(source: .pi, executionState: .idle, phase: .sessionStart),
            AgentRuntimeEvent(source: .pi, executionState: .waiting, phase: .stop),
            AgentRuntimeEvent(source: .pi, executionState: .idle, phase: .sessionStart),
        ] {
            #expect(reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 20)
            ) != nil)
        }

        #expect(reducer.decision(
            for: AgentRuntimeEvent(source: .pi, executionState: .idle, phase: .sessionEnd),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 20)
        ) == nil)

        #expect(reducer.decision(
            for: AgentRuntimeEvent(source: .pi, executionState: .waiting, phase: .stop),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 20)
        ) != nil)

        let currentEnd = reducer.decision(
            for: AgentRuntimeEvent(source: .pi, executionState: .idle, phase: .sessionEnd),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 20)
        )
        #expect(currentEnd?.update.agentKind == .shell)
        #expect(currentEnd?.update.clearsAttention == true)
    }

    @Test("a late Stop buffered behind exit cannot reapply status or resurrect the agent glyph")
    func lateStopAfterSessionEndIsSuppressed() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .pi)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let endResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: try #require(endResult).update, now: Date())
        #expect(session.agentKind == .shell)

        // A higher-timestamped Stop arrives after exit: it must not reapply waiting,
        // add unread, or re-infer the Pi kind on the now-shell session.
        let lateStopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .waiting,
                phase: .stop,
                eventID: "late-stop",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        let lateStop = try #require(lateStopResult)
        #expect(lateStop.update.agentExecutionState == nil)
        #expect(lateStop.update.attentionReason == nil)
        #expect(lateStop.update.agentKind == nil)
        #expect(lateStop.update.unreadNotificationDelta == 0)

        _ = WorkspaceAttentionReducer.updatePane(&session, paneID: paneID, update: lateStop.update, now: Date())
        #expect(session.agentState == .idle)
        #expect(session.agentKind == .shell)
    }

    @Test("a fresh session start after exit lifts the post-exit suppression latch")
    func sessionStartAfterEndLiftsLatch() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )

        // New session starts: the pane should infer the Pi kind again from source.
        let startResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        let start = try #require(startResult)
        #expect(start.update.agentKind == .pi)

        // And a subsequent turn-end waiting event is honored again, proving the latch lifted.
        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .pi,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 14)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )
        let stop = try #require(stopResult)
        #expect(stop.update.agentExecutionState == .waiting)
        #expect(stop.update.attentionReason == nil)
        #expect(stop.update.unreadNotificationDelta == 1)
    }

    @Test("remove clears state for pane")
    func removeClearsPaneState() {
        let paneID = UUID()
        var reducer = AgentRuntimeEventReducer()
        reducer.stateByPaneID[paneID] = AgentRuntimeEventReducer.RuntimeEventState()
        #expect(reducer.stateByPaneID[paneID] != nil)

        reducer.remove(paneID: paneID)
        #expect(reducer.stateByPaneID[paneID] == nil)
    }

    @Test("prune removes state for dead panes")
    func pruneRemovesDeadPaneState() {
        let livePane = UUID()
        let deadPane = UUID()
        var reducer = AgentRuntimeEventReducer()
        reducer.stateByPaneID[livePane] = AgentRuntimeEventReducer.RuntimeEventState()
        reducer.stateByPaneID[deadPane] = AgentRuntimeEventReducer.RuntimeEventState()

        reducer.prune(livePaneIDs: [livePane])
        #expect(reducer.stateByPaneID[livePane] != nil)
        #expect(reducer.stateByPaneID[deadPane] == nil)
    }

    @Test("a tool that ends after the turn does not downgrade waiting")
    func trailingToolEndAfterStopKeepsWaiting() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 10)
        )
        let stop = try #require(stopResult)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: stop.update, now: Date(timeIntervalSince1970: 10))
        #expect(session.agentState == .waiting)

        // A background Bash task or a subagent finishing after the turn ended.
        let trailingResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "trailing",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        let trailing = try #require(trailingResult)
        #expect(trailing.update.agentExecutionState == nil)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: trailing.update, now: Date(timeIntervalSince1970: 12))
        #expect(session.agentState == .waiting)
    }

    @Test("work that starts after the turn still downgrades waiting")
    func toolStartAfterStopDowngradesWaiting() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 10)
        )
        // Required, not discarded: if this Stop were ever dropped the pane would
        // never reach `.waiting`, the flag would never arm, and every assertion
        // below would pass while testing nothing.
        let stop = try #require(stopResult)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: stop.update, now: Date(timeIntervalSince1970: 10))
        #expect(session.agentState == .waiting)

        let startResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 11)
        )
        let start = try #require(startResult)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: start.update, now: Date(timeIntervalSince1970: 11))
        #expect(session.agentState == .thinking)

        // The continuation's own toolEnd is in-turn again, so it applies.
        let endResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        #expect(try #require(endResult).update.agentExecutionState == .thinking)
    }

    @Test("a new prompt re-arms the turn so its own tool events apply")
    func promptSubmitAfterStopClearsBetweenTurns() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stop = try #require(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .waiting,
                    phase: .stop,
                    eventID: "stop",
                    timestamp: Date(timeIntervalSince1970: 10)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: true,
                now: Date(timeIntervalSince1970: 10)
            ) as AgentRuntimeEventReducer.Decision?)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: stop.update, now: Date(timeIntervalSince1970: 10))
        #expect(session.agentState == .waiting)

        let submitResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "submit",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 11)
        )
        let submit = try #require(submitResult)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: submit.update, now: Date(timeIntervalSince1970: 11))

        let endResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "end",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        let end = try #require(endResult)
        #expect(end.update.agentExecutionState == .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: end.update, now: Date(timeIntervalSince1970: 12))
        #expect(session.agentState == .thinking)
    }

    @Test("a restored waiting pane is between turns before the reducer sees a stop")
    func restoredWaitingPaneSeedsBetweenTurns() throws {
        // The reducer's state is rebuilt empty on relaunch, but the pane's
        // `.waiting` survives — a job that outlived the quit must not downgrade it.
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        var reducer = AgentRuntimeEventReducer()

        let trailingResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "trailing",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        let trailing = try #require(trailingResult)
        #expect(trailing.update.agentExecutionState == nil)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: trailing.update, now: Date(timeIntervalSince1970: 12))
        #expect(session.agentState == .waiting)
    }

    @Test("an idle-prompt notification arms the turn boundary like a stop")
    func waitingNotificationArmsBetweenTurns() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let notice = try #require(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .waiting,
                    phase: .notification,
                    eventID: "idle",
                    timestamp: Date(timeIntervalSince1970: 10)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: true,
                now: Date(timeIntervalSince1970: 10)
            ) as AgentRuntimeEventReducer.Decision?)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: notice.update, now: Date(timeIntervalSince1970: 10))
        #expect(session.agentState == .waiting)

        let trailingResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "trailing",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(try #require(trailingResult).update.agentExecutionState == nil)
    }

    @Test("a blocking prompt on a between-turns tool end still reaches the pane")
    func betweenTurnsToolEndKeepsItsAttentionReason() throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        var reducer = AgentRuntimeEventReducer()

        // No bundled provider pairs these today, but the event file is a
        // documented protocol: a real blocking prompt must not be swallowed.
        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                attentionReason: .permissionPrompt,
                phase: .toolEnd,
                eventID: "prompt",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        let decision = try #require(result)
        #expect(decision.update.agentExecutionState == nil)
        #expect(decision.update.attentionReason == .permissionPrompt)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: decision.update, now: Date(timeIntervalSince1970: 12))
        #expect(session.agentState == .needsAttention)
    }

    @Test("a between-turns tool end still records the file it touched")
    func betweenTurnsToolEndStillRecordsTouchedPath() throws {
        // Issue #175's recent-link recording is deliberately outside the
        // suppression: a background subagent's Markdown write still reaches the
        // palette even though its execution claim is ignored.
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "touched",
                touchedPath: "/tmp/notes.md",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        let decision = try #require(result)
        #expect(decision.update.agentExecutionState == nil)
        #expect(decision.recentLinkAction == .record("/tmp/notes.md"))
    }

    @Test("a file-writing tool end does not strand a turn that starts microseconds earlier")
    func suppressedToolEndWithTouchedPathDoesNotBlockAToolStart() throws {
        // Every background file write produces a suppressed toolEnd carrying a
        // touchedPath. If that raised the staleness bar, a `.toolStart` sampled
        // microseconds earlier (hook events are appended by independent
        // processes, ~0.6% invert) would be dropped, `isBetweenTurns` would
        // never clear, and the pane would read `.waiting` for a whole working
        // turn with the send bar armed (review finding).
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        var reducer = AgentRuntimeEventReducer()

        let write = try #require(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .thinking,
                    phase: .toolEnd,
                    eventID: "write",
                    touchedPath: "/tmp/notes.md",
                    timestamp: Date(timeIntervalSince1970: 20)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: true,
                now: Date(timeIntervalSince1970: 20)
            ) as AgentRuntimeEventReducer.Decision?)
        #expect(write.update.agentExecutionState == nil)
        #expect(write.recentLinkAction == .record("/tmp/notes.md"))

        // Sampled a hair earlier, appended after — must still re-arm the turn.
        let startResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "start",
                timestamp: Date(timeIntervalSince1970: 19.999_999)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 20)
        )
        let start = try #require(startResult)
        #expect(start.update.agentExecutionState == .thinking)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: start.update, now: Date(timeIntervalSince1970: 20))
        #expect(session.agentState == .thinking)
    }

    @Test("a suppressed tool end does not strand the turn by advancing the watermark")
    func suppressedToolEndDoesNotBlockALaterToolStart() throws {
        // Hook events are appended by independent short-lived processes, so
        // timestamp order can invert against append order by microseconds. An
        // ignored event must not raise the bar its own disarming toolStart clears.
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .waiting)
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "trailing",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )

        // Sampled a hair earlier than the ignored event, appended after it.
        let startResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "start",
                timestamp: Date(timeIntervalSince1970: 11.999_999)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )
        #expect(try #require(startResult).update.agentExecutionState == .thinking)
    }

    /// Seeds a pane's resting execution state. Post INT-504 agent state lives on
    /// the pane and `TerminalSession.agentExecutionState` is a derived, get-only
    /// rollup, so the prior direct assignment is routed through `updatePane`.
    private func seedExecutionState(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID,
        _ state: AgentExecutionState
    ) {
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(agentExecutionState: state),
            now: Date(timeIntervalSince1970: 0)
        )
    }
}
