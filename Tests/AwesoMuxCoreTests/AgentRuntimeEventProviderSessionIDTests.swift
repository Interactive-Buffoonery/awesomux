import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("Provider session id trust boundary and latch")
struct AgentRuntimeEventProviderSessionIDTests {
    private static let sessionA = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private static let sessionB = "9a8b7c6d-5e4f-4321-9876-543210fedcba"

    // MARK: - sessionEnd superseded guard

    /// The regression this guard exists for: once every provider reports a
    /// session id, a buffered SessionEnd from the OLD session must not reset the
    /// live one.
    @Test("a stale sessionEnd carrying a different session id is dropped")
    func staleSessionEndWithMismatchedSessionIDIsDropped() {
        var context = Self.supersededLifecycle()
        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: Self.sessionA
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionB)
    }

    @Test("a sessionEnd carrying the live session id applies")
    func sessionEndWithMatchingSessionIDApplies() {
        var context = Self.supersededLifecycle()
        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-new",
                providerSessionID: Self.sessionB
            )
        )

        #expect(decision?.update.agentKind == .shell)
        #expect(decision?.update.clearsAttention == true)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == true)
    }

    @Test("a stale sessionEnd carrying no session id is dropped")
    func sessionEndWithoutSessionIDIsDropped() {
        var context = Self.supersededLifecycle()
        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-anonymous"
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
    }

    @Test("a stale sessionEnd is dropped when the pane never latched a session id")
    func sessionEndIsDroppedWithoutALatchedSessionID() {
        var context = Self.supersededLifecycle(sessionIDs: false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == nil)

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: Self.sessionA
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
    }

    /// The `.supersededStopped` hole: gating the identity check on
    /// "superseded AND not currently stopped" meant the live session's own
    /// turn-end Stop switched the check off again, and the next stale end
    /// reset a session that is very much alive.
    @Test("a stale sessionEnd is still dropped after the live session's turn-end Stop")
    func staleSessionEndIsDroppedAfterTheLiveSessionStops() {
        var context = Self.supersededLifecycle()
        #expect(
            context.apply(
                AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .waiting,
                    phase: .stop,
                    eventID: "stop-b",
                    providerSessionID: Self.sessionB,
                    timestamp: Date(timeIntervalSince1970: 13)
                )
            ) != nil)

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 14)
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionB)
    }

    /// Same hole, reached the way a user does: the superseding session takes
    /// another turn, so the stale end lands while it is genuinely mid-work.
    @Test("a stale sessionEnd cannot reset the live session mid-turn")
    func staleSessionEndCannotResetTheLiveSessionMidTurn() {
        var context = Self.supersededLifecycle()
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop-b",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 13)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "prompt-b",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 14)
            ),
        ] {
            #expect(context.apply(event) != nil)
        }

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 15)
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
    }

    /// A same-kind nested child (`claude -p` inside a Bash tool call) exits
    /// while the parent is mid-turn. Its id disagrees with the latch, which is
    /// proof enough on its own — this pane's lifecycle was never superseded.
    @Test("a nested same-kind child's sessionEnd does not reset the parent")
    func nestedChildSessionEndDoesNotResetTheParent() {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-parent",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            #expect(context.apply(event) != nil)
        }

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-child",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 12)
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)
    }

    // MARK: - Latch

    /// A reordered/nested same-kind SessionStart arriving mid-turn must not
    /// move the latch: only a tool call can spawn one, and the pane's real
    /// agent is still working.
    @Test("a same-kind SessionStart mid-turn does not steal the latch")
    func sameKindSessionStartMidTurnDoesNotStealTheLatch() {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-parent",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-child",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
        ] {
            _ = context.apply(event)
        }

        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)
    }

    /// The counterpart, and the answer to the unclean-death case: between
    /// turns the same event IS a genuine handoff — a `/clear`-style restart,
    /// or a fresh agent started after the previous one was killed without
    /// writing Stop or SessionEnd — so the latch must follow it. Otherwise the
    /// transcript surface resolves the DEAD session and Resume stages its id.
    /// The lifecycle here is still `.active` (only an idle-prompt notification
    /// has landed), so nothing but `isBetweenTurns` can authorize the handoff.
    @Test("a same-kind SessionStart between turns takes the latch")
    func sameKindSessionStartBetweenTurnsTakesTheLatch() {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .notification,
                eventID: "idle-prompt",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-new",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
        ] {
            _ = context.apply(event)
        }

        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionB)
    }

    /// The other half of the unclean-death case. `kill -9` / crash / sleep
    /// writes no Stop and no SessionEnd, so `AgentLivenessPolicy` synthesizes
    /// one from the process table — `source: .unknown`, no session id. It is
    /// the one end that provably cannot be stale, so the proven-mismatch drop
    /// above must never catch it: if it did, the dead id would stay latched
    /// and Resume would stage it beside whatever runs in the pane next.
    @Test("an app-synthesized end from process liveness clears the latch")
    func synthesizedLivenessEndClearsTheLatch() {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-dead",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            #expect(context.apply(event) != nil)
        }
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)

        let decision = context.apply(
            AgentRuntimeEvent(source: .unknown, executionState: .idle, phase: .sessionEnd)
        )

        #expect(decision?.update.agentKind == .shell)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == true)
    }

    @Test(
        "session id latches at sessionStart and clears at sessionEnd",
        arguments: [
            (AgentRuntimeSource.claudeCode, AgentKind.claudeCode),
            (.codex, .codex),
            (.grok, .grok),
        ]
    )
    func sessionIDLatchesAndClears(source: AgentRuntimeSource, kind: AgentKind) {
        var context = Context(agentKind: kind)
        _ = context.apply(
            AgentRuntimeEvent(
                source: source,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            )
        )
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)

        _ = context.apply(
            AgentRuntimeEvent(
                source: source,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 11)
            )
        )
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == nil)
    }

    @Test("a prompt submit latches the session id when SessionStart was missed")
    func promptSubmitLatchesSessionIDAfterMissedSessionStart() {
        var context = Context(agentKind: .codex)
        _ = context.apply(
            AgentRuntimeEvent(
                source: .codex,
                executionState: .thinking,
                phase: .promptSubmit,
                eventID: "prompt",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            )
        )

        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)
    }

    /// Without the pre-latch clear, the transcript surface would resolve the
    /// PREVIOUS session for a brand-new agent that has not reported an id yet.
    @Test("a new lifecycle without a session id clears the previous one")
    func newLifecycleWithoutSessionIDClearsPreviousLatch() {
        var context = Context(agentKind: .claudeCode)
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            )
        )
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop-old",
                timestamp: Date(timeIntervalSince1970: 11)
            )
        )
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-new",
                timestamp: Date(timeIntervalSince1970: 12)
            )
        )

        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == nil)
    }

    // MARK: - Ingress validation

    @Test(
        "a hostile session id is stripped without dropping the event it rides on",
        arguments: [
            "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d\nrm -rf ~",
            "../../../tmp/evil",
            String(repeating: "a", count: 512),
            "not-a-uuid",
            "",
        ]
    )
    func hostileSessionIDIsStrippedFromParsedEvent(rawSessionID: String) throws {
        let event = try #require(
            AgentRuntimeEvent.parse(data: Self.line(providerSessionID: rawSessionID))
        )

        #expect(event.providerSessionID == nil)
        #expect(event.phase == .sessionStart)
        #expect(event.executionState == .idle)
        #expect(event.source == .claudeCode)
    }

    @Test("a UUID session id survives parsing")
    func uuidSessionIDSurvivesParsing() throws {
        let event = try #require(
            AgentRuntimeEvent.parse(data: Self.line(providerSessionID: Self.sessionA))
        )

        #expect(event.providerSessionID == Self.sessionA)
        #expect(event.phase == .sessionStart)
    }

    @Test("a wrong-typed session id strips the field instead of dropping the event")
    func wrongTypedSessionIDStripsTheField() throws {
        let event = try #require(
            AgentRuntimeEvent.parse(data: Self.line(providerSessionID: 42))
        )

        #expect(event.providerSessionID == nil)
        #expect(event.phase == .sessionStart)
    }

    /// Grok's id format is unverified, so it keeps its pre-existing pass-through
    /// (single token only) rather than gaining a UUID requirement that could
    /// silently disable its child-agent drop rule.
    @Test("a non-UUID grok session id is preserved")
    func grokSessionIDIsNotShapeChecked() throws {
        let event = try #require(
            AgentRuntimeEvent.parse(
                data: Self.line(source: "grok", providerSessionID: "grok-parent")
            )
        )

        #expect(event.providerSessionID == "grok-parent")
    }

    @Test("a whitespace-bearing grok session id is stripped")
    func hostileGrokSessionIDIsStripped() throws {
        let event = try #require(
            AgentRuntimeEvent.parse(
                data: Self.line(source: "grok", providerSessionID: "parent\nrm -rf ~")
            )
        )

        #expect(event.providerSessionID == nil)
        #expect(event.phase == .sessionStart)
    }

    // MARK: - Helpers

    private static func line(source: String = "claude-code", providerSessionID: Any) -> Data {
        let payload: [String: Any] = [
            "v": AgentRuntimeEvent.supportedVersion,
            "source": source,
            "execution": "idle",
            "phase": "sessionStart",
            "eventID": "e1",
            "providerSessionID": providerSessionID,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// A pane whose lifecycle is superseded-but-not-stopped: session A started,
    /// stopped, and session B started on top of it. This is the exact state the
    /// `sessionEnd` guard arbitrates.
    private static func supersededLifecycle(sessionIDs: Bool = true) -> Context {
        var context = Context(agentKind: .claudeCode)
        for (index, event) in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-a",
                providerSessionID: sessionIDs ? sessionA : nil,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop-a",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-b",
                providerSessionID: sessionIDs ? sessionB : nil,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
        ].enumerated() {
            #expect(context.apply(event) != nil, "setup event \(index) was dropped")
        }
        return context
    }

    private struct Context {
        let session: TerminalSession
        var reducer = AgentRuntimeEventReducer()

        var paneID: TerminalPane.ID { session.activePaneID }

        init(agentKind: AgentKind) {
            session = TerminalSession(
                title: "agent", workingDirectory: "~", agentKind: agentKind
            )
        }

        mutating func apply(_ event: AgentRuntimeEvent) -> AgentRuntimeEventReducer.Decision? {
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 100)
            )
        }
    }
}
