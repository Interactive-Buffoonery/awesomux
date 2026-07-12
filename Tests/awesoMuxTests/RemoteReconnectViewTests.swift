import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// View/enactor coverage for the manual remote-reconnect path (INT-697, §3/§6).
/// Mirrors `CommandBridgeRuntimeDeathHealViewTests`' fixture shape but tags the
/// owning group with a `RemoteTarget`, so a bridge death latches the reconnect
/// overlay state instead of just `.error`.
@MainActor
@Suite("Remote reconnect view/enactor")
struct RemoteReconnectViewTests {
    private let establishedMetadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

    @Test("manual reconnect clears the latch, refills budget, and flips to reconnecting")
    func manualReconnectClearsLatchRefillsBudgetAndFlipsReconnecting() throws {
        let fixture = try makeRemoteAgentFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = try latchRemotePane(
            runtime: runtime,
            store: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            spendBudget: 2
        )

        // Latched: error overlay state + a partially-drained crash budget.
        #expect(view.commandBridgeErrorLatched)
        #expect(view.commandBridgeEnactor.respawnLedger.respawnAttempts == 2)
        let latchedPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(latchedPane.remoteReconnect == .disconnected(.init(target: fixture.target)))

        // Drive through the full runtime → view → enactor forwarder chain.
        #expect(runtime.reconnectRemotePane(in: fixture.pane.id))

        #expect(!view.commandBridgeErrorLatched)
        #expect(view.commandBridgeEnactor.respawnLedger.respawnAttempts == 0)
        let reconnectingPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(reconnectingPane.remoteReconnect == .reconnecting(.init(target: fixture.target)))
    }

    @Test("a racing second reconnect no-ops")
    func secondReconnectIsIdempotent() throws {
        let fixture = try makeRemoteAgentFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = try latchRemotePane(
            runtime: runtime,
            store: fixture.store,
            session: fixture.session,
            pane: fixture.pane
        )

        #expect(runtime.reconnectRemotePane(in: fixture.pane.id))
        // Simulate budget spent by the in-flight respawn between the two clicks;
        // a no-op second click must NOT refill it back to zero.
        view.commandBridgeEnactor.respawnLedger.recordRespawnAttempt()

        #expect(runtime.reconnectRemotePane(in: fixture.pane.id))

        #expect(!view.commandBridgeErrorLatched)
        #expect(view.commandBridgeEnactor.respawnLedger.respawnAttempts == 1)
        let pane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(pane.remoteReconnect == .reconnecting(.init(target: fixture.target)))
    }

