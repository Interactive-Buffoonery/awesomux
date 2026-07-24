import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// Full-lifecycle SEQUENCE coverage for ``CommandBridgeEnactor`` (INT-613): the
/// transitions the isolated policy atoms (`CommandBridgeExitSupervisionTests`)
/// and the view-heal suite don't assert as one continuous enactor lifetime —
/// crash-loop budget draining to the error latch, detach→reconnect spending no
/// budget, fresh-incarnation clearing transient per-pane state, and a latched
/// pane staying inert to stray status events.
///
/// Drives a real enactor through a real `GhosttySurfaceNSView` host against a
/// real `SessionStore` + `GhosttyRuntime`; `surface == nil` makes the native
/// dispose/remount calls inert, exactly as the existing view suite relies on.
@MainActor
@Suite("Command bridge enactor lifecycle")
struct CommandBridgeEnactorTests {
    private enum Announcement: Equatable {
        case freshRespawn
        case errorEntered
    }

    private let establishedMetadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

    @Test("daemon-death respawns drain the budget and latch error at the cap")
    func crashLoopDrainsBudgetToErrorLatch() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceErrorEntered = { announcements.append(.errorEntered) }

        // Each daemon-death session-end under the cap spends one budget unit and
        // heals; the ledger climbs. The final one exceeds the cap and latches.
        for attempt in 1...CommandBridgeEnactor.maxRespawnAttempts {
            try driveSessionEnd(fixture: fixture, reason: .daemonDied)
            #expect(enactor.respawnLedger.respawnAttempts == attempt)
            #expect(!enactor.errorLatched)
        }

