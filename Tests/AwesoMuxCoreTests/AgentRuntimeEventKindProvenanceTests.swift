import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

/// Kind provenance: a pane's `agentKind` set from scraped viewport text is a
/// guess and must yield to the pane's own runtime-event stream; a kind proven
/// by that stream must not be overruled by another provider's events (nested
/// child processes share the pane's event file).
///
/// Regression context: a stray "claude code" string in an OpenCode pane's
/// scrollback tagged the pane `.claudeCode` while it was still `.shell`, and
/// the cross-kind guard then rejected every genuine OpenCode event forever —
/// the wrong glyph survived process lifetime and app relaunch (persisted).
@Suite("AgentRuntimeEventKindProvenance")
struct AgentRuntimeEventKindProvenanceTests {
    private func session(
        agentKind: AgentKind,
        agentKindIsRuntimeEstablished: Bool
    ) -> TerminalSession {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: "~",
            agentKind: agentKind,
            agentKindIsRuntimeEstablished: agentKindIsRuntimeEstablished,
            executionPlan: .local
        )
        return TerminalSession(
            title: "session",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
    }

    private func openCodeEvent(
        phase: AgentRuntimePhase,
        eventID: String,
        timestamp: Date
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .openCode,
            kind: .openCode,
            executionState: .thinking,
            phase: phase,
            eventID: eventID,
            timestamp: timestamp
        )
    }

    private func claudeCodeEvent(
        phase: AgentRuntimePhase,
        eventID: String,
        timestamp: Date
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .claudeCode,
            kind: .claudeCode,
            executionState: .thinking,
            phase: phase,
            eventID: eventID,
            timestamp: timestamp
        )
    }

    @Test("a text-guessed kind yields to another provider's prompt submit")
    func textGuessedKindYieldsToPromptSubmit() throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        // #require cannot wrap a mutating call; capture the optional first.
        let reclaimed = reducer.decision(
            for: openCodeEvent(
                phase: .promptSubmit,
                eventID: "reclaim",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let decision = try #require(reclaimed)
        #expect(decision.update.agentKind == .openCode)
        #expect(decision.update.agentKindIsRuntimeEstablished == true)
    }

    @Test("a foreign prompt submit cannot steal a mid-turn text-guessed pane")
    func foreignPromptSubmitDoesNotReclaimMidTurn() throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        // The guessed provider's own prompt proves the pane is genuinely
        // mid-turn, so a nested child of another provider must not reclaim it.
        let parentTurn = reducer.decision(
            for: claudeCodeEvent(
                phase: .promptSubmit,
                eventID: "parent-turn",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        _ = try #require(parentTurn)

        #expect(
            reducer.decision(
                for: openCodeEvent(
                    phase: .promptSubmit,
                    eventID: "child-steal",
                    timestamp: Date(timeIntervalSince1970: 12)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 13)
            ) == nil,
            "a foreign prompt submit mid-turn must stay rejected over a text-guessed kind"
        )
    }

    @Test("a stopped text-guessed pane still yields to another provider")
    func stoppedTextGuessedKindStillYields() throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        // A finished turn is not a live one: once the guessed provider stops
        // between turns, the reclaim path stays open for a genuine handoff.
        let earlierTurn = reducer.decision(
            for: claudeCodeEvent(
                phase: .promptSubmit,
                eventID: "earlier-turn",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        _ = try #require(earlierTurn)
        let turnEnd = reducer.decision(
            for: claudeCodeEvent(
                phase: .stop,
                eventID: "turn-end",
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        _ = try #require(turnEnd)

        let reclaimed = reducer.decision(
            for: openCodeEvent(
                phase: .promptSubmit,
                eventID: "handoff",
                timestamp: Date(timeIntervalSince1970: 14)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )
        let handoff = try #require(reclaimed)
        #expect(handoff.update.agentKind == .openCode)
    }

    @Test("a text-guessed kind yields to another provider's session start")
    func textGuessedKindYieldsToSessionStart() throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let restarted = reducer.decision(
            for: openCodeEvent(
                phase: .sessionStart,
                eventID: "restart",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        let decision = try #require(restarted)

        #expect(decision.update.agentKind == .openCode)
    }

    @Test("foreign tool chatter cannot steal a text-guessed pane mid-turn")
    func foreignToolChatterDoesNotReclaim() {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        #expect(
            reducer.decision(
                for: openCodeEvent(
                    phase: .toolStart,
                    eventID: "chatter",
                    timestamp: Date(timeIntervalSince1970: 10)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) == nil
        )
    }

    @Test("a runtime-proven kind still rejects another provider's identity boundary")
    func runtimeProvenKindRejectsOtherProvider() {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: true)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        for phase in [AgentRuntimePhase.sessionStart, .promptSubmit] {
            #expect(
                reducer.decision(
                    for: openCodeEvent(
                        phase: phase,
                        eventID: "nested-\(phase.rawValue)",
                        timestamp: Date(timeIntervalSince1970: 10)
                    ),
                    currentSession: session,
                    paneID: paneID,
                    terminalIsFocused: false,
                    now: Date(timeIntervalSince1970: 11)
                ) == nil,
                "different-kind \(phase.rawValue) must stay rejected over a hook-proven kind"
            )
        }
    }

    @Test("same-kind events establish provenance through the attention reducer")
    func sameKindRuntimeEventEstablishesProvenance() throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var mutable = session

        _ = WorkspaceAttentionReducer.updatePane(
            &mutable,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: .claudeCode,
                agentKindIsRuntimeEstablished: true,
                agentExecutionState: .thinking
            ),
            now: Date(timeIntervalSince1970: 1)
        )

        let pane = try #require(mutable.layout.pane(id: paneID))
        #expect(pane.agentKind == .claudeCode)
        #expect(pane.agentKindIsRuntimeEstablished)
    }

    @Test("text re-detecting the same kind does not clear runtime proof")
    func textSameKindKeepsProvenance() throws {
        let session = session(agentKind: .codex, agentKindIsRuntimeEstablished: true)
        let paneID = session.activePaneID
        var mutable = session

        _ = WorkspaceAttentionReducer.updatePane(
            &mutable,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: .codex,
                agentKindIsRuntimeEstablished: false
            ),
            now: Date(timeIntervalSince1970: 1)
        )

        let pane = try #require(mutable.layout.pane(id: paneID))
        #expect(pane.agentKindIsRuntimeEstablished)
    }

    @Test("a text claim overwriting the kind downgrades provenance")
    func textDifferentKindDowngradesProvenance() throws {
        let session = session(agentKind: .codex, agentKindIsRuntimeEstablished: true)
        let paneID = session.activePaneID
        var mutable = session

        _ = WorkspaceAttentionReducer.updatePane(
            &mutable,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: .claudeCode,
                agentKindIsRuntimeEstablished: false
            ),
            now: Date(timeIntervalSince1970: 1)
        )

        let pane = try #require(mutable.layout.pane(id: paneID))
        #expect(pane.agentKind == .claudeCode)
        #expect(!pane.agentKindIsRuntimeEstablished)
    }

    @Test("provenance persists through a snapshot round trip")
    func codableRoundTripPreservesProvenance() throws {
        let proven = TerminalPane(
            title: "proven",
            workingDirectory: "~",
            agentKind: .openCode,
            agentKindIsRuntimeEstablished: true,
            executionPlan: .local
        )
        let legacy = TerminalPane(
            title: "legacy",
            workingDirectory: "~",
            agentKind: .claudeCode,
            executionPlan: .local
        )

        for pane in [proven, legacy] {
            let data = try JSONEncoder().encode(pane)
            let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)
            #expect(decoded.agentKind == pane.agentKind)
            #expect(decoded.agentKindIsRuntimeEstablished == pane.agentKindIsRuntimeEstablished)
        }
    }
}