    @Test("same-incarnation attach after reconnect clears state and preserves agent chrome")
    func sameIncarnationAttachConfirmsAndPreservesChrome() throws {
        let fixture = try makeRemoteAgentFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = try latchRemotePane(
            runtime: runtime,
            store: fixture.store,
            session: fixture.session,
            pane: fixture.pane
        )
        // The latch drives the pane's execution state to `.error`; the agent
        // identity survives it.
        let latchedPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(latchedPane.agentExecutionState == .error)
        #expect(latchedPane.agentKind == .codex)

        #expect(runtime.reconnectRemotePane(in: fixture.pane.id))

        // `created: false` == reconnect to the still-live daemon, so agent chrome
        // is preserved (no `resetPaneAgentChromeToShell`); the confirmation hook
        // is the only thing that un-sticks the bridge-death `.error`.
        view.handleCommandBridgeStatusEvents([
            try #require(Self.attachedEvent(
                token: "tok",
                terminalSessionID: fixture.sessionID,
                created: false,
                daemonPid: 100,
                daemonCreatedAt: 1_700_000_000
            ))
        ])

        let confirmedPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(confirmedPane.remoteReconnect == nil)
        #expect(confirmedPane.agentExecutionState != .error)
        #expect(confirmedPane.agentKind == .codex)
    }

    @Test("a failed reconnect (ssh 255) re-latches back to disconnected")
    func failedReconnectRelatchesDisconnected() throws {
        let fixture = try makeRemoteAgentFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = try latchRemotePane(
            runtime: runtime,
            store: fixture.store,
            session: fixture.session,
            pane: fixture.pane
        )

        #expect(runtime.reconnectRemotePane(in: fixture.pane.id))
        let reconnectingPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(reconnectingPane.remoteReconnect == .reconnecting(.init(target: fixture.target)))

        // Host still down: the fresh channel reports an ssh transport failure.
        try driveRemoteShellExit(on: view, terminalSessionID: fixture.sessionID, code: 255)

        #expect(view.commandBridgeErrorLatched)
        let relatchedPane = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(relatchedPane.remoteReconnect == .disconnected(.init(target: fixture.target)))
    }

    @Test("reconnecting one split pane leaves its sibling untouched")
    func reconnectingOnePaneLeavesSiblingUntouched() throws {
        let fixture = try makeRemoteSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)

        // Sibling B: a healthy remote pane with its own recovery record + budget.
        let viewB = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.paneB,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        viewB.commandBridgeSessionID = fixture.paneB.terminalSessionID
        viewB.commandBridgeEnactor.respawnLedger.recordRespawnAttempt()

        _ = try latchRemotePane(
            runtime: runtime,
            store: fixture.store,
            session: fixture.session,
            pane: fixture.paneA
        )

        #expect(runtime.reconnectRemotePane(in: fixture.paneA.id))

        // B's surface view, latch, ledger, and store chrome are all untouched.
        // A cached lookup returns the same instance only if it was never evicted.
        let stillViewB = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.paneB,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        #expect(stillViewB === viewB)
        #expect(!viewB.commandBridgeErrorLatched)
        #expect(viewB.commandBridgeEnactor.respawnLedger.respawnAttempts == 1)
        let paneB = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.paneB.id)
        )
        #expect(paneB.remoteReconnect == nil)
        #expect(paneB.agentExecutionState == fixture.paneB.agentExecutionState)
    }

    // MARK: - Drivers

    /// Build + register a remote pane's surface view, optionally pre-spend some
    /// crash budget, then drive an ssh transport failure (code 255) which — for a
    /// remote pane — latches `.error` immediately (no respawn), setting the
    /// `.disconnected` overlay state via `recordPaneProcessError`.
    private func latchRemotePane(
        runtime: GhosttyRuntime,
        store: SessionStore,
        session: TerminalSession,
        pane: TerminalPane,
        spendBudget: Int = 0
    ) throws -> GhosttySurfaceNSView {
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        // Set the session id first so the recovery record (and its ledger) exist
        // before we spend budget against them.
        view.commandBridgeSessionID = pane.terminalSessionID
        for _ in 0..<spendBudget {
            view.commandBridgeEnactor.respawnLedger.recordRespawnAttempt()
        }
        try driveRemoteShellExit(on: view, terminalSessionID: pane.terminalSessionID, code: 255)
        #expect(view.commandBridgeErrorLatched)
        return view
    }

    private func driveRemoteShellExit(
        on view: GhosttySurfaceNSView,
        terminalSessionID: TerminalSessionID,
        code: Int
    ) throws {
        let channel = try #require(AmxBackend.makeStatusChannel(for: terminalSessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        view.commandBridgeSessionID = terminalSessionID
        view.beginCommandBridgeStatusWatch(channel: channel)
        #expect(view.commandBridgeStatusWatcher?.isArmed == true)

        let event = try #require(Self.sessionEndEvent(
            token: channel.token,
            terminalSessionID: terminalSessionID,
            reason: .shellExit,
            code: code
        ))
        view.handleCommandBridgeStatusEvents([event])
    }

    private static func sessionEndEvent(
        token: String,
        terminalSessionID: TerminalSessionID,
        reason: SessionEndReason,
        code: Int
    ) -> AmxStatusEvent? {
        let line = """
        {"event":"session-end","token":"\(token)","reason":"\(statusReason(reason))","code":\(code),"session":"\(terminalSessionID.rawValue)","ts":1700000001}
        """
        return AmxStatusEvent.parseLines(line + "\n", expectedToken: token).first
    }

    private static func attachedEvent(
        token: String,
        terminalSessionID: TerminalSessionID,
        created: Bool,
        daemonPid: Int,
        daemonCreatedAt: Int
    ) -> AmxStatusEvent? {
        let line = """
        {"event":"attached","token":"\(token)","created":\(created),"daemon_pid":\(daemonPid),"daemon_created_at":\(daemonCreatedAt),"session":"\(terminalSessionID.rawValue)","ts":1700000001}
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

    private func makeRemoteAgentFixture() throws -> RemoteAgentFixture {
        let sessionID = try #require(TerminalSessionID(
            rawValue: "22222222-2222-4222-8222-222222222222"
        ))
        let target = RemoteTarget(user: "deploy", host: "prod.example")
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "codex",
            workingDirectory: "/home/deploy",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt
        )
        let session = TerminalSession(
            title: "remote agent",
            workingDirectory: "/home/deploy",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "prod", remote: target, sessions: [session])],
            selectedSessionID: session.id
        )
        return RemoteAgentFixture(
            sessionID: sessionID,
            target: target,
            session: session,
            pane: pane,
            store: store
        )
    }

    private func makeRemoteSplitFixture() throws -> RemoteSplitFixture {
        let sessionIDA = try #require(TerminalSessionID(
            rawValue: "33333333-3333-4333-8333-333333333333"
        ))
        let sessionIDB = try #require(TerminalSessionID(
            rawValue: "44444444-4444-4444-8444-444444444444"
        ))
        let target = RemoteTarget(user: "deploy", host: "prod.example")
        let paneA = TerminalPane(
            terminalSessionID: sessionIDA,
            terminalBackendMetadata: establishedMetadata,
            title: "pane A",
            workingDirectory: "/home/deploy/a"
        )
        let paneB = TerminalPane(
            terminalSessionID: sessionIDB,
            terminalBackendMetadata: establishedMetadata,
            title: "pane B",
            workingDirectory: "/home/deploy/b",
            agentKind: .codex,
            agentExecutionState: .thinking
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(paneA),
            second: .pane(paneB),
            firstFraction: 0.5
        ))
        let session = TerminalSession(
            title: "remote split",
            workingDirectory: "/home/deploy",
            layout: layout,
            activePaneID: paneA.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "prod", remote: target, sessions: [session])],
            selectedSessionID: session.id
        )
        return RemoteSplitFixture(
            target: target,
            session: session,
            paneA: paneA,
            paneB: paneB,
            store: store
        )
    }

    private struct RemoteAgentFixture {
        let sessionID: TerminalSessionID
        let target: RemoteTarget
        let session: TerminalSession
        let pane: TerminalPane
        let store: SessionStore
    }

    private struct RemoteSplitFixture {
        let target: RemoteTarget
        let session: TerminalSession
        let paneA: TerminalPane
        let paneB: TerminalPane
        let store: SessionStore
    }
}