        try driveSessionEnd(fixture: fixture, reason: .daemonDied)
        #expect(enactor.errorLatched)
        #expect(announcements == [.errorEntered])
    }

    @Test("a detach reconnect spends no budget and does not reset chrome")
    func reconnectSpendsNoBudgetAndKeepsChrome() throws {
        let fixture = try makeAgentFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceSessionRespawnedFresh = { announcements.append(.freshRespawn) }
        enactor.announceErrorEntered = { announcements.append(.errorEntered) }

        // Live-daemon reconnect: `.detached` maps to `.reconnect`, which
        // re-attaches without metering the crash budget. A detach-happy user
        // repeats this many times; the budget must stay pinned at zero across
        // every hop, not just the first.
        for _ in 1...3 {
            try driveSessionEnd(fixture: fixture, reason: .detached)
            #expect(enactor.respawnLedger.respawnAttempts == 0)
            #expect(!enactor.errorLatched)
            // Chrome is only reset on a fresh incarnation, not on a reconnect.
            let pane = try #require(fixture.livePane)
            #expect(pane.agentKind == AgentKind.codex)
        }
        #expect(announcements.isEmpty)
    }

    @Test("a fresh daemon incarnation clears transient per-pane agent chrome")
    func freshIncarnationClearsTransientState() throws {
        let fixture = try makeAgentFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceSessionRespawnedFresh = { announcements.append(.freshRespawn) }
        enactor.sessionID = fixture.sessionID
        fixture.view.shellCommandFinishedIdleLatched = true

        // First attach establishes the incarnation baseline; a second attach with
        // a different daemon pid/createdAt classifies as `.fresh`.
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])
        enactor.handleStatusEvents([try attachedEvent(pid: 200, createdAt: 1_700_000_100, sessionID: fixture.sessionID)])

        let pane = try #require(fixture.livePane)
        #expect(pane.agentKind == AgentKind.shell)
        #expect(pane.attentionReason == nil)
        #expect(announcements == [.freshRespawn])
    }

    @Test("a clean shell exit clears bridge state and closes without recursing")
    func cleanExitClearsStateAndCloses() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor

        // `.shellExit` maps to `.markExited`, whose arm clears bridge state
        // (nilling `sessionID`) BEFORE re-entering `closeAfterProcessExit`. The
        // re-entry hits the `sessionID != nil` recursion floor and falls through
        // to the normal close instead of looping back into supervision. This
        // asserts the floor holds: the drive returns (no unbounded recursion),
        // the bridge state is cleared, and the pane is gone from the store.
        try driveSessionEnd(fixture: fixture, reason: .shellExit)

        #expect(enactor.sessionID == nil)
        #expect(!enactor.errorLatched)
        #expect(!enactor.exitProbeInFlight)
        #expect(fixture.livePane == nil)
    }

    @Test("a remote clean exit (code 0) closes the pane like a local shell (INT-769)")
    func remoteCleanShellExitClosesPane() throws {
        let fixture = try makeRemoteFixture()
        let enactor = fixture.view.commandBridgeEnactor

        // ssh returns 0 when the user (or remote shell) exits cleanly. That should
        // close the pane like a local shell, not leave a corpse in an error state.
        try driveSessionEnd(fixture: fixture, reason: .shellExit, code: 0)

        #expect(enactor.sessionID == nil)
        #expect(!enactor.errorLatched)
        #expect(!enactor.exitProbeInFlight)
        #expect(fixture.livePane == nil)
    }

    @Test(
        "a remote abnormal exit (dropped connection, non-zero code) latches error without closing")
    func remoteAbnormalShellExitLatchesErrorWithoutClosing() throws {
        let fixture = try makeRemoteFixture()
        let enactor = fixture.view.commandBridgeEnactor

        // ssh returns 255 on a dropped connection: keep the persistent workgroup
        // and surface an error to recover from, never silently close.
        try driveSessionEnd(fixture: fixture, reason: .shellExit, code: 255)

        #expect(enactor.sessionID == fixture.sessionID)
        #expect(enactor.errorLatched)
        #expect(!enactor.exitProbeInFlight)
        let pane = try #require(fixture.livePane)
        #expect(pane.agentExecutionState == .error)
    }

    @Test("a no-status attach clears the previous status watcher")
    func noStatusAttachClearsPreviousStatusWatcher() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        enactor.beginStatusWatch(channel: channel)
        let previousWatcher = try #require(enactor.statusWatcher)
        #expect(previousWatcher.isArmed)
        #expect(enactor.statusChannel != nil)

        enactor.beginStatusWatch(channel: nil)

        #expect(!previousWatcher.isArmed)
        #expect(enactor.statusWatcher == nil)
        #expect(enactor.statusChannel == nil)
    }

    @Test("foreground executable probe uses only the current daemon")
    func foregroundExecutableProbeUsesCurrentDaemon() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        #expect(enactor.foregroundExecutableMatch("ssh") == .unknown)

        enactor.sessionID = fixture.sessionID
        enactor.respawnLedger.recordAttach(AmxDaemonIncarnation(pid: 42, createdAt: 1))
        var probedExecutable: String?
        var probedDaemonPID: pid_t?
        let result = enactor.foregroundExecutableMatch("ssh") { executable, daemonPID in
            probedExecutable = executable
            probedDaemonPID = daemonPID
            return .matching
        }
        #expect(result == .matching)
        #expect(probedExecutable == "ssh")
        #expect(probedDaemonPID == 42)

        enactor.errorLatched = true
        #expect(
            enactor.foregroundExecutableMatch("ssh") { _, _ in
                Issue.record("latched panes must not probe")
                return .matching
            } == .unknown
        )
    }

    @Test("foreground comm probe shares the executable probe's evidence guards")
    func foregroundCommUsesCurrentDaemon() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        #expect(enactor.foregroundComm() == nil)

        enactor.sessionID = fixture.sessionID
        enactor.respawnLedger.recordAttach(AmxDaemonIncarnation(pid: 42, createdAt: 1))
        var probedDaemonPID: pid_t?
        let observed = enactor.foregroundComm { daemonPID in
            probedDaemonPID = daemonPID
            return "2.1.214"
        }
        #expect(observed == "2.1.214")
        #expect(probedDaemonPID == 42)

        enactor.errorLatched = true
        #expect(
            enactor.foregroundComm { _ in
                Issue.record("latched panes must not probe")
                return "zsh"
            } == nil
        )
    }

    @Test("nudge foreground comm fails closed for both bridge states without evidence")
    func nudgeForegroundCommFailsClosed() throws {
        let fixture = try makeFixture()

        // Non-bridged pane with no live surface: the quit-gate sampler has no
        // pid to read, so the nudge evidence must be nil (deny), never a guess.
        #expect(fixture.view.commandBridgeEnactor.sessionID == nil)
        #expect(fixture.view.documentNudgeForegroundComm() == nil)

        // Bridged pane with no recorded daemon incarnation: same deny.
        fixture.view.commandBridgeEnactor.sessionID = fixture.sessionID
        #expect(fixture.view.documentNudgeForegroundComm() == nil)
    }

    @Test("status events for another session are ignored")
    func mismatchedSessionStatusIsIgnored() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        let event = try #require(
            Self.attachedStatusEvent(
                pid: 42,
                createdAt: 1,
                session: "00000000-0000-4000-8000-000000000002"
            )
        )

        enactor.handleStatusEvents([event])

        #expect(enactor.respawnLedger.lastIncarnation == nil)
    }

    @Test(
        "a remote-tagged pane whose attach command is unavailable never falls back to a local shell"
    )
    func remoteUnavailableNeverSpawnsLocalShell() async throws {
        let fixture = try makeRemoteFixture()

        // The bundled `amx` executable never sits beside the test binary, so
        // `AmxBackend.attachCommand` genuinely returns nil here — this drives
        // the real `.remoteUnavailable` branch of `BridgeSurfaceCommandPolicy`,
        // not a mock of it.
        fixture.view.createSurfaceIfNeeded()

        // CRITICAL regression (ADR-0022 trust boundary): before the fix,
        // `createSurfaceIfNeeded` read past the error latch `prepareAttach`
        // had just set and fell through to `runtime.createSurface(command:
        // nil)`, spawning a silent, typable LOCAL shell that looked like the
        // remote host. It must instead leave the pane surfaceless and latched.
        // The latch is set SYNCHRONOUSLY (the trust boundary can't wait a tick).
        #expect(fixture.view.surface == nil)
        #expect(fixture.view.commandBridgeErrorLatched)

        // The user-visible error chrome (`recordPaneProcessError`) is deferred
        // one runloop hop so it lands outside the layout pass — mutating it
        // in-pass crashed AppKit's constraint engine. Pump the main queue, then
        // assert the chrome caught up.
        await pumpMainQueue()
        let pane = try #require(fixture.livePane)
        #expect(pane.agentExecutionState == .error)
    }

    @Test(
        "a remote-tagged pane never falls back to a local shell when the bridge is globally disabled"
    )
    func remoteWithBridgeDisabledNeverSpawnsLocalShell() async throws {
        let fixture = try makeRemoteFixture(bridgeEnabled: false)

        // Global command bridge OFF: `createSurfaceIfNeeded` runs its
        // bridge-disabled pre-guard (clearing bridge state) but does NOT
        // short-circuit — it still reaches `prepareAttach(bridgeEnabled:
        // false)`, whose policy now routes a remote group to `.remoteUnavailable`
        // regardless of the toggle rather than `.localShell`.
        fixture.view.createSurfaceIfNeeded()

        // Same trust-boundary guarantee as the amx-missing case, reached
        // through the disabled-bridge gate instead (ADR-0022). Latch synchronous;
        // error chrome deferred (see the amx-missing case above).
        #expect(fixture.view.surface == nil)
        #expect(fixture.view.commandBridgeErrorLatched)
        await pumpMainQueue()
        let pane = try #require(fixture.livePane)
        #expect(pane.agentExecutionState == .error)
    }

    // MARK: - Remote-owned (`.remoteZmx`) panes

    @Test("a remote-owned pane attaches over ssh without minting a status channel")
    func remoteOwnedPrepareAttachMintsNoStatusChannel() throws {
        let fixture = try makeRemoteOwnedFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var providedSessionName: RemoteSessionName?
        var providedExecutablePath: String?
        enactor.remoteOwnedAttachCommandProvider = { target, sessionName, executablePath in
            providedSessionName = sessionName
            providedExecutablePath = executablePath
            return "ssh \(target.sshDestination) zmx attach \(sessionName.rawValue)"
        }

        let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)

        #expect(launch == .remoteOwnedAttach("ssh ed@example.invalid zmx attach work"))
        #expect(providedSessionName?.rawValue == "work")
        #expect(providedExecutablePath == "/opt/homebrew/bin/zmx")
        // Without the session id, `handleProcessExit` bails at its `sessionID
        // != nil` guard and the host silently closes a pane whose ssh died.
        #expect(enactor.sessionID == fixture.sessionID)
        // The far host reports into no local file: an armed watcher would sit on
        // a feed nothing ever writes, and the exit path must stay statusless.
        #expect(enactor.statusChannel == nil)
        #expect(enactor.statusWatcher == nil)
        #expect(statusFileNames(for: fixture.sessionID).isEmpty)

        // Control: prove the listing above can actually see a status file, so
        // the emptiness assertion isn't passing for the wrong reason.
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }
        #expect(statusFileNames(for: fixture.sessionID).count == 1)
    }

    @Test("a remote-owned clean exit (code 0) closes the pane like a local shell")
    func remoteOwnedCleanExitClosesPane() throws {
        let fixture = try makeRemoteOwnedFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionExistsProvider = { _ in
            Issue.record("a remote-owned pane must never probe the local amx daemon")
            return true
        }
        enactor.sessionID = fixture.sessionID

        // ssh forwards the remote shell's own status, so 0 is a deliberate
        // `exit` on the far side — INT-769 parity with a local shell.
        enactor.beginExitSupervision(exitCode: 0)

        #expect(enactor.sessionID == nil)
        #expect(!enactor.errorLatched)
        #expect(!enactor.exitProbeInFlight)
        #expect(fixture.livePane == nil)
    }

    @Test("a remote-owned abnormal exit latches the disconnected reconnect state")
    func remoteOwnedAbnormalExitLatchesDisconnected() throws {
        for exitCode in [Int16(255), nil] {
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionExistsProvider = { _ in
                Issue.record("a remote-owned pane must never probe the local amx daemon")
                return true
            }
            enactor.sessionID = fixture.sessionID

            enactor.beginExitSupervision(exitCode: exitCode)

            #expect(enactor.errorLatched)
            #expect(!enactor.exitProbeInFlight)
            let pane = try #require(fixture.livePane)
            #expect(pane.agentExecutionState == .error)
            #expect(
                pane.remoteReconnect == .disconnected(.init(target: try remoteOwnedTarget()))
            )
        }
    }

    @Test("a remote-owned exit with the bridge disabled never re-creates the surface")
    func remoteOwnedExitWithBridgeDisabledDoesNotLoop() throws {
        // The legacy exit path answers a bridge-disabled clean exit by clearing
        // state and re-driving surface creation — for a remote-owned pane the
        // policy would answer that with another remote-owned attach, forever.
        let fixture = try makeRemoteOwnedFixture(bridgeEnabled: false)
        let host = TestHost(fixture: fixture)
        let enactor = CommandBridgeEnactor(host: host)
        enactor.sessionExistsProvider = { _ in
            Issue.record("a remote-owned pane must never probe the local amx daemon")
            return true
        }
        enactor.sessionID = fixture.sessionID

        enactor.beginExitSupervision(exitCode: 0)

        #expect(host.closeAfterProcessExitCount == 1)
        #expect(host.scheduleSurfaceCreationCount == 0)
        #expect(enactor.sessionID == nil)
        #expect(!enactor.errorLatched)
    }

    @Test("a remote-owned spawn confirms a pending manual reconnect without a status event")
    func remoteOwnedSpawnConfirmsManualReconnect() throws {
        let fixture = try makeRemoteOwnedFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.markError()
        let target = try remoteOwnedTarget()
        #expect(fixture.livePane?.remoteReconnect == .disconnected(.init(target: target)))

        enactor.beginManualReconnect()
        #expect(fixture.livePane?.remoteReconnect == .reconnecting(.init(target: target)))

        // The re-spawn's only confirmation signal: there is no `attached` event
        // to wait for, so the overlay would otherwise stay painted forever.
        fixture.view.applyPostSpawnPaneState(for: .remoteOwnedAttach("ssh …"))

        #expect(fixture.livePane?.remoteReconnect == nil)
        #expect(!enactor.errorLatched)
    }

    @Test("only a local-amx attach stamps established backend metadata")
    func onlyBridgeAttachStampsEstablishedMetadata() throws {
        let remoteOwned = try makeRemoteOwnedFixture()
        // `established` names a LOCAL amx session; stamping it for a remote-owned
        // pane points the Path Bar's `amx cwd` poll at an id no local daemon has.
        remoteOwned.view.applyPostSpawnPaneState(for: .remoteOwnedAttach("ssh …"))
        #expect(remoteOwned.livePane?.terminalBackendMetadata == .empty)

        let bridge = try makeFixture()
        bridge.store.updateTerminalBackendMetadata(
            sessionID: bridge.hostSessionID,
            paneID: bridge.paneID,
            metadata: .empty
        )
        bridge.view.applyPostSpawnPaneState(for: .bridgeAttach("amx attach …"))
        #expect(bridge.livePane?.terminalBackendMetadata == establishedMetadata)
    }

    @Test("a remote-owned pane keeps its agent chrome; a plain local shell resets it")
    func remoteOwnedSpawnKeepsAgentChrome() throws {
        // A remote-owned attach re-joins a session that survives on the far
        // host, so a live agent's identity must survive with it — unlike a fresh
        // local shell, whose restored chrome is definitionally dead.
        let remoteOwned = try makeRemoteOwnedFixture(agentKind: .codex)
        remoteOwned.view.applyPostSpawnPaneState(for: .remoteOwnedAttach("ssh …"))
        #expect(remoteOwned.livePane?.agentKind == AgentKind.codex)

        let local = try makeAgentFixture()
        local.view.applyPostSpawnPaneState(for: .localShell)
        #expect(local.livePane?.agentKind == AgentKind.shell)
    }

    @Test("a remote-owned surface spawns the assembled ssh command, never a local shell")
    func remoteOwnedSurfaceSpawnsSSHCommand() throws {
        let fixture = try makeRemoteOwnedFixture()
        let spawned = SpawnedCommandBox()
        fixture.runtime.createSurfaceOverride = { _, _, _, command in
            spawned.record(command)
            return nil
        }
        fixture.view.commandBridgeEnactor.remoteOwnedAttachCommandProvider = { _, sessionName, _ in
            "remote-owned-\(sessionName.rawValue)"
        }

        fixture.view.createSurfaceIfNeeded()

        #expect(spawned.commands == ["remote-owned-work"])
        #expect(!fixture.view.commandBridgeErrorLatched)
        #expect(fixture.view.commandBridgeEnactor.statusChannel == nil)
        #expect(statusFileNames(for: fixture.sessionID).isEmpty)
    }

    @Test("a latched-error pane is inert to a stray attached event")
    func latchedPaneIgnoresStrayAttached() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.errorLatched = true

        // A stray `attached` line must not un-latch the pane or record an
        // incarnation while the user is looking at the error state.
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])

        #expect(enactor.errorLatched)
        #expect(enactor.respawnLedger.lastIncarnation == nil)
    }

    @Test("legacy heal synchronizes the host before remounting")
    func legacyHealSynchronizesHostBeforeRemounting() async throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionExistsProvider = { _ in true }
        enactor.sessionID = fixture.sessionID

        // Model a stale view payload while the store remains authoritative. The
        // degraded no-status path must install the heal result on the host just
        // like the status-driven path does before it remounts.
        fixture.view.pane.title = "stale host pane"
        #expect(fixture.view.pane != fixture.livePane)

        enactor.beginExitSupervision(exitCode: 0)
        await waitForLegacyProbeToSettle(enactor)

        let livePane = try #require(fixture.livePane)
        #expect(fixture.view.pane == livePane)
        #expect(fixture.view.paneID == livePane.id)
        #expect(enactor.sessionID == livePane.terminalSessionID)
    }

    @Test("status heal synchronizes the host before remounting")
    func statusHealSynchronizesHostBeforeRemounting() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        fixture.view.pane.title = "stale host pane"
        #expect(fixture.view.pane != fixture.livePane)

        try driveSessionEnd(fixture: fixture, reason: .daemonDied)

        let livePane = try #require(fixture.livePane)
        #expect(fixture.view.pane == livePane)
        #expect(fixture.view.paneID == livePane.id)
        #expect(enactor.sessionID == livePane.terminalSessionID)
    }

    @Test("legacy non-zero exit announces error entry")
    func legacyNonzeroExitAnnouncesError() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceErrorEntered = { announcements.append(.errorEntered) }

        enactor.sessionID = fixture.sessionID
        enactor.beginExitSupervision(exitCode: 1)

        #expect(enactor.errorLatched)
        #expect(announcements == [.errorEntered])
    }

    @Test("legacy missing session announces error entry")
    func legacyMissingSessionAnnouncesError() async throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceErrorEntered = { announcements.append(.errorEntered) }

        enactor.sessionExistsProvider = { _ in false }
        enactor.sessionID = fixture.sessionID
        enactor.beginExitSupervision(exitCode: 0)
        await waitForLegacyProbeToSettle(enactor)

        #expect(enactor.errorLatched)
        #expect(announcements == [.errorEntered])
    }

    @Test("session repoint cancels pending budget refill and stale work")
    func sessionRepointCancelsBudgetRefill() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.respawnLedger.recordRespawnAttempt()
        let recoveryRecord = try #require(enactor.recoveryRecord)
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])
        let pendingRefill = try #require(enactor.budgetRefillWorkItem)

        enactor.handleSessionRepoint()
        enactor.handleSessionRepoint()
        pendingRefill.perform()

        #expect(pendingRefill.isCancelled)
        #expect(enactor.budgetRefillWorkItem == nil)
        #expect(recoveryRecord.respawnLedger.respawnAttempts == 1)
    }

    @Test("surface teardown cancels pending budget refill and stale work")
    func surfaceTeardownCancelsBudgetRefill() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])
        enactor.respawnLedger.recordRespawnAttempt()
        let recoveryRecord = try #require(enactor.recoveryRecord)
        let pendingRefill = try #require(enactor.budgetRefillWorkItem)

        enactor.notifyNativeSurfaceDisposed()
        enactor.notifyNativeSurfaceDisposed()
        pendingRefill.perform()

        #expect(pendingRefill.isCancelled)
        #expect(enactor.budgetRefillWorkItem == nil)
        #expect(recoveryRecord.respawnLedger.respawnAttempts == 1)
    }

    @Test("new incarnation replaces pending budget refill and stale work cannot win")
    func newIncarnationReplacesBudgetRefill() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])
        let staleRefill = try #require(enactor.budgetRefillWorkItem)
        enactor.respawnLedger.recordRespawnAttempt()
        let recoveryRecord = try #require(enactor.recoveryRecord)

        enactor.handleStatusEvents([try attachedEvent(pid: 200, createdAt: 1_700_000_100, sessionID: fixture.sessionID)])
        let currentRefill = try #require(enactor.budgetRefillWorkItem)
        staleRefill.perform()

        #expect(staleRefill.isCancelled)
        #expect(staleRefill !== currentRefill)
        #expect(recoveryRecord.respawnLedger.respawnAttempts == 1)

        currentRefill.perform()
        #expect(recoveryRecord.respawnLedger.respawnAttempts == 0)
        #expect(enactor.budgetRefillWorkItem == nil)
    }

    @Test("session end cancels pending budget refill")
    func sessionEndCancelsBudgetRefill() throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.handleStatusEvents([try attachedEvent(pid: 100, createdAt: 1_700_000_000, sessionID: fixture.sessionID)])
        let pendingRefill = try #require(enactor.budgetRefillWorkItem)
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }
        enactor.beginStatusWatch(channel: channel)
        let event = try #require(
            Self.sessionEndEvent(
            token: channel.token,
            terminalSessionID: fixture.sessionID,
            reason: .detached
        ))

        enactor.handleStatusEvents([event])

        #expect(pendingRefill.isCancelled)
        #expect(enactor.budgetRefillWorkItem == nil)
    }

    @Test("suspended legacy probe does not retain enactor past host teardown")
    func suspendedLegacyProbeDoesNotRetainEnactor() async throws {
        let fixture = try makeFixture()
        var host: TestHost? = TestHost(fixture: fixture)
        var enactor: CommandBridgeEnactor? = CommandBridgeEnactor(host: try #require(host))
        var resumeProbe: (() -> Void)?
        enactor?.sessionExistsProvider = { _ in
            await withCheckedContinuation { continuation in
                resumeProbe = { continuation.resume(returning: false) }
            }
        }
        enactor?.sessionID = fixture.sessionID
        enactor?.beginExitSupervision(exitCode: 0)
        for _ in 0..<1_000 where resumeProbe == nil {
            await Task.yield()
        }
        #expect(resumeProbe != nil)

        weak let weakHost = host
        weak let weakEnactor = enactor
        enactor = nil
        host = nil

        #expect(weakHost == nil)
        #expect(weakEnactor == nil)
        resumeProbe?()
        await Task.yield()
    }

    @Test("stale legacy probe cannot win after same-identity repoint")
    func staleLegacyProbeCannotClearNewProbe() async throws {
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        let sessionID = fixture.sessionID
        var resumeOldProbe: (() -> Void)?
        var resumeNewProbe: (() -> Void)?
        var oldProbeReturned = false
        var probeCount = 0
        enactor.sessionExistsProvider = { sessionID in
            #expect(sessionID == fixture.sessionID)
            probeCount += 1
            await withCheckedContinuation { continuation in
                let resume = { continuation.resume(returning: ()) }
                if probeCount == 1 {
                    resumeOldProbe = resume
                } else {
                    resumeNewProbe = resume
                }
            }
            if probeCount == 2, resumeOldProbe != nil {
                oldProbeReturned = true
            }
            return false
        }

        enactor.sessionID = sessionID
        enactor.beginExitSupervision(exitCode: 0)
        for _ in 0..<1_000 where resumeOldProbe == nil {
            await Task.yield()
        }
        #expect(resumeOldProbe != nil)

        enactor.handleSessionRepoint()
        enactor.sessionID = sessionID
        enactor.beginExitSupervision(exitCode: 0)
        for _ in 0..<1_000 where resumeNewProbe == nil {
            await Task.yield()
        }
        #expect(resumeNewProbe != nil)
        #expect(enactor.exitProbeInFlight)

        resumeOldProbe?()
        for _ in 0..<1_000 where !oldProbeReturned {
            await Task.yield()
        }
        await Task.yield()

        #expect(oldProbeReturned)
        #expect(enactor.exitProbeInFlight)

        resumeNewProbe?()
        await waitForLegacyProbeToSettle(enactor)
    }

    // MARK: - Drivers

    /// Drain any `DispatchQueue.main.async` blocks the enactor deferred (the
    /// `.remoteUnavailable` error chrome hops one runloop tick to escape the
    /// layout pass). Suspending the MainActor via `Task.sleep` hands control
    /// back to the main run loop so those blocks execute before we assert.
    private func pumpMainQueue() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func waitForLegacyProbeToSettle(_ enactor: CommandBridgeEnactor) async {
        for _ in 0..<1_000 where enactor.exitProbeInFlight {
            await Task.yield()
        }
        #expect(!enactor.exitProbeInFlight)
    }

    /// Arm a fresh status channel, feed one `session-end`, and let the enactor
    /// decide. Mirrors the view suite's driver but pokes the enactor directly.
    private func driveSessionEnd(
        fixture: Fixture,
        reason: SessionEndReason,
        code: Int = 0
    ) throws {
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        let enactor = fixture.view.commandBridgeEnactor
        enactor.sessionID = fixture.sessionID
        enactor.beginStatusWatch(channel: channel)
        #expect(enactor.statusWatcher?.isArmed == true)

        let event = try #require(
            Self.sessionEndEvent(
            token: channel.token,
            terminalSessionID: fixture.sessionID,
            reason: reason,
            code: code
        ))
        enactor.handleStatusEvents([event])
    }

    private func attachedEvent(
        pid: Int,
        createdAt: Int,
        sessionID: TerminalSessionID
    ) throws -> AmxStatusEvent {
        try #require(
            Self.attachedStatusEvent(
                pid: pid,
                createdAt: createdAt,
                session: sessionID.rawValue
            )
        )
    }

    // MARK: - Event construction (matches AmxStatusChannel JSONL shape)

    private static func sessionEndEvent(
        token: String,
        terminalSessionID: TerminalSessionID,
        reason: SessionEndReason,
        code: Int = 0
    ) -> AmxStatusEvent? {
        let line = """
        {"event":"session-end","token":"\(token)","reason":"\(statusReason(reason))","code":\(code),"session":"\(terminalSessionID.rawValue)","ts":1700000001}
        """
        return AmxStatusEvent.parseLines(line + "\n", expectedToken: token).first
    }

    private static func attachedStatusEvent(
        pid: Int,
        createdAt: Int,
        session: String = "00000000-0000-4000-8000-000000000001"
    ) -> AmxStatusEvent? {
        let token = "tok"
        let line = """
            {"event":"attached","token":"\(token)","created":true,"daemon_pid":\(pid),"daemon_created_at":\(createdAt),"session":"\(session)","ts":1700000001}
            """
        return AmxStatusEvent.parseLines(line + "\n", expectedToken: token).first
    }

    private static func statusReason(_ reason: SessionEndReason) -> String {
        switch reason {
        case .daemonDied: "daemon-died"
        case .detached: "detached"
        case .shellExit: "shell-exit"
        case .unknown: "unknown"
        }
    }

    // MARK: - Fixtures

    private func makeFixture() throws -> Fixture {
        let sessionID = try #require(
            TerminalSessionID(
            rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ))
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "bridge",
            workingDirectory: "/tmp/bridge", executionPlan: .local)
        return try makeFixture(sessionID: sessionID, pane: pane)
    }

    private func makeAgentFixture() throws -> Fixture {
        let sessionID = try #require(
            TerminalSessionID(
            rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ))
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "codex",
            workingDirectory: "/tmp/agent",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt, executionPlan: .local)
        return try makeFixture(sessionID: sessionID, pane: pane)
    }

    /// A pane in a remote-tagged workgroup, never yet attached. `amx` being
    /// missing beside the test binary is what makes `attachCommandAvailable`
    /// false in `prepareAttach` — the real-world condition this guards, not a
    /// contrived one. `bridgeEnabled: false` models the global command-bridge
    /// toggle being off, which must still error rather than spawn a local shell.
    private func makeRemoteFixture(bridgeEnabled: Bool = true) throws -> Fixture {
        let sessionID = try #require(
            TerminalSessionID(
            rawValue: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        ))
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            title: "remote",
            workingDirectory: "/tmp",
            executionPlan: .ssh(
                SSHExecution(
                    target: RemoteTarget(user: "ed", host: "example.invalid")!
                )))
        let session = TerminalSession(
            title: "remote session",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [
                SessionGroup(
                name: "remote group",
                    remote: RemoteTarget(user: "ed", host: "example.invalid")!,
                sessions: [session]
                )
            ],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: bridgeEnabled)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return Fixture(
            sessionID: sessionID,
            hostSessionID: session.id,
            paneID: pane.id,
            session: session,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    /// A pane whose persistence the REMOTE host owns (`.remoteZmx`): the far
    /// side's zmx holds the session, so there is no local daemon, no status
    /// side channel, and nothing for the command bridge to wrap.
    private func makeRemoteOwnedFixture(
        bridgeEnabled: Bool = true,
        agentKind: AgentKind = .shell
    ) throws -> Fixture {
        let sessionID = try #require(
            TerminalSessionID(
                rawValue: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
            ))
        let remote = try remoteOwnedTarget()
        let execution = try #require(
            SSHExecution(
                target: remote,
                persistenceOwner: .remoteZmx,
                sessionName: RemoteSessionName(rawValue: "work"),
                remoteExecutablePath: "/opt/homebrew/bin/zmx"
            ))
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            title: "remote-owned",
            workingDirectory: "/tmp",
            agentKind: agentKind,
            executionPlan: .ssh(execution)
        )
        let session = TerminalSession(
            title: "remote-owned session",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [
                SessionGroup(name: "remote group", remote: remote, sessions: [session])
            ],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: bridgeEnabled)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return Fixture(
            sessionID: sessionID,
            hostSessionID: session.id,
            paneID: pane.id,
            session: session,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    private func remoteOwnedTarget() throws -> RemoteTarget {
        try #require(RemoteTarget(user: "ed", host: "example.invalid"))
    }

    /// Status files are named `<session>-<token prefix>.status.jsonl`, so a
    /// session-prefixed listing of the socket directory is how "no channel was
    /// ever minted" is proven — `statusChannel == nil` alone would also hold for
    /// a channel that was minted and then deleted.
    private func statusFileNames(for sessionID: TerminalSessionID) -> [String] {
        let directory = AmxBackend.sessionSocketDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix(sessionID.rawValue) }
    }

    private func makeFixture(sessionID: TerminalSessionID, pane: TerminalPane) throws -> Fixture {
        let session = TerminalSession(
            title: "session",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return Fixture(
            sessionID: sessionID,
            hostSessionID: session.id,
            paneID: pane.id,
            session: session,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    private struct Fixture {
        /// The bridge terminal-session identity (`amx` session id).
        let sessionID: TerminalSessionID
        /// The owning `TerminalSession.ID` used to key the store.
        let hostSessionID: TerminalSession.ID
        let paneID: TerminalPane.ID
        let session: TerminalSession
        let store: SessionStore
        let runtime: GhosttyRuntime
        let view: GhosttySurfaceNSView

        @MainActor var livePane: TerminalPane? {
            store.session(id: hostSessionID)?.layout.pane(id: paneID)
        }
    }

    private final class TestHost: CommandBridgeEnactorHost {
        let runtime: GhosttyRuntime
        let sessionStore: SessionStore
        let sessionID: TerminalSession.ID
        var paneID: TerminalPane.ID
        var pane: TerminalPane
        var terminalIsFocused = false
        var hasNativeSurface = false
        var commandExitCache = CommandExitCache()
        var shellCommandFinishedIdleLatched = false

        init(fixture: Fixture) {
            runtime = fixture.runtime
            sessionStore = fixture.store
            sessionID = fixture.hostSessionID
            paneID = fixture.paneID
            pane = fixture.view.pane
        }

        private(set) var closeAfterProcessExitCount = 0
        private(set) var scheduleSurfaceCreationCount = 0

        func disposeNativeSurface(resetHostedLayer: Bool) {}
        func remountFreshSurfaceAfterCommandBridgeHeal(
            _ recovery: SessionStore.CommandBridgePaneHealResult
        ) {}
        func closeAfterProcessExit(processAlive: Bool) {
            closeAfterProcessExitCount += 1
        }
        func scheduleSurfaceCreationIfNeeded() {
            scheduleSurfaceCreationCount += 1
        }
    }

    /// Records what `runtime.createSurface` was actually asked to spawn. The
    /// override returns nil (a fabricated `ghostty_surface_t` would be freed for
    /// real on view teardown), so this proves the command, not the surface.
    private final class SpawnedCommandBox {
        private(set) var commands: [String?] = []

        func record(_ command: String?) {
            commands.append(command)
        }
    }
}
