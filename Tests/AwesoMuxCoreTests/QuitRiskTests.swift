import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Quit risk")
struct QuitRiskTests {

    // MARK: - INT-420 cache correctness

    @MainActor
    @Test("a multi-pane session stays at risk while a sibling pane still qualifies, independent of the other pane's mutation path")
    func multiPaneSessionStaysAtRiskUntilAllPanesClear() {
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        guard let secondPaneID = store.splitActivePane(orientation: .horizontal, in: session.id) else {
            Issue.record("expected split to succeed")
            return
        }

        // Mark the second (fresh shell) pane as a durable risk via the
        // quit-confirmation sync path — a different governance path than the
        // first pane's freshness-candidate risk.
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(sessionID: session.id, paneID: secondPaneID, needsConfirmation: true)
        ])
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
        #expect(store.sessionsAtRiskOnQuitCount == 1)

        // Clear the durable risk on the second pane. The first pane (fresh
        // codex .thinking) is still a freshness candidate, so the session must
        // stay at risk — reclassification must scan ALL of a session's panes,
        // not just the one the triggering mutation touched.
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(sessionID: session.id, paneID: secondPaneID, needsConfirmation: false)
        ])
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
        #expect(store.sessionsAtRiskOnQuitCount == 1)
    }

    @MainActor
    @Test("a freshness-candidate session ages out of risk purely from elapsed time, with no intervening mutation")
    func freshnessCandidateAgesOutWithoutMutation() {
        let now = Date()
        let session = TerminalSession(
            title: "codex thinking",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking,
            lastAgentStateChangeAt: now
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        // No mutation happens between these two reads — only `now` advances.
        #expect(store.sessionsAtRiskOnQuit(at: now).map(\.id) == [session.id])
        #expect(store.sessionsAtRiskOnQuitCount(at: now) == 1)

        let stale = now.addingTimeInterval(TerminalPane.staleAgentActivityThreshold + 1)
        #expect(store.sessionsAtRiskOnQuit(at: stale).isEmpty)
        #expect(store.sessionsAtRiskOnQuitCount(at: stale) == 0)
    }

    @MainActor
    @Test("a shared snapshot list containing another store's paneIDs is safely ignored (INT-185)")
    func sharedSnapshotListIgnoresForeignPaneIDs() {
        // INT-185: the quit path now computes ONE snapshot list across every
        // live surface app-wide and fans the SAME list out to the main store,
        // every floating-slot store, and the pop-up store — instead of each
        // store triggering its own resample of the shared surface set. That
        // redesign only holds if a store's `updateTerminalQuitConfirmationRisks`
        // ignores snapshot entries for paneIDs it doesn't own, rather than
        // erroring or cross-contaminating another store's session. This is
        // the load-bearing correctness property for that fix.
        // The owned session's OWN snapshot is safe and the foreign entry is
        // risky — the reverse of "both true" would pass whether or not the
        // foreign entry leaks into the owned store, since either outcome
        // reports the owned session as risky either way. Only this shape
        // (owned=safe, foreign=risky) actually distinguishes "ignored" from
        // "cross-contaminated": cross-contamination would incorrectly flip
        // the owned session to risky (review finding — the original version
        // of this test could not fail on the bug it claimed to guard).
        let ownedSafe = TerminalSession(title: "mine", workingDirectory: "~", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [ownedSafe])])

        let foreignPaneID = TerminalPane.ID()
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: ownedSafe.id,
                paneID: ownedSafe.activePaneID,
                needsConfirmation: false
            ),
            // A pane this store has never heard of — as if the shared snapshot
            // list also included a floating-slot store's surfaces.
            TerminalQuitConfirmationSnapshot(
                sessionID: TerminalSession.ID(),
                paneID: foreignPaneID,
                needsConfirmation: true
            ),
        ])

        #expect(store.sessionsAtRiskOnQuit.isEmpty)
        #expect(store.sessionsAtRiskOnQuitCount == 0)
    }

}
