import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Quit risk")
struct QuitRiskTests {
    @Test("waiting is not risky for agent or shell sessions")
    func waitingIsNotQuitRisk() {
        let agent = TerminalSession(
            title: "claude waiting",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .waiting
        )
        let shell = TerminalSession(
            title: "shell waiting",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .waiting
        )

        #expect(!agent.isQuitRisk())
        #expect(!shell.isQuitRisk())
    }

    @Test("active states age out; attention is no longer a quit risk")
    func activeStatesAgeOutAfterThreshold() {
        let now = Date()
        let stale = now.addingTimeInterval(-(TerminalSession.staleAgentActivityThreshold + 1))
        let fresh = now.addingTimeInterval(-1)

        for activeState in [AgentState.running, .thinking, .output] {
            let staleSession = TerminalSession(
                title: "stale",
                workingDirectory: "~",
                agentKind: .claudeCode,
                agentState: activeState,
                lastAgentStateChangeAt: stale
            )
            let freshSession = TerminalSession(
                title: "fresh",
                workingDirectory: "~",
                agentKind: .claudeCode,
                agentState: activeState,
                lastAgentStateChangeAt: fresh
            )
            #expect(!staleSession.isQuitRisk(at: now))
            #expect(freshSession.isQuitRisk(at: now))
        }

        // INT-217: attention is a display projection, NOT a liveness signal.
        // A stale-attention agent with no live process is no longer a quit risk.
        let staleAttention = TerminalSession(
            title: "stuck attention",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .needsAttention,
            lastAgentStateChangeAt: stale
        )
        #expect(!staleAttention.isQuitRisk(at: now))
    }

    @MainActor
    @Test("markAgentActivityObserved refreshes a stale active session")
    func markAgentActivityObservedRefreshesStale() {
        let stale = Date().addingTimeInterval(-(TerminalSession.staleAgentActivityThreshold + 5))
        let session = TerminalSession(
            title: "long thinker",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .thinking,
            lastAgentStateChangeAt: stale
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.sessionsAtRiskOnQuit.isEmpty)

        store.markAgentActivityObserved(id: session.id)
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
    }

