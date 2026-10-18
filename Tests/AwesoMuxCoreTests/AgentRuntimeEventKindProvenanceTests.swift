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

    @Test(arguments: [AgentRuntimePhase.promptSubmit, .sessionStart])
    func textGuessedKindYieldsToPromptSubmit(phase: AgentRuntimePhase) throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        // #require cannot wrap a mutating call; capture the optional first.
        let reclaimed = reducer.decision(
            for: openCodeEvent(
                phase: phase,
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

    @Test(arguments: [(true, AgentRuntimePhase.promptSubmit), (false, .toolStart)])
    func foreignPromptSubmitDoesNotReclaimMidTurn(parentTurnApplied: Bool, phase: AgentRuntimePhase) throws {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        if parentTurnApplied {
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

        }

        #expect(
            reducer.decision(
                for: openCodeEvent(
                    phase: phase,
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

    // MARK: - Session-id proof over a retagged pane

    private static let parentSessionID = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private static let childSessionID = "9a8b7c6d-5e4f-4321-9876-543210fedcba"

    private func claudeCodeEventWithSessionID(
        phase: AgentRuntimePhase,
        eventID: String,
        providerSessionID: String?,
        timestamp: Date
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .claudeCode,
            kind: .claudeCode,
            executionState: .thinking,
            phase: phase,
            eventID: eventID,
            providerSessionID: providerSessionID,
            timestamp: timestamp
        )
    }

    private func foreignBoundaryEvent(
        phase: AgentRuntimePhase,
        eventID: String,
        providerSessionID: String?,
        timestamp: Date
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .codex,
            kind: .codex,
            executionState: .thinking,
            phase: phase,
            eventID: eventID,
            providerSessionID: providerSessionID,
            timestamp: timestamp
        )
    }

    /// A viewport scrape claiming a different kind downgrades provenance in
    /// place — same pane identity, so the reducer's latch from earlier events
    /// still applies to it.
    private func retagged(
        _ session: TerminalSession,
        agentKind: AgentKind
    ) -> TerminalSession {
        var mutable = session
        _ = WorkspaceAttentionReducer.updatePane(
            &mutable,
            paneID: session.activePaneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: agentKind,
                agentKindIsRuntimeEstablished: false
            ),
            now: Date(timeIntervalSince1970: 1)
        )
        return mutable
    }

    /// Drives the guessed provider through a full applied turn so its id is
    /// latched and its lifecycle rests between turns — the one state where the
    /// live-turn gate opens the reclaim path.
    private func latchedAndStoppedReducer(
        session: TerminalSession,
        paneID: TerminalSession.ID
    ) -> AgentRuntimeEventReducer {
        var reducer = AgentRuntimeEventReducer()
        _ = reducer.decision(
            for: claudeCodeEventWithSessionID(
                phase: .promptSubmit,
                eventID: "latch",
                providerSessionID: Self.parentSessionID,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )
        _ = reducer.decision(
            for: claudeCodeEventWithSessionID(
                phase: .stop,
                eventID: "turn-end",
                providerSessionID: Self.parentSessionID,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 13)
        )
        return reducer
    }

    /// The hardening for the between-turns blind spot: once the guessed
    /// provider stops, the live-turn gate opens — but its id stays latched
    /// across a text retag (only sessionEnd clears it), so a boundary carrying
    /// a disagreeing id is provably foreign and must not steal the kind.
    @Test("a latched id refuses another provider's prompt submit over a stopped text-guessed pane")
    func latchedIDRefusesForeignBoundaryOverStoppedRetaggedPane() {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = latchedAndStoppedReducer(session: session, paneID: paneID)
        #expect(reducer.providerSessionID(for: paneID) == Self.parentSessionID)

        let retagged = self.retagged(session, agentKind: .openCode)
        #expect(
            reducer.decision(
                for: foreignBoundaryEvent(
                    phase: .promptSubmit,
                    eventID: "child-steal",
                    providerSessionID: Self.childSessionID,
                    timestamp: Date(timeIntervalSince1970: 14)
                ),
                currentSession: retagged,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 15)
            ) == nil,
            "a disagreeing id must refuse the reclaim the stopped lifecycle opened"
        )
        #expect(reducer.providerSessionID(for: paneID) == Self.parentSessionID)
    }

    /// The real agent keeps its reclaim path after a retag: its own boundary
    /// carries the latched id, so the proof says it is exactly the session the
    /// pane runs.
    @Test(arguments: [false, true])
    func matchingIDStillReclaimsStoppedRetaggedPane(anonymousForeignBoundary: Bool) {
        let session = session(agentKind: .claudeCode, agentKindIsRuntimeEstablished: false)
        let paneID = session.activePaneID
        var reducer = latchedAndStoppedReducer(session: session, paneID: paneID)

        let retagged = self.retagged(session, agentKind: .openCode)
        let event =
            anonymousForeignBoundary
            ? foreignBoundaryEvent(
                phase: .promptSubmit, eventID: "anonymous", providerSessionID: nil, timestamp: Date(timeIntervalSince1970: 14))
            : claudeCodeEventWithSessionID(
                phase: .promptSubmit,
                eventID: "heal",
                providerSessionID: Self.parentSessionID,
                timestamp: Date(timeIntervalSince1970: 14)
            )
        let healed = reducer.decision(
            for: event,
            currentSession: retagged,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 15)
        )

        #expect(healed != nil)
        #expect(healed?.update.agentKind == (anonymousForeignBoundary ? .codex : .claudeCode))
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
}
