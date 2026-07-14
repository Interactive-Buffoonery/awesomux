import Foundation
import Testing
@testable import AwesoMuxCore

/// Covers `WorkspaceAttentionReducer.updatePane`'s `PaneUpdateOutcome.didMutate`
/// gate and the coarsened activity heartbeat it enables (perf/main-thread-churn).
/// A same-state repeat (Claude Code emits these continuously while streaming)
/// must report `didMutate == false` so the store skips the whole-store
/// `@Observable` publish, while a real field change or a due heartbeat refresh
/// must still report `true`.
@Suite("WorkspaceAttentionReducer heartbeat coarsening")
struct WorkspaceAttentionReducerHeartbeatTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(
        agentKind: AgentKind = .claudeCode,
        agentExecutionState: AgentExecutionState = .thinking
    ) -> TerminalSession {
        TerminalSession(
            title: "claude",
            workingDirectory: "~",
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            lastAgentStateChangeAt: Self.t0
        )
    }

    @Test("same-state repeat within the coarsening window mutates nothing")
    func sameStateRepeatIsQuiet() {
        var session = makeSession()
        let paneID = session.activePaneID

        let outcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(agentExecutionState: .thinking),
            now: Self.t0.addingTimeInterval(1)
        )

        #expect(outcome.didMutate == false)
        #expect(outcome.unreadChange == nil)
        #expect(session.lastAgentStateChangeAt == Self.t0)
    }

    @Test("same-state repeat past the window refreshes the heartbeat")
    func sameStateRepeatRefreshesWhenDue() {
        var session = makeSession()
        let paneID = session.activePaneID
        let refreshedAt = Self.t0.addingTimeInterval(11)

        let outcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(agentExecutionState: .thinking),
            now: refreshedAt
        )

        #expect(outcome.didMutate == true)
        #expect(session.lastAgentStateChangeAt == refreshedAt)
    }

    @Test("a state CHANGE refreshes immediately regardless of the window")
    func stateChangeAlwaysRefreshes() {
        var session = makeSession()
        let paneID = session.activePaneID
        let changedAt = Self.t0.addingTimeInterval(1)

        let outcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(agentExecutionState: .output),
            now: changedAt
        )

        #expect(outcome.didMutate == true)
        #expect(session.agentExecutionState == .output)
        #expect(session.lastAgentStateChangeAt == changedAt)
    }

    @Test("an agent-kind-only correction reports mutation")
    func agentKindOnlyCorrectionMutates() {
        // VisibleTextAgentStateReducer can emit exactly this shape — a kind
        // correction with no execution-state change (shouldApplyState == false).
        // Dropping it would strand a mistagged pane forever.
        var session = makeSession(agentKind: .codex)
        let paneID = session.activePaneID
        let originalStamp = session.lastAgentStateChangeAt

        let outcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(agentKind: .claudeCode),
            now: Self.t0.addingTimeInterval(1)
        )

        #expect(outcome.didMutate == true)
        #expect(session.agentKind == .claudeCode)
        // No execution-state field on this update: the heartbeat must not move.
        #expect(session.lastAgentStateChangeAt == originalStamp)
    }

    @Test("title/attention/unread writes still report mutation")
    func fieldWritesReportMutation() {
        var session = makeSession()
        let paneID = session.activePaneID

        let titleOutcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(title: "new"),
            now: Self.t0.addingTimeInterval(1)
        )
        #expect(titleOutcome.didMutate == true)
        #expect(session.title == "new")

        let attentionOutcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(attentionReason: .bell),
            now: Self.t0.addingTimeInterval(2)
        )
        #expect(attentionOutcome.didMutate == true)
        #expect(session.attentionReason == .bell)

        let unreadOutcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(unreadNotificationDelta: 1),
            now: Self.t0.addingTimeInterval(3)
        )
        #expect(unreadOutcome.didMutate == true)
        #expect(unreadOutcome.unreadChange?.oldCount == 0)
        #expect(unreadOutcome.unreadChange?.newCount == 1)

        // A same-value re-emit of an already-set field must stay quiet — that
        // is the entire point of the gate, not just "some field changed once".
        let repeatTitleOutcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(title: "new"),
            now: Self.t0.addingTimeInterval(4)
        )
        #expect(repeatTitleOutcome.didMutate == false)
    }

    @Test("quit-risk staleness boundary survives worst-case coarsening phase")
    func stalenessBoundaryWithCoarsening() {
        // Worst case: the heartbeat was last WRITTEN at t0. A same-state repeat
        // arrives at t0+9.999s — inside the coarsening window, so it does NOT
        // refresh the stamp (this is the "repeats stay sub-window" phase from
        // the brief). Real agent activity then goes silent.
        var session = makeSession()
        let paneID = session.activePaneID
        let subWindowRepeatAt = Self.t0.addingTimeInterval(9.999)

        let repeatOutcome = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: paneID,
            update: .init(agentExecutionState: .thinking),
            now: subWindowRepeatAt
        )
        #expect(repeatOutcome.didMutate == false)
        #expect(session.lastAgentStateChangeAt == Self.t0)

        // Freshness must be read from the LAST WRITTEN stamp (t0), never from
        // the arrival time of the quiet repeat (t0+9.999) — an implementation
        // that anchored on the latter would still call this "fresh" at
        // t0+9.999+59.999 (elapsed 59.999 < 60 from the wrong anchor), when the
        // correct anchor (t0) has already accumulated 69.998s and IS stale.
        let wronglyAnchoredPoint = subWindowRepeatAt.addingTimeInterval(59.999)
        #expect(session.isQuitRisk(at: wronglyAnchoredPoint) == false)

        // The boundary is exact relative to the real (t0) anchor: fresh at
        // t0+59.999s, stale at t0+60s. The coarsening never widens the 60s
        // trust window — it can only shift the anchor earlier by at most
        // agentActivityFreshnessCoarsening (10s) per refresh, and here it did
        // not refresh at all, so there is zero drift from t0.
        #expect(session.isQuitRisk(at: Self.t0.addingTimeInterval(59.999)) == true)
        #expect(session.isQuitRisk(at: Self.t0.addingTimeInterval(60)) == false)
    }
}