    @MainActor
    @Test("session store returns agent sessions whose states are risky on quit")
    func sessionStoreReturnsSessionsAtRiskOnQuit() {
        let shellRunning = TerminalSession(
            title: "shell running",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let claudeRunning = TerminalSession(
            title: "claude running",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .running
        )
        let codexThinking = TerminalSession(
            title: "codex thinking",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking
        )
        let codexOutput = TerminalSession(
            title: "codex output",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .output
        )
        // INT-217: attention with no running execution is no longer a quit risk.
        // Explicitly idle so the fallback doesn't resolve to .running via
        // agentKind.initialSessionState.
        let codexNeedsAttention = TerminalSession(
            title: "codex needs attention",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            agentExecutionState: .idle
        )
        let claudeDone = TerminalSession(
            title: "claude done",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .done
        )
        let shellNeedsAttention = TerminalSession(
            title: "shell needs attention",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .needsAttention
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shellRunning, claudeRunning]),
            SessionGroup(name: "scratch", sessions: [
                codexThinking,
                codexOutput,
                codexNeedsAttention,
                claudeDone,
                shellNeedsAttention
            ])
        ])

        let expectedIDs: Set<TerminalSession.ID> = [
            claudeRunning.id,
            codexThinking.id,
            codexOutput.id
        ]
        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == expectedIDs)
        #expect(store.sessionsAtRiskOnQuitCount == expectedIDs.count)
    }

    @Test("terminal quit confirmation marks shell sessions as quit risks")
    func terminalQuitConfirmationMarksShellAsRisk() {
        let shell = TerminalSession(
            title: "vim",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )

        #expect(shell.isQuitRisk())
    }

    @MainActor
    @Test("terminal quit confirmation risks are synced from backend snapshots")
    func terminalQuitConfirmationRisksSyncFromBackendSnapshots() {
        let shell = TerminalSession(
            title: "ssh",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let idleShell = TerminalSession(
            title: "idle",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell, idleShell])
        ])

        // `idleShell` is omitted, so the absence policy clears its pre-set flag.
        store.updateTerminalQuitConfirmationRisks([.active(shell, needsConfirmation: true)])

        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == Set([shell.id]))
        #expect(store.sessionsAtRiskOnQuitCount == 1)
    }

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
    @Test("empty session store has no quit risks")
    func emptySessionStoreHasNoRisks() {
        let store = SessionStore(groups: [])
        #expect(store.sessionsAtRiskOnQuit.isEmpty)
        #expect(store.sessionsAtRiskOnQuitCount == 0)
    }

    @MainActor
    @Test("aggregating snapshots OR-folds multi-pane sessions into a single risk")
    func snapshotAggregationOrFoldsMultiPaneSessions() {
        let multiPaneSession = TerminalSession(
            title: "split",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let singlePaneSession = TerminalSession(
            title: "solo",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [multiPaneSession, singlePaneSession])
        ])

        // Two panes for multiPaneSession: one busy (vim), one idle.
        // OR-fold should mark the SESSION risky.
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: multiPaneSession.id,
                paneID: multiPaneSession.activePaneID,
                needsConfirmation: false
            ),
            TerminalQuitConfirmationSnapshot(
                sessionID: multiPaneSession.id,
                paneID: multiPaneSession.activePaneID,
                needsConfirmation: true
            ),
            TerminalQuitConfirmationSnapshot(
                sessionID: singlePaneSession.id,
                paneID: singlePaneSession.activePaneID,
                needsConfirmation: false
            )
        ])

        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == Set([multiPaneSession.id]))
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

    @MainActor
    @Test("aggregating empty snapshots clears all previously-flagged sessions")
    func snapshotAggregationClearsAllOnEmpty() {
        let stale = TerminalSession(
            title: "ghost",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [stale])
        ])

        store.updateTerminalQuitConfirmationRisks([TerminalQuitConfirmationSnapshot]())

        #expect(store.sessionsAtRiskOnQuit.isEmpty)
    }

    @MainActor
    @Test("liveness syncs through the snapshot seam and resets on absence")
    func livenessSyncsAndResets() {
        let busy = TerminalSession(title: "dev", workingDirectory: "~", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [busy])])

        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: busy.id,
                paneID: busy.activePaneID,
                needsConfirmation: false,
                liveness: .busyShell
            )
        ])
        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == Set([busy.id]))

        // Absent from the next batch → reset to .unsampled (safe).
        store.updateTerminalQuitConfirmationRisks([])
        #expect(store.sessionsAtRiskOnQuit.isEmpty)
    }

    @Test("a live foreground process makes an idle-exec pane a quit risk")
    func liveForegroundProcessIsRisk() {
        var pane = TerminalPane(title: "claude", workingDirectory: "~", agentKind: .claudeCode, executionPlan: .local)
        pane.agentExecutionState = .idle
        pane.foregroundProcessLiveness = .liveCommand
        #expect(pane.isQuitRisk())

        var idle = TerminalPane(title: "zsh", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        idle.foregroundProcessLiveness = .idleShell
        #expect(!idle.isQuitRisk())

        var bg = TerminalPane(title: "zsh", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        bg.foregroundProcessLiveness = .busyShell
        #expect(bg.isQuitRisk())

        var bridged = TerminalPane(title: "zsh", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        bridged.foregroundProcessLiveness = .bridged
        bridged.needsTerminalQuitConfirmation = true   // even away-from-prompt
        #expect(!bridged.isQuitRisk())
    }

    @MainActor
    @Test("idle shell-only store has no quit risks even with risky agent states")
    func idleShellOnlyStoreHasNoRisks() {
        let busyShell = TerminalSession(
            title: "build",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let attentionShell = TerminalSession(
            title: "ssh",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .needsAttention
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [busyShell, attentionShell])
        ])
        #expect(store.sessionsAtRiskOnQuit.isEmpty)
        #expect(store.sessionsAtRiskOnQuitCount == 0)
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
        let ownedRisky = TerminalSession(title: "mine", workingDirectory: "~", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [ownedRisky])])

        let foreignPaneID = TerminalPane.ID()
        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: ownedRisky.id,
                paneID: ownedRisky.activePaneID,
                needsConfirmation: true
            ),
            // A pane this store has never heard of — as if the shared snapshot
            // list also included a floating-slot store's surfaces.
            TerminalQuitConfirmationSnapshot(
                sessionID: TerminalSession.ID(),
                paneID: foreignPaneID,
                needsConfirmation: true
            ),
        ])

        #expect(Set(store.sessionsAtRiskOnQuit.map(\.id)) == Set([ownedRisky.id]))
        #expect(store.sessionsAtRiskOnQuitCount == 1)
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
