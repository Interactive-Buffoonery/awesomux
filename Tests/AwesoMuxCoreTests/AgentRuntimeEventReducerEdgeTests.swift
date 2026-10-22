import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("AgentRuntimeEventReducer edge cases")
struct AgentRuntimeEventReducerEdgeTests {
    @Test(arguments: [AgentKind.openCode, .claudeCode])
    func promptSubmitClearsUnreadRaisedByBackgroundTurnEnd(kind: AgentKind) throws {
        var session = TerminalSession(title: "opencode", workingDirectory: "~", agentKind: kind)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        let stopResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: kind == .openCode ? .openCode : .claudeCode,
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
                source: kind == .openCode ? .openCode : .claudeCode,
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

    @Test("an older tool end preserves a newer permission prompt")
    func olderToolEndPreservesNewerPermissionPrompt() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()

        for (eventID, timestamp) in [("background-tool", 1.0), ("prompted-tool", 2.0)] {
            _ = reducer.decision(
                for: AgentRuntimeEvent(
                    source: .codex,
                    executionState: .thinking,
                    phase: .toolStart,
                    eventID: eventID,
                    timestamp: Date(timeIntervalSince1970: timestamp)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: timestamp)
            )
        }

        let promptResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                attentionReason: .permissionPrompt,
                phase: .notification,
                eventID: "prompted-tool",
                timestamp: Date(timeIntervalSince1970: 3)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 3)
        )
        let prompt = try #require(promptResult)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: prompt.update, now: Date(timeIntervalSince1970: 3)
        )

        let backgroundEndResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                phase: .toolEnd,
                eventID: "background-tool",
                timestamp: Date(timeIntervalSince1970: 4)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 4)
        )
        let backgroundEnd = try #require(backgroundEndResult)
        #expect(!backgroundEnd.update.attentionClearIsAuthoritative)
        #expect(!backgroundEnd.update.clearsUnreadNotifications)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: backgroundEnd.update, now: Date(timeIntervalSince1970: 4)
        )
        #expect(session.attentionReason == .permissionPrompt)
        #expect(session.unreadNotificationCount == 1)
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

    @Test("late permission request is suppressed after a recent answer attempt")
    func latePermissionRequestIsSuppressedAfterRecentAnswerAttempt() throws {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, .thinking)
        var reducer = AgentRuntimeEventReducer()
        reducer.recordPermissionAnswerAttempt(
            paneID: paneID,
            now: Date(timeIntervalSince1970: 5)
        )

        let permissionResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                attentionReason: .permissionPrompt,
                phase: .notification,
                eventID: "late-permission",
                timestamp: Date(timeIntervalSince1970: 6)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 6)
        )
        let permission = try #require(permissionResult)
        #expect(permission.update.attentionReason == nil)
        #expect(permission.update.unreadNotificationDelta == 0)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: permission.update, now: Date(timeIntervalSince1970: 6)
        )
        #expect(session.attentionReason == nil)
        #expect(session.needsUserInput == false)

        let nextPermissionResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .codex,
                attentionReason: .permissionPrompt,
                phase: .notification,
                eventID: "next-permission",
                timestamp: Date(timeIntervalSince1970: 6.5)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 6.5)
        )
        let nextPermission = try #require(nextPermissionResult)
        #expect(nextPermission.update.attentionReason == .permissionPrompt)
        #expect(nextPermission.update.unreadNotificationDelta == 1)
    }

    @Test(arguments: [AgentRuntimePhase.sessionStart, .promptSubmit])
    func grokSubagentStopWithDifferentSessionIDIsDropped(firstPhase: AgentRuntimePhase) throws {
        let session = TerminalSession(title: "grok", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let start = reducer.decision(
            for: AgentRuntimeEvent(
                source: .grok,
                kind: .grok,
                executionState: firstPhase == .sessionStart ? .idle : .thinking,
                phase: firstPhase,
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

    @Test("trailing tool ends preserve waiting after a stop or restore", arguments: [false, true])
    func trailingToolEndAfterStopKeepsWaiting(restored: Bool) throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        seedExecutionState(&session, paneID: paneID, restored ? .waiting : .thinking)
        var reducer = AgentRuntimeEventReducer()

        if !restored {
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
        }

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

    @Test(arguments: [nil, "/tmp/notes.md"] as [String?])
    func suppressedToolEndDoesNotBlockALaterToolStart(touchedPath: String?) throws {
        // Hook events are appended by independent short-lived processes, so
        // timestamp order can invert against append order by microseconds. An
        // ignored event must not raise the bar its own disarming toolStart clears.
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
                touchedPath: touchedPath,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: true,
            now: Date(timeIntervalSince1970: 12)
        )

        let trailing = try #require(trailingResult)
        #expect(trailing.update.agentExecutionState == nil)
        if let touchedPath {
            #expect(trailing.recentLinkAction == .record(touchedPath))
        }

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

    @Test(arguments: [
        (true, 0, false), (false, 1, false),
        (true, 0, true), (false, 1, true),
    ])
    func focusControlsUnread(focused: Bool, expectedDelta: Int, turnEnd: Bool) throws {
        var session = TerminalSession(title: "agent", workingDirectory: "~", agentKind: turnEnd ? .claudeCode : .shell)
        let paneID = session.activePaneID
        if turnEnd { seedExecutionState(&session, paneID: paneID, .thinking) }
        var reducer = AgentRuntimeEventReducer()
        let event =
            turnEnd
            ? AgentRuntimeEvent(source: .claudeCode, executionState: .waiting, phase: .stop)
            : AgentRuntimeEvent(source: .claudeCode, attentionReason: .processError)
        let result = reducer.decision(
            for: event, currentSession: session, paneID: paneID,
            terminalIsFocused: focused, now: Date(timeIntervalSince1970: 10)
        )
        let decision = try #require(result)
        #expect(decision.update.unreadNotificationDelta == expectedDelta)
        if turnEnd {
            #expect(decision.update.attentionReason == nil)
            _ = WorkspaceAttentionReducer.updatePane(
                &session, paneID: paneID, update: decision.update, now: Date(timeIntervalSince1970: 10))
            #expect(session.agentState == .waiting)
            #expect(session.attentionReason == nil)
            #expect(session.unreadNotificationCount == expectedDelta)
        }
    }
}
