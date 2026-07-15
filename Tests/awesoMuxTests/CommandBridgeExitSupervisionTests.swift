import AwesoMuxCore
import Testing

/// Unit coverage for the PURE seam the bridge exit-supervision path enacts:
/// the `BridgeSessionEndPolicy` decision keyed on the latest `SessionEndReason`,
/// and the `CommandBridgeRespawnLedger` that owns the respawn budget +
/// daemon-incarnation tracking. The `NSView` is a thin enactor over these, so
/// the supervision behavior is testable here without AppKit.
@Suite("CommandBridgeExitSupervision")
struct CommandBridgeExitSupervisionTests {

    private let maxAttempts = CommandBridgeRespawnLedger.defaultMaxRespawnAttempts

    // MARK: - Policy decision keyed on recorded SessionEndReason

    @Test("clean shell exit marks the pane exited (pane closes, no respawn)")
    func shellExitMarksExited() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .shellExit,
            bridgeEnabled: true,
            respawnAttempts: 0,
            maxAttempts: maxAttempts
        )
        #expect(decision == .markExited)
    }

    @Test("remote shell exit latches error instead of closing the workgroup")
    func remoteShellExitErrors() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .shellExit,
            bridgeEnabled: true,
            isRemote: true,
            respawnAttempts: 0,
            maxAttempts: maxAttempts
        )
        #expect(decision == .error)
    }

    @Test("daemon death under the cap respawns fresh")
    func daemonDiedUnderCapRespawns() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .daemonDied,
            bridgeEnabled: true,
            respawnAttempts: maxAttempts - 1,
            maxAttempts: maxAttempts
        )
        #expect(decision == .respawnFresh)
    }

    @Test("no recorded reason fails safe to respawn (INT-571 non-destructive)")
    func nilReasonRespawns() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: nil,
            bridgeEnabled: true,
            respawnAttempts: 0,
            maxAttempts: maxAttempts
        )
        #expect(decision == .respawnFresh)
    }

    @Test("at the respawn cap latches error instead of respawning")
    func atCapLatchesError() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .daemonDied,
            bridgeEnabled: true,
            respawnAttempts: maxAttempts,
            maxAttempts: maxAttempts
        )
        #expect(decision == .error)
    }

    @Test("bridge disabled marks exited regardless of reason")
    func disabledMarksExited() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .daemonDied,
            bridgeEnabled: false,
            respawnAttempts: 0,
            maxAttempts: maxAttempts
        )
        #expect(decision == .markExited)
    }

    @Test("user-initiated detach reconnects")
    func detachReconnects() {
        let decision = BridgeSessionEndPolicy.decide(
            reason: .detached,
            bridgeEnabled: true,
            respawnAttempts: 0,
            maxAttempts: maxAttempts
        )
        #expect(decision == .reconnect)
    }

    // MARK: - Respawn ledger (attempts budget + incarnation tracking)

    @Test("an attach alone does NOT reset the respawn budget")
    func attachDoesNotResetAttempts() {
        // Load-bearing: a crash-looping daemon attaches on every respawn, so if
        // recordAttach reset the budget the `.error` cap would be unreachable.
        var ledger = CommandBridgeRespawnLedger()
        ledger.recordRespawnAttempt()
        ledger.recordRespawnAttempt()
        #expect(ledger.respawnAttempts == 2)

        ledger.recordAttach(AmxDaemonIncarnation(pid: 100, createdAt: 1_700_000_000))
        #expect(ledger.respawnAttempts == 2)
    }

    @Test("refillBudget resets attempts to zero")
    func refillResetsAttempts() {
        var ledger = CommandBridgeRespawnLedger()
        ledger.recordRespawnAttempt()
        ledger.recordRespawnAttempt()
        ledger.refillBudget()
        #expect(ledger.respawnAttempts == 0)
    }

    @Test("each respawn attempt increments the budget")
    func respawnAttemptIncrements() {
        var ledger = CommandBridgeRespawnLedger()
        #expect(ledger.respawnAttempts == 0)
        ledger.recordRespawnAttempt()
        #expect(ledger.respawnAttempts == 1)
    }

    @Test("a crash loop (attach, die, attach, die...) reaches the error cap")
    func crashLoopReachesCap() {
        // Reproduces the convergent reviewer finding: without the uptime gate,
        // attach-resets-budget would oscillate the counter and never latch error.
        // Here each respawn attaches a fresh incarnation that dies before the
        // grace window refills the budget, so attempts climb to the cap.
        var ledger = CommandBridgeRespawnLedger()
        for i in 0..<maxAttempts {
            // Each death decides via the policy on the CURRENT attempt count.
            let decision = BridgeSessionEndPolicy.decide(
                reason: .daemonDied,
                bridgeEnabled: true,
                respawnAttempts: ledger.respawnAttempts,
                maxAttempts: maxAttempts
            )
            #expect(decision == .respawnFresh, "attempt \(i) should still respawn")
            ledger.recordRespawnAttempt()
            // The respawn attaches a fresh daemon, but it dies before the grace
            // window — so NO refillBudget() call. The incarnation is recorded.
            ledger.recordAttach(AmxDaemonIncarnation(pid: 1000 + i, createdAt: i))
        }
        // Budget now exhausted: the next death latches error.
        #expect(ledger.respawnAttempts == maxAttempts)
        let finalDecision = BridgeSessionEndPolicy.decide(
            reason: .daemonDied,
            bridgeEnabled: true,
            respawnAttempts: ledger.respawnAttempts,
            maxAttempts: maxAttempts
        )
        #expect(finalDecision == .error)
    }

    @Test("a healthy session that survives the grace window refills and never latches error")
    func healthySessionRefillsBudget() {
        var ledger = CommandBridgeRespawnLedger()
        // Two crashes drain the budget partway.
        ledger.recordRespawnAttempt()
        ledger.recordRespawnAttempt()
        #expect(ledger.respawnAttempts == 2)
        // The respawn attaches AND survives the grace window → refill.
        ledger.recordAttach(AmxDaemonIncarnation(pid: 42, createdAt: 1))
        ledger.refillBudget()
        // A later unrelated crash decides on a full budget again.
        let decision = BridgeSessionEndPolicy.decide(
            reason: .daemonDied,
            bridgeEnabled: true,
            respawnAttempts: ledger.respawnAttempts,
            maxAttempts: maxAttempts
        )
        #expect(decision == .respawnFresh)
    }

    @Test("first attach is not treated as a fresh respawn")
    func firstAttachIsFirstAttach() {
        var ledger = CommandBridgeRespawnLedger()
        let outcome = ledger.recordAttach(AmxDaemonIncarnation(pid: 7, createdAt: 42))
        #expect(outcome == .firstAttach)
        #expect(ledger.lastIncarnation == AmxDaemonIncarnation(pid: 7, createdAt: 42))
    }

    @Test("re-attaching to the same daemon incarnation is a reconnect")
    func sameIncarnationIsReconnect() {
        var ledger = CommandBridgeRespawnLedger()
        let incarnation = AmxDaemonIncarnation(pid: 7, createdAt: 42)
        ledger.recordAttach(incarnation)
        let outcome = ledger.recordAttach(incarnation)
        #expect(outcome == .reconnect)
    }

    @Test("consecutive ambiguous respawn debits are refunded when attach proves a reconnect")
    func reconnectRefundsConsecutiveAmbiguousRespawnAttempts() {
        var ledger = CommandBridgeRespawnLedger()
        let incarnation = AmxDaemonIncarnation(pid: 7, createdAt: 42)
        ledger.recordAttach(incarnation)
        for _ in 0..<maxAttempts {
            ledger.recordRespawnAttempt()
        }

        let outcome = ledger.recordAttach(incarnation)

        #expect(outcome == .reconnect)
        #expect(ledger.respawnAttempts == 0)
    }

    @Test("consecutive ambiguous respawn debits remain when attach proves a fresh daemon")
    func freshAttachKeepsConsecutiveAmbiguousRespawnAttempts() {
        var ledger = CommandBridgeRespawnLedger()
        ledger.recordAttach(AmxDaemonIncarnation(pid: 7, createdAt: 42))
        for _ in 0..<maxAttempts {
            ledger.recordRespawnAttempt()
        }

        let outcome = ledger.recordAttach(AmxDaemonIncarnation(pid: 8, createdAt: 43))

        #expect(outcome == .fresh)
        #expect(ledger.respawnAttempts == maxAttempts)
    }

    @Test("a fresh attach locks prior attempts out of a later reconnect refund")
    func freshAttachLocksPriorAttempts() {
        var ledger = CommandBridgeRespawnLedger()
        let freshIncarnation = AmxDaemonIncarnation(pid: 8, createdAt: 43)
        ledger.recordAttach(AmxDaemonIncarnation(pid: 7, createdAt: 42))
        ledger.recordRespawnAttempt()
        ledger.recordRespawnAttempt()

        #expect(ledger.recordAttach(freshIncarnation) == .fresh)
        #expect(ledger.respawnAttempts == 2)
        ledger.recordRespawnAttempt()
        #expect(ledger.respawnAttempts == 3)

        #expect(ledger.recordAttach(freshIncarnation) == .reconnect)
        #expect(ledger.respawnAttempts == 2)
    }

    @Test("attaching to a different daemon incarnation is a fresh respawn")
    func differentIncarnationIsFresh() {
        var ledger = CommandBridgeRespawnLedger()
        ledger.recordAttach(AmxDaemonIncarnation(pid: 7, createdAt: 42))
        let outcome = ledger.recordAttach(AmxDaemonIncarnation(pid: 9, createdAt: 99))
        #expect(outcome == .fresh)
    }

    @Test("reset clears both attempts and incarnation")
    func resetClearsState() {
        var ledger = CommandBridgeRespawnLedger()
        ledger.recordRespawnAttempt()
        ledger.recordAttach(AmxDaemonIncarnation(pid: 7, createdAt: 42))
        ledger.recordRespawnAttempt()
        #expect(ledger.respawnAttempts == 2)
        ledger.reset()
        #expect(ledger.respawnAttempts == 0)
        #expect(ledger.lastIncarnation == nil)
    }

    // MARK: - Latched-error pane inertness (I-1)

    @Test("shouldProcessCommandBridgeStatusEvents returns true when no error is latched")
    func noLatchAllowsEvents() {
        #expect(shouldProcessCommandBridgeStatusEvents(errorLatched: false) == true)
    }

    @Test("shouldProcessCommandBridgeStatusEvents returns false when error is latched")
    func latchBlocksEvents() {
        // A latched-error pane must ignore stray status events: a late `attached`
        // line on the status file must not clear agent chrome or false-announce
        // "Session restarted" while the pane is in the error state.
        #expect(shouldProcessCommandBridgeStatusEvents(errorLatched: true) == false)
    }
}
