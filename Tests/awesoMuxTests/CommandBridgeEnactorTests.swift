import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Observation
import Synchronization
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
        /// Claims the session is back. Only an `attached` status event earns it.
        case remoteReconnected(host: String?)
        /// Claims only that a reconnect was dialed.
        case remoteReconnectStarted(host: String?)
    }

    private let establishedMetadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

    @Test(arguments: [false, true], [false, true])
    func freshIncarnationClearsTransientState(established: Bool, created: Bool) async throws {
        let pane = TerminalPane(
            terminalBackendMetadata: established ? establishedMetadata : .empty,
            title: "restart notice",
            workingDirectory: "/tmp", executionPlan: .local
        )
        let candidate = try makeFixture(sessionID: pane.terminalSessionID, pane: pane)
        let bridge = candidate.view.commandBridgeEnactor
        bridge.attachCommandProvider = { _, _, _, _ in "amx attach" }
        var notices = 0
        bridge.announceSessionRespawnedFresh = { _, _ in notices += 1 }
        let launch = bridge.prepareAttach(for: pane, bridgeEnabled: true)
        candidate.view.applyPostSpawnPaneState(for: launch)
        // A failed first attach may prepare again after the spawn stamp.
        // It must keep the original saved-pane classification.
        _ = bridge.prepareAttach(for: try #require(candidate.livePane), bridgeEnabled: true)
        let event = try attachedEvent(
            pid: 300, createdAt: 1_700_000_200,
            sessionID: pane.terminalSessionID, created: created
        )
        bridge.handleStatusEvents([event, event])
        #expect(notices == (established && created ? 1 : 0))
        #expect((candidate.runtime.restartedSessionNotices[pane.id] != nil) == (established && created))
        candidate.runtime.discardSurface(for: pane.id, preservingRestartNotice: true)
        #expect((candidate.runtime.restartedSessionNotices[pane.id] != nil) == (established && created))
        candidate.runtime.discardSurface(for: pane.id)
        await awaitSignal { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!(candidate.runtime.restartedSessionNotices[pane.id] != nil))
        candidate.runtime.restartedSessionNotices[pane.id] = UUID()
        bridge.markError()
        #expect(!(candidate.runtime.restartedSessionNotices[pane.id] != nil))
    }

    enum ExitOutcomesCase: String, CaseIterable {
        case cleanExitClearsStateAndCloses
        case remoteCleanShellExitClosesPane
        case remoteAbnormalShellExitLatchesErrorWithoutClosing
        case remoteOwnedCleanExitClosesPane
        case remoteOwnedAbnormalExitLatchesDisconnected
        case remoteOwnedExitIgnoresStaleCommandExitCache
        case remoteOwnedExitWithBridgeDisabledDoesNotLoop
        case reconnectSpendsNoBudgetAndKeepsChrome
    }

    @Test(arguments: ExitOutcomesCase.allCases)
    func exitOutcomes(_ scenario: ExitOutcomesCase) async throws {
        switch scenario {
        case .cleanExitClearsStateAndCloses:
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
        case .remoteCleanShellExitClosesPane:
            let fixture = try makeRemoteFixture()
            let enactor = fixture.view.commandBridgeEnactor

            // ssh returns 0 when the user (or remote shell) exits cleanly. That should
            // close the pane like a local shell, not leave a corpse in an error state.
            try driveSessionEnd(fixture: fixture, reason: .shellExit, code: 0)

            #expect(enactor.sessionID == nil)
            #expect(!enactor.errorLatched)
            #expect(!enactor.exitProbeInFlight)
            #expect(fixture.livePane == nil)
        case .remoteAbnormalShellExitLatchesErrorWithoutClosing:
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
        case .remoteOwnedCleanExitClosesPane:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionExistsProvider = { _ in
                Issue.record("a remote-owned pane must never probe the local amx daemon")
                return true
            }
            enactor.sessionID = fixture.sessionID
            // ssh forwards the remote shell's own status, so 0 is a deliberate
            // `exit` on the far side — INT-769 parity with a local shell.
            stubRemoteOwnedExitStatus(0, on: enactor)

            enactor.beginExitSupervision(exitCode: nil)

            #expect(enactor.sessionID == nil)
            #expect(!enactor.errorLatched)
            #expect(!enactor.exitProbeInFlight)
            #expect(fixture.livePane == nil)
        case .remoteOwnedAbnormalExitLatchesDisconnected:
            for status in [Int16(255), Int16(127), nil] {
                let fixture = try makeRemoteOwnedFixture()
                // Failures: read-after-dispose, oversized/control text, nil recapture
                // erasing diagnostics, duplicate exits wedging retry, and persistence.
                let host = TestHost(fixture: fixture)
                host.hasNativeSurface = true
                host.terminalText = String(repeating: "α", count: 5000) + "\rError marker Ｆ\u{202E}\u{001B}\n\n"
                let enactor = CommandBridgeEnactor(host: host)
                enactor.sessionExistsProvider = { _ in
                    Issue.record("a remote-owned pane must never probe the local amx daemon")
                    return true
                }
                enactor.sessionID = fixture.sessionID
                stubRemoteOwnedExitStatus(status, on: enactor)

                enactor.beginExitSupervision(exitCode: nil)

                #expect(enactor.errorLatched)
                #expect(!enactor.exitProbeInFlight)
                let pane = try #require(fixture.livePane)
                #expect(pane.agentExecutionState == .error)
                let diagnostic = try #require(pane.remoteReconnect?.context.diagnosticText)
                #expect(diagnostic.utf8.count <= 4096)
                #expect(diagnostic.contains("Error marker Ｆ"))
                #expect(!diagnostic.contains("\r") && !diagnostic.contains("\u{202E}") && !diagnostic.contains("\u{001B}"))
                #expect(host.exitEvents == ["read", "dispose"])
                #expect(!host.hasNativeSurface)
                #expect(!String(decoding: try JSONEncoder().encode(pane), as: UTF8.self).contains("Error marker"))
                #expect(enactor.handleChildExited())
                await Task.yield()
                #expect(!enactor.exitResolutionPending)
                #expect(fixture.livePane?.remoteReconnect?.context.diagnosticText == diagnostic)
                #expect(fixture.livePane?.remoteReconnect?.context.displacedNonErrorState == true)
                enactor.beginManualReconnect()
                #expect(!enactor.errorLatched)
                enactor.markError()
                #expect(fixture.livePane?.remoteReconnect?.context.displacedNonErrorState == true)
                #expect(fixture.livePane?.remoteReconnect?.context.diagnosticText == nil)
                enactor.beginManualReconnect()
                #expect(!enactor.errorLatched)
                #expect(fixture.store.confirmPaneRemoteReconnected(sessionID: fixture.hostSessionID, paneID: fixture.paneID))
                #expect(fixture.livePane?.agentExecutionState == .idle)
                #expect(fixture.livePane?.remoteReconnect == nil)
                host.hasNativeSurface = true
                enactor.beginExitSupervision(exitCode: nil)
                #expect(enactor.errorLatched)
                #expect(fixture.livePane?.remoteReconnect?.context.diagnosticText == nil)
            }
        case .remoteOwnedExitIgnoresStaleCommandExitCache:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionID = fixture.sessionID
            // What a remote `grep` with no match leaves behind.
            fixture.view.handleCommandFinished(exitCode: 1)
            stubRemoteOwnedExitStatus(0, on: enactor)

            enactor.beginExitSupervision(exitCode: 1)

            #expect(!enactor.errorLatched)
            #expect(fixture.livePane == nil)
        case .remoteOwnedExitWithBridgeDisabledDoesNotLoop:
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
            stubRemoteOwnedExitStatus(0, on: enactor)

            enactor.beginExitSupervision(exitCode: nil)

            #expect(host.closeAfterProcessExitCount == 1)
            #expect(host.scheduleSurfaceCreationCount == 0)
            #expect(enactor.sessionID == nil)
            #expect(!enactor.errorLatched)
        case .reconnectSpendsNoBudgetAndKeepsChrome:
            let fixture = try makeAgentFixture()
            let enactor = fixture.view.commandBridgeEnactor
            var announcements: [Announcement] = []
            enactor.announceSessionRespawnedFresh = { _, _ in announcements.append(.freshRespawn) }
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
    }

    @Test("carrier status mint failure uses the direct SSH exit file")
    func remoteOwnedCarrierWithoutStatusFallsBack() throws {
        let fixture = try makeRemoteOwnedFixture(bridgeEnabled: true)
        let enactor = fixture.view.commandBridgeEnactor
        enactor.remoteOwnedCarrierCommandProvider = { _, _, _, _ in "carrier" }
        enactor.statusChannelProvider = { _ in nil }
        let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)
        guard case .remoteOwnedAttach = launch else {
            Issue.record("expected direct SSH fallback")
            return
        }
        #expect(enactor.remoteOwnedExitStatusFile != nil)
        #expect(enactor.statusWatcher == nil)
        enactor.remoteOwnedExitStatusConsumer = { _ in 0 }
        enactor.beginExitSupervision(exitCode: 0)
        #expect(!enactor.errorLatched)
        #expect(enactor.sessionID == nil)
    }

    @Test(arguments: [false, true])
    func remoteOwnedCarrierIgnoresBridgeToggle(bridgeEnabled: Bool) throws {
        let fixture = try makeRemoteOwnedFixture(bridgeEnabled: bridgeEnabled, agentKind: .codex)
        let enactor = fixture.view.commandBridgeEnactor
        defer { enactor.beginStatusWatch(channel: nil) }
        enactor.remoteOwnedCarrierCommandProvider = { id, status, execution, _ in
            #expect(execution.sessionName?.rawValue == "work")
            return "carrier \(id.rawValue) status=\(status != nil)"
        }
        let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: bridgeEnabled)
        #expect(launch == .bridgeAttach("carrier \(fixture.sessionID.rawValue) status=true"))
        #expect(enactor.statusWatcher?.isArmed == true)
        #expect(enactor.remoteOwnedExitStatusFile == nil)
        fixture.view.applyPostSpawnPaneState(for: launch)
        #expect(fixture.livePane?.terminalBackendMetadata == .amxRemoteCarrier)
        #expect(fixture.store.localAPITerminalWatchTarget(paneID: fixture.paneID)?.localSessionName == fixture.sessionID.rawValue)
        enactor.handleStatusEvents([try attachedEvent(pid: 123, createdAt: 1, sessionID: fixture.sessionID)])
        #expect(fixture.livePane?.terminalBackendMetadata == .amxRemoteCarrier)
        #expect(fixture.livePane?.agentKind == AgentKind.codex)
        #expect(fixture.runtime.restartedSessionNotices[fixture.paneID] == nil)
        fixture.store.updateTerminalBackendMetadata(
            sessionID: fixture.hostSessionID, paneID: fixture.paneID,
            metadata: TerminalBackendMetadata(rawValue: "amx:recovery:existing"))
        fixture.view.pane = try #require(fixture.livePane)
        fixture.view.applyPostSpawnPaneState(for: launch)
        #expect(fixture.livePane?.terminalBackendMetadata.amxAttachDisposition == .existingOnly)
        enactor.beginExitSupervision(exitCode: 0)
        #expect(enactor.errorLatched)
        #expect(fixture.livePane?.terminalBackendMetadata.amxAttachDisposition == .existingOnly)
    }

    @Test(arguments: [false, true])
    func remoteOwnedCarrierExitPreservesSSHOutcome(bridgeEnabled: Bool) throws {
        for (reason, code): (SessionEndReason?, Int?) in [
            (.shellExit, 0), (.shellExit, 1), (.shellExit, 127), (.shellExit, 255),
            (.shellExit, nil), (.daemonDied, 0), (.detached, 0), (nil, nil),
        ] {
            let fixture = try makeRemoteOwnedFixture(bridgeEnabled: bridgeEnabled)
            let enactor = fixture.view.commandBridgeEnactor
            defer { enactor.beginStatusWatch(channel: nil) }
            enactor.sessionID = fixture.sessionID
            let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
            enactor.beginStatusWatch(channel: channel)
            fixture.view.applyPostSpawnPaneState(for: .bridgeAttach("carrier"))
            enactor.latestSessionEndReason = reason
            enactor.latestSessionEndCode = code
            // Stale far-side OSC reports must never decide SSH's outcome.
            enactor.beginExitSupervision(exitCode: 0)
            if reason == .shellExit && code == 0 {
                #expect(!enactor.errorLatched)
                #expect(enactor.sessionID == nil)
            } else {
                #expect(enactor.errorLatched)
                #expect(fixture.livePane?.remoteReconnect == .disconnected(.init(target: try remoteOwnedTarget())))
                #expect(fixture.livePane?.terminalBackendMetadata == .empty)
            }
            #expect(enactor.respawnLedger.respawnAttempts == 0)
        }
    }

    enum NoStatusWatcherCase: String, CaseIterable {
        case noStatusAttachClearsPreviousStatusWatcher
        case bridgeAttachWithoutChannelBearingCommandArmsNoWatcher
        case remoteOwnedPrepareAttachMintsNoStatusChannel
        case remoteOwnedAttachDropsStaleStatusWatcher
    }

    @Test(arguments: NoStatusWatcherCase.allCases)
    func noStatusWatcher(_ scenario: NoStatusWatcherCase) throws {
        switch scenario {
        case .noStatusAttachClearsPreviousStatusWatcher:
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
        case .bridgeAttachWithoutChannelBearingCommandArmsNoWatcher:
            let fixture = try makeFixture()
            let enactor = fixture.view.commandBridgeEnactor
            // The availability probe (`status == nil`) succeeds while the
            // channel-bearing rebuild fails. Arming off the mint alone would leave a
            // watcher on a file the spawned command never names, and the exit path
            // would then trust that permanently empty feed.
            enactor.attachCommandProvider = { sessionID, status, _, _ in
                status == nil ? "amx attach \(sessionID.rawValue)" : nil
            }

            let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)

            #expect(launch == .bridgeAttach("amx attach \(fixture.sessionID.rawValue)"))
            #expect(enactor.statusWatcher == nil)
            #expect(enactor.statusChannel == nil)
            #expect(statusFileNames(for: fixture.sessionID).isEmpty)
        case .remoteOwnedPrepareAttachMintsNoStatusChannel:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            var providedSessionName: RemoteSessionName?
            enactor.remoteOwnedAttachCommandProvider = { target, sessionName, _ in
                providedSessionName = sessionName
                return "ssh \(target.sshDestination) zmx attach \(sessionName.rawValue)"
            }

            let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)

            #expect(launch == .remoteOwnedAttach("ssh ed@example.invalid zmx attach work"))
            #expect(providedSessionName?.rawValue == "work")
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
        case .remoteOwnedAttachDropsStaleStatusWatcher:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
            defer { try? FileManager.default.removeItem(at: channel.fileURL) }

            // Models a pane re-pointed from a bridge session to a remote-owned one
            // without `handleSessionRepoint` having run first: the far host writes
            // nothing to this feed, so the arm must not survive the attach.
            enactor.beginStatusWatch(channel: channel)
            let staleWatcher = try #require(enactor.statusWatcher)
            #expect(staleWatcher.isArmed)

            _ = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)

            #expect(!staleWatcher.isArmed)
            #expect(enactor.statusWatcher == nil)
            #expect(enactor.statusChannel == nil)
        }
    }

    enum ForegroundEvidenceCase: String, CaseIterable {
        case foregroundCommUsesCurrentDaemon
        case nudgeForegroundCommFailsClosed
    }

    @Test(arguments: ForegroundEvidenceCase.allCases)
    func foregroundEvidence(_ scenario: ForegroundEvidenceCase) throws {
        switch scenario {
        case .foregroundCommUsesCurrentDaemon:
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
        case .nudgeForegroundCommFailsClosed:
            let fixture = try makeFixture()

            // Non-bridged pane with no live surface: the quit-gate sampler has no
            // pid to read, so the nudge evidence must be nil (deny), never a guess.
            #expect(fixture.view.commandBridgeEnactor.sessionID == nil)
            #expect(fixture.view.documentNudgeForegroundComm() == nil)

            // Bridged pane with no recorded daemon incarnation: same deny.
            fixture.view.commandBridgeEnactor.sessionID = fixture.sessionID
            #expect(fixture.view.documentNudgeForegroundComm() == nil)
        }
    }

    enum StrayStatusEventsCase: String, CaseIterable {
        case mismatchedSessionStatusIsIgnored
        case latchedPaneIgnoresStrayAttached
    }

    @Test(arguments: StrayStatusEventsCase.allCases)
    func strayStatusEvents(_ scenario: StrayStatusEventsCase) throws {
        switch scenario {
        case .mismatchedSessionStatusIsIgnored:
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
        case .latchedPaneIgnoresStrayAttached:
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
    }

    enum RemoteNeverSpawnsLocalShellCase: String, CaseIterable {
        case remoteUnavailableNeverSpawnsLocalShell
        case remoteWithBridgeDisabledNeverSpawnsLocalShell
    }

    @Test(arguments: RemoteNeverSpawnsLocalShellCase.allCases)
    func remoteNeverSpawnsLocalShell(_ scenario: RemoteNeverSpawnsLocalShellCase) async throws {
        let bridgeEnabled = scenario == .remoteUnavailableNeverSpawnsLocalShell
        let fixture = try makeRemoteFixture(bridgeEnabled: bridgeEnabled)
        fixture.view.createSurfaceIfNeeded()
        #expect(fixture.view.surface == nil)
        #expect(fixture.view.commandBridgeErrorLatched)
        await pumpMainQueue()
        let pane = try #require(fixture.livePane)
        #expect(pane.agentExecutionState == .error)
    }

    // MARK: - Remote-owned (`.remoteZmx`) panes

    /// The pane's exit used to sit behind libghostty's "Press any key to close
    /// the terminal." screen: setting a surface command forces
    /// `wait-after-command` on, and a remote-owned pane has no status feed to
    /// act on instead. Claiming the child-exited action is what closes that gap.
    ///
    /// The claim must be answered synchronously, but the teardown must NOT run
    /// before the action returns: `Surface.childExited` keeps using the surface
    /// afterward and supervision frees it. Asserting the pane is still alive at
    /// return is what fails if anyone re-inlines the teardown.
    enum ChildExitCase: String, CaseIterable {
        case remoteOwnedChildExitDefersSupervision
        case remoteOwnedChildExitFailureLatchesOverlay
        case remoteOwnedRepeatedChildExitEnactsOnce
        case ordinaryBridgeChildExitDefersSupervision
        case statuslessBridgeChildExitUsesLegacyFallback
        case localShellChildExitIsNotClaimed
    }

    @Test(arguments: ChildExitCase.allCases)
    func childExit(_ scenario: ChildExitCase) async throws {
        switch scenario {
        case .remoteOwnedChildExitDefersSupervision:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionExistsProvider = { _ in
                Issue.record("a remote-owned pane must never probe the local amx daemon")
                return true
            }
            enactor.sessionID = fixture.sessionID
            stubRemoteOwnedExitStatus(0, on: enactor)

            #expect(fixture.view.handleChildExited())

            // Nothing freed yet — this is the invariant the C boundary depends on.
            #expect(enactor.sessionID == fixture.sessionID)
            #expect(fixture.livePane != nil)

            await Task.yield()

            #expect(enactor.sessionID == nil)
            #expect(!enactor.errorLatched)
            #expect(fixture.livePane == nil)
        case .remoteOwnedChildExitFailureLatchesOverlay:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionID = fixture.sessionID
            stubRemoteOwnedExitStatus(255, on: enactor)

            #expect(fixture.view.handleChildExited())
            await Task.yield()

            #expect(enactor.errorLatched)
            let pane = try #require(fixture.livePane)
            #expect(pane.remoteReconnect == .disconnected(.init(target: try remoteOwnedTarget())))
        case .remoteOwnedRepeatedChildExitEnactsOnce:
            let fixture = try makeRemoteOwnedFixture()
            let enactor = fixture.view.commandBridgeEnactor
            enactor.sessionID = fixture.sessionID
            var consumed = 0
            enactor.remoteOwnedExitStatusFile = URL(fileURLWithPath: "/tmp/unused.exit")
            enactor.remoteOwnedExitStatusConsumer = { _ in
                consumed += 1
                return 0
            }

            #expect(fixture.view.handleChildExited())
            #expect(fixture.view.handleChildExited())
            await Task.yield()

            #expect(consumed == 1)
        case .ordinaryBridgeChildExitDefersSupervision:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "99999999-9999-4999-8999-999999999999"))
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    terminalBackendMetadata: establishedMetadata,
                    title: "silent bridge",
                    workingDirectory: "/tmp/silent-bridge",
                    executionPlan: .local
                )
            )
            let enactor = fixture.view.commandBridgeEnactor
            let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.sessionID))
            defer { try? FileManager.default.removeItem(at: channel.fileURL) }

            enactor.sessionID = fixture.sessionID
            enactor.beginStatusWatch(channel: channel)
            #expect(enactor.statusWatcher?.isArmed == true)

            // No session-end was written: this is the killed/crashed attach-client
            // shape, not a direct beginExitSupervision shortcut.
            #expect(fixture.view.handleChildExited())
            #expect(enactor.sessionID == fixture.sessionID)
            #expect(!enactor.exitProbeInFlight)
            #expect(fixture.livePane != nil)

            await Task.yield()

            #expect(!enactor.errorLatched)
            #expect(enactor.respawnLedger.respawnAttempts == 1)
            #expect(fixture.livePane != nil)
        case .statuslessBridgeChildExitUsesLegacyFallback:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "88888888-8888-4888-8888-888888888888"))
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    terminalBackendMetadata: establishedMetadata,
                    title: "statusless bridge",
                    workingDirectory: "/tmp/statusless-bridge",
                    executionPlan: .local
                )
            )
            let enactor = fixture.view.commandBridgeEnactor
            var sessionExistenceProbes = 0
            enactor.sessionExistsProvider = { sessionID in
                #expect(sessionID == fixture.sessionID)
                sessionExistenceProbes += 1
                return true
            }

            enactor.sessionID = fixture.sessionID
            #expect(enactor.statusWatcher == nil)

            #expect(fixture.view.handleChildExited())
            // libghostty can deliver COMMAND_FINISHED on its queued main-actor hop
            // after the synchronous child-exited decision.
            fixture.view.commandExitCache.record(
                exitCode: 0,
                at: Date().timeIntervalSinceReferenceDate
            )
            #expect(enactor.sessionID == fixture.sessionID)
            #expect(!enactor.exitProbeInFlight)

            await Task.yield()
            await waitForLegacyProbeToSettle(enactor)

            #expect(sessionExistenceProbes == 1)
            #expect(!enactor.errorLatched)
            #expect(fixture.livePane != nil)
        case .localShellChildExitIsNotClaimed:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"))
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    title: "local",
                    workingDirectory: "/tmp",
                    executionPlan: .local
                )
            )

            #expect(!fixture.view.handleChildExited())
            #expect(fixture.livePane != nil)
        }
    }

    /// An ordinary bridge attach has the same wait-after-command hazard as a
    /// remote-owned attach when its client dies before writing session-end.

    @Test(
        "pre-attach recovery failures preserve existing-only metadata after deferred error chrome",
        arguments: [false, true]
    )
    func preAttachRecoveryFailurePreservesMetadata(channelCommandUnavailable: Bool) async throws {
        let sessionID = TerminalSessionID.generate()
        let existingOnly = TerminalBackendMetadata(rawValue: "amx:v1:existing-only")
        let fixture = try makeFixture(
            sessionID: sessionID,
            pane: TerminalPane(
                terminalSessionID: sessionID,
                terminalBackendMetadata: existingOnly,
                title: "recover",
                workingDirectory: "/tmp/recover",
                executionPlan: .local
            )
        )
        let enactor = fixture.view.commandBridgeEnactor
        if channelCommandUnavailable {
            SessionRecoveryConfirmationCenter.shared.begin(
                sessionID, daemonPID: 42, createdEpoch: 100
            )
        }
        defer { SessionRecoveryConfirmationCenter.shared.cancel(sessionID) }
        var sawChannelCommand = false
        enactor.attachCommandProvider = { _, channel, _, mode in
            #expect(mode == .existingOnly)
            if channel != nil {
                sawChannelCommand = true
                if channelCommandUnavailable { return nil }
            }
            return "amx attach --existing"
        }

        let launch = enactor.prepareAttach(for: fixture.view.pane, bridgeEnabled: true)

        #expect(sawChannelCommand)
        #expect(launch == .localShell)
        #expect(enactor.errorLatched)
        await pumpMainQueue()

        #expect(fixture.livePane?.agentExecutionState == .error)
        #expect(fixture.livePane?.terminalBackendMetadata == existingOnly)
        #expect(enactor.statusWatcher == nil)
        #expect(enactor.respawnLedger.respawnAttempts == 0)
    }

    enum ExistingOnlyFailsClosedCase: String, CaseIterable {
        case failedExistingOnlyAttachDoesNotRespawn
        case rejectedRecoveryIdentityDoesNotEstablish
        case existingOnlyWithoutArmedStatusFailsClosed
    }

    @Test(arguments: ExistingOnlyFailsClosedCase.allCases)
    func existingOnlyFailsClosed(_ scenario: ExistingOnlyFailsClosedCase) async throws {
        switch scenario {
        case .failedExistingOnlyAttachDoesNotRespawn:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "77777777-7777-4777-8777-777777777777"))
            let existingOnly = TerminalBackendMetadata(rawValue: "amx:v1:existing-only")
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    terminalBackendMetadata: existingOnly,
                    title: "recover",
                    workingDirectory: "/tmp/recover",
                    executionPlan: .local
                )
            )
            let enactor = fixture.view.commandBridgeEnactor
            let channel = try #require(AmxBackend.makeStatusChannel(for: sessionID))
            defer { try? FileManager.default.removeItem(at: channel.fileURL) }
            SessionRecoveryConfirmationCenter.shared.begin(
                sessionID, daemonPID: 42, createdEpoch: 100
            )
            let expectationToken = try #require(
                SessionRecoveryConfirmationCenter.shared.expectationToken(for: sessionID)
            )
            enactor.sessionID = sessionID
            enactor.beginStatusWatch(
                channel: channel, recoveryExpectationToken: expectationToken
            )
            SessionRecoveryConfirmationCenter.shared.didStartAttach(sessionID)

            fixture.view.applyPostSpawnPaneState(for: .bridgeAttach("amx attach --existing …"))
            #expect(fixture.livePane?.terminalBackendMetadata == existingOnly)

            #expect(fixture.view.handleChildExited())
            await Task.yield()

            #expect(enactor.errorLatched)
            #expect(enactor.respawnLedger.respawnAttempts == 0)
            #expect(
                fixture.livePane?.terminalBackendMetadata.amxAttachDisposition == .existingOnly
            )
            #expect(
                await SessionRecoveryConfirmationCenter.shared.wait(
                    for: sessionID, timeout: .milliseconds(10)
                ) == false
            )
        case .rejectedRecoveryIdentityDoesNotEstablish:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "66666666-6666-4666-8666-666666666666"))
            let existingOnly = TerminalBackendMetadata(rawValue: "amx:v1:existing-only")
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    terminalBackendMetadata: existingOnly,
                    title: "recover",
                    workingDirectory: "/tmp/recover",
                    executionPlan: .local
                )
            )
            let enactor = fixture.view.commandBridgeEnactor
            SessionRecoveryConfirmationCenter.shared.begin(
                sessionID, daemonPID: 42, createdEpoch: 100
            )
            let token = try #require(
                SessionRecoveryConfirmationCenter.shared.expectationToken(for: sessionID)
            )
            enactor.sessionID = sessionID

            enactor.handleStatusEvents(
                [try attachedEvent(pid: 99, createdAt: 101, sessionID: sessionID)],
                recoveryExpectationToken: token
            )

            #expect(enactor.errorLatched)
            #expect(fixture.livePane?.terminalBackendMetadata == existingOnly)
            #expect(enactor.respawnLedger.respawnAttempts == 0)

            enactor.sessionExistsProvider = { _ in
                Issue.record("rejected recovery must not enter the legacy probe")
                return true
            }
            enactor.beginExitSupervision(exitCode: 0)
            await Task.yield()

            #expect(enactor.errorLatched)
            #expect(enactor.respawnLedger.respawnAttempts == 0)
            #expect(
                fixture.livePane?.terminalBackendMetadata.amxAttachDisposition == .existingOnly
            )
            #expect(
                await SessionRecoveryConfirmationCenter.shared.wait(
                    for: sessionID, timeout: .milliseconds(10)
                ) == false
            )
        case .existingOnlyWithoutArmedStatusFailsClosed:
            let sessionID = try #require(
                TerminalSessionID(rawValue: "55555555-5555-4555-8555-555555555555"))
            let fixture = try makeFixture(
                sessionID: sessionID,
                pane: TerminalPane(
                    terminalSessionID: sessionID,
                    terminalBackendMetadata: TerminalBackendMetadata(
                        rawValue: "amx:v1:existing-only"
                    ),
                    title: "recover",
                    workingDirectory: "/tmp/recover",
                    executionPlan: .local
                )
            )
            let host = TestHost(fixture: fixture)
            host.hasNativeSurface = true
            let enactor = CommandBridgeEnactor(host: host)
            enactor.errorLatched = true
            SessionRecoveryConfirmationCenter.shared.begin(
                sessionID, daemonPID: 42, createdEpoch: 100
            )
            SessionRecoveryConfirmationCenter.shared.didStartAttach(sessionID)
            enactor.sessionID = sessionID
            enactor.sessionExistsProvider = { _ in
                Issue.record("existing-only failure must not enter the legacy probe")
                return true
            }

            enactor.beginExitSupervision(exitCode: 0)
            await Task.yield()

            #expect(enactor.errorLatched)
            #expect(host.disposeCount == 1 && !host.hasNativeSurface)
            #expect(enactor.respawnLedger.respawnAttempts == 0)
            #expect(
                fixture.livePane?.terminalBackendMetadata.amxAttachDisposition == .existingOnly
            )
            #expect(
                await SessionRecoveryConfirmationCenter.shared.wait(
                    for: sessionID, timeout: .milliseconds(10)
                ) == false
            )
        }
    }

    /// A plain local shell has no managed bridge identity, so libghostty keeps
    /// its normal child-exit handling and press-any-key behavior.

    @Test("manual reconnect announces its attempt and relatches on failure")
    func manualReconnectSequence() throws {
        let fixture = try makeRemoteOwnedFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceRemoteReconnected = { host, _ in
            announcements.append(.remoteReconnected(host: host))
        }
        enactor.announceRemoteReconnectStarted = { host, _ in
            announcements.append(.remoteReconnectStarted(host: host))
        }
        enactor.sessionID = fixture.sessionID
        enactor.markError()
        #expect(fixture.livePane?.remoteReconnect == .disconnected(.init(target: try remoteOwnedTarget())))
        enactor.beginManualReconnect()
        #expect(fixture.livePane?.remoteReconnect == .reconnecting(.init(target: try remoteOwnedTarget())))

        // The spawn succeeds — libghostty forked a local ssh child. That says
        // nothing about `example.invalid`, which by RFC 2606 can never resolve,
        // so this models every unreachable-host/pending-auth/missing-zmx
        // reconnect: the local process starts and the attach still fails.
        fixture.view.applyPostSpawnPaneState(for: .remoteOwnedAttach("ssh …"))

        #expect(announcements == [.remoteReconnectStarted(host: "example.invalid")])
        // The overlay still clears on spawn (there is no `attached` event to
        // wait for), so the announcement is the only thing standing between a
        // VoiceOver user and a false "you're back" — assert the overlay
        // behaviour is unchanged so this can't silently pass by regressing it.
        #expect(fixture.livePane?.remoteReconnect == nil)
        #expect(!enactor.errorLatched)

        // ssh then reports the failure it was always going to report. The pane
        // re-latches and the disconnected overlay owns the failure voice; what
        // must never appear anywhere in this sequence is a success claim.
        enactor.beginExitSupervision(exitCode: 255)

        #expect(enactor.errorLatched)
        #expect(announcements == [.remoteReconnectStarted(host: "example.invalid")])
    }

    enum PostSpawnStateCase: String, CaseIterable {
        case onlyBridgeAttachStampsEstablishedMetadata
        case remoteOwnedSpawnKeepsAgentChrome
    }

    @Test(arguments: PostSpawnStateCase.allCases)
    func postSpawnState(_ scenario: PostSpawnStateCase) throws {
        switch scenario {
        case .onlyBridgeAttachStampsEstablishedMetadata:
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
        case .remoteOwnedSpawnKeepsAgentChrome:
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
    }

    enum RemoteOwnedSpawnCase: String, CaseIterable {
        case remoteOwnedSurfaceSpawnsSSHCommand
        case remoteOwnedKeepsSessionAcrossReentryWithBridgeDisabled
    }

    @Test(arguments: RemoteOwnedSpawnCase.allCases)
    func remoteOwnedSpawn(_ scenario: RemoteOwnedSpawnCase) throws {
        switch scenario {
        case .remoteOwnedSurfaceSpawnsSSHCommand:
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
        case .remoteOwnedKeepsSessionAcrossReentryWithBridgeDisabled:
            let fixture = try makeRemoteOwnedFixture(bridgeEnabled: false)
            let enactor = fixture.view.commandBridgeEnactor
            let spawned = SpawnedCommandBox()
            fixture.runtime.createSurfaceOverride = { _, _, _, command in
                spawned.record(command)
                return nil
            }
            enactor.remoteOwnedAttachCommandProvider = { _, sessionName, _ in
                "remote-owned-\(sessionName.rawValue)"
            }

            fixture.view.createSurfaceIfNeeded()
            #expect(enactor.sessionID == fixture.sessionID)
            let record = try #require(enactor.recoveryRecord)

            // `surface` stays nil here, exactly as it does while a real spawn is
            // pending, so later layout passes re-enter. The bridge-disabled
            // pre-clear says nothing about a pane whose session lives on the far
            // host and must leave it alone. The identity check is the assertion that
            // bites: a clear discards the record and mints a replacement.
            fixture.view.createSurfaceIfNeeded()

            #expect(enactor.sessionID == fixture.sessionID)
            #expect(enactor.recoveryRecord === record)
            #expect(spawned.commands == ["remote-owned-work", "remote-owned-work"])
        }
    }

    enum LegacyErrorAnnouncementsCase: String, CaseIterable {
        case legacyNonzeroExitAnnouncesError
        case legacyMissingSessionAnnouncesError
    }

    @Test(arguments: LegacyErrorAnnouncementsCase.allCases)
    func legacyErrorAnnouncements(_ scenario: LegacyErrorAnnouncementsCase) async throws {
        let missingSession = scenario == .legacyMissingSessionAnnouncesError
        let fixture = try makeFixture()
        let enactor = fixture.view.commandBridgeEnactor
        var announcements: [Announcement] = []
        enactor.announceErrorEntered = { announcements.append(.errorEntered) }
        if missingSession { enactor.sessionExistsProvider = { _ in false } }
        enactor.sessionID = fixture.sessionID
        enactor.beginExitSupervision(exitCode: missingSession ? 0 : 1)
        if missingSession { await waitForLegacyProbeToSettle(enactor) }
        #expect(enactor.errorLatched)
        #expect(announcements == [.errorEntered])
    }

    enum BudgetRefillCancellationCase: String, CaseIterable {
        case sessionRepointCancelsBudgetRefill
        case surfaceTeardownCancelsBudgetRefill
        case newIncarnationReplacesBudgetRefill
        case sessionEndCancelsBudgetRefill
    }

    @Test(arguments: BudgetRefillCancellationCase.allCases)
    func budgetRefillCancellation(_ scenario: BudgetRefillCancellationCase) throws {
        switch scenario {
        case .sessionRepointCancelsBudgetRefill:
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
        case .surfaceTeardownCancelsBudgetRefill:
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
        case .newIncarnationReplacesBudgetRefill:
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
        case .sessionEndCancelsBudgetRefill:
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
            await awaitSignal { continuation in
                let resume = { continuation.resume() }
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
        await awaitSignal { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
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
        sessionID: TerminalSessionID,
        created: Bool = true
    ) throws -> AmxStatusEvent {
        try #require(
            Self.attachedStatusEvent(
                pid: pid,
                createdAt: createdAt,
                session: sessionID.rawValue,
                created: created
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
        session: String = "00000000-0000-4000-8000-000000000001",
        created: Bool = true
    ) -> AmxStatusEvent? {
        let token = "tok"
        let line = """
            {"event":"attached","token":"\(token)","created":\(created),"daemon_pid":\(pid),"daemon_created_at":\(createdAt),"session":"\(session)","ts":1700000001}
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
                sessionName: RemoteSessionName(rawValue: "work")
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
        view.commandBridgeEnactor.remoteOwnedCarrierCommandProvider = { _, _, _, _ in nil }
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

    /// Stands in for the `/bin/sh` wrapper having written (or not written) a
    /// status, without touching the filesystem.
    private func stubRemoteOwnedExitStatus(_ status: Int16?, on enactor: CommandBridgeEnactor) {
        enactor.remoteOwnedExitStatusFile = URL(fileURLWithPath: "/tmp/unused.exit")
        enactor.remoteOwnedExitStatusConsumer = { _ in status }
    }

    private func remoteOwnedTarget() throws -> RemoteTarget {
        try #require(RemoteTarget(user: "ed", host: "example.invalid"))
    }

    /// Status files are named `<session>-<token prefix>.status.jsonl`, so a
    /// session-prefixed listing of the socket directory is how "no channel was
    /// ever minted" is proven — `statusChannel == nil` alone would also hold for
    /// a channel that was minted and then deleted.
    ///
    /// The suffix is part of the filter, not decoration: a remote-owned attach
    /// legitimately mints a `<session>.exit` file in the same directory, and a
    /// prefix-only match would count that as a status channel.
    private func statusFileNames(for sessionID: TerminalSessionID) -> [String] {
        let directory = AmxBackend.sessionSocketDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter {
            $0.hasPrefix(sessionID.rawValue) && $0.hasSuffix(".status.jsonl")
        }
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
        var terminalText: String?
        private(set) var exitEvents: [String] = []
        private(set) var disposeCount = 0
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

        func visibleTerminalText() -> String? {
            exitEvents.append("read")
            return terminalText
        }
        func disposeNativeSurface(resetHostedLayer: Bool) {
            exitEvents.append("dispose")
            disposeCount += 1
            hasNativeSurface = false
            terminalText = nil
        }
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
