import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("AgentRuntimeEventReducer edge cases")
struct AgentRuntimeEventReducerEdgeTests {
    @Test("nil session clears state and returns nil")
    func nilSessionClearsState() {
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
        #expect(reducer.stateByPaneID[paneID] == nil)
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

    @Test("after turn-end, next prompt leaves waiting unread until acknowledgement")
    func turnEndUnreadClearsOnAcknowledgeNotNextPrompt() throws {
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
        #expect(prompt.update.clearsAttention == false)

        // The prompt decision was only inspected, not applied, so the session still
        // carries Stop's resting executionState (.waiting) and unread marker.
        #expect(session.agentExecutionState == .waiting)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 1)

        _ = WorkspaceAttentionReducer.acknowledgePane(&session, paneID: paneID)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.agentState == .waiting)
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
