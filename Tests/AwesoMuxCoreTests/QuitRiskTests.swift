import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Quit risk")
struct QuitRiskTests {

    @MainActor
    @Test("unobserved prompt state does not enter the quit-risk cache")
    func unobservedPromptStateIsNotCachedAsRisk() {
        let shell = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [shell])])

        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: shell.id,
                paneID: shell.activePaneID,
                needsConfirmation: true,
                promptObserved: false,
                liveness: .unsampled
            )
        ])

        #expect(store.sessionsAtRiskOnQuit.isEmpty)
    }

    @MainActor
    @Test("sessions absent from the snapshot list are reset to safe (lazy-mount invariant)")
    func snapshotAggregationClearsAbsentSessions() {
        // Architectural invariant: a session is in `surfaceViews` iff it has
        // a live `ghostty_surface_t`. Surfaces are created lazily on render
        // and discarded on pane close / session close / pane recycle. So a
        // session ID absent from the snapshot list has no spawned process —
        // clearing the flag is correct, not a false-negative. If this test
        // ever needs to be relaxed because surfaces are eagerly spawned for
        // un-mounted sessions, revisit
        // `SessionStore.updateTerminalQuitConfirmationRisks` simultaneously.
        let mountedBusy = TerminalSession(
            title: "vim",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )
        let unmounted = TerminalSession(
            title: "stale-flag",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [mountedBusy, unmounted])
        ])

        // Only the mounted session has a snapshot; the previously-flagged
        // unmounted session must be cleared by the absence policy.
        store.updateTerminalQuitConfirmationRisks([.active(mountedBusy, needsConfirmation: true)])

        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == Set([mountedBusy.id]))
    }

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
    @Test("splitting an already at-risk session's pane preserves its risk classification (structural mutation)")
    func splittingAtRiskSessionPreservesRiskClassification() {
        let session = TerminalSession(
            title: "codex thinking",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])

        // Split is a structural mutation — it rebuilds both risk sets from
        // scratch via rebuildDerivedState() rather than reclassifyRiskMembership.
        // The original (risky) pane must survive the split still classified risky.
        guard store.splitActivePane(orientation: .vertical, in: session.id) != nil else {
            Issue.record("expected split to succeed")
            return
        }
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
        #expect(store.sessionsAtRiskOnQuitCount == 1)
    }

    @MainActor
    @Test("clearStaleErrorIfPresent reclassifies the session after clearing the only risky pane")
    func clearStaleErrorIfPresentReclassifiesSession() {
        let session = TerminalSession(
            title: "codex errored",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(sessionID: session.id, paneID: session.activePaneID, needsConfirmation: true)
        ])
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])

        // clearStaleErrorIfPresent only fires when the pane's execution state is
        // .error, so drive it there first via recordPaneProcessError, then clear.
        store.recordPaneProcessError(in: session.id, paneID: session.activePaneID, terminalIsFocused: true)
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(sessionID: session.id, paneID: session.activePaneID, needsConfirmation: false)
        ])
        store.clearStaleErrorIfPresent(id: session.id)

        #expect(store.sessionsAtRiskOnQuit.isEmpty)
        #expect(store.sessionsAtRiskOnQuitCount == 0)
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

    @MainActor
    @Test("duplicate session IDs fall back to brute-force evaluation instead of under-reporting risk")
    func duplicateSessionIDsFallBackToBruteForce() {
        let sharedID = TerminalSession.ID()
        // The FIRST occurrence is safe. If the cache resolved risk via
        // position(for:) (which always finds the first occurrence), a naive
        // ID-keyed implementation would wrongly report this pair as safe.
        let safeFirstCopy = TerminalSession(
            id: sharedID,
            title: "idle first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let riskySecondCopy = TerminalSession(
            id: sharedID,
            title: "codex thinking second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "one", sessions: [safeFirstCopy]),
            SessionGroup(name: "two", sessions: [riskySecondCopy])
        ])

        // Matches main's pre-cache brute-force semantics: every session VALUE is
        // evaluated independently, so the risky second copy is not masked by its
        // safe duplicate.
        #expect(store.sessionsAtRiskOnQuitCount == 1)
        #expect(store.sessionsAtRiskOnQuit.map(\.title) == ["codex thinking second"])
    }
}
