import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Command bridge runtime-death view heal")
struct CommandBridgeRuntimeDeathHealViewTests {
    private let establishedMetadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

    @Test("late process-exit callback on evicted healed view does not collapse split")
    func lateProcessExitAfterHealDoesNotClosePane() throws {
        let fixture = try makeSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let staleView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )

        try driveDaemonDeathHeal(on: staleView, terminalSessionID: fixture.deadSessionID)

        staleView.commandBridgeSessionID = nil
        staleView.commandExitCache.record(
            exitCode: 0,
            at: Date().timeIntervalSinceReferenceDate
        )
        staleView.closeAfterProcessExit(processAlive: false)

        let healedSession = try #require(fixture.store.session(id: fixture.session.id))
        #expect(healedSession.layout == fixture.layout)
        #expect(healedSession.layout.pane(id: fixture.deadPane.id) == fixture.deadPane)
        #expect(healedSession.layout.pane(id: fixture.siblingPane.id) == fixture.siblingPane)
        #expect(healedSession.activePaneID == fixture.deadPane.id)
    }

    @Test("cached attach-client exit code does not bypass established bridge heal")
    func cachedExitCodeDoesNotCloseEstablishedBridgePane() throws {
        let fixture = try makeSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let staleView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )

        staleView.commandBridgeSessionID = nil
        staleView.commandExitCache.record(
            exitCode: 0,
            at: Date().timeIntervalSinceReferenceDate
        )
        staleView.closeAfterProcessExit(processAlive: false)

        let healedSession = try #require(fixture.store.session(id: fixture.session.id))
        let freshView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: healedSession,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )

        #expect(freshView !== staleView)
        #expect(staleView.ignoresProcessExitAfterCommandBridgeHeal)
        #expect(healedSession.layout == fixture.layout)
        #expect(healedSession.activePaneID == fixture.deadPane.id)
    }

    @Test("crash-loop cap survives healed surface recreation")
    func crashLoopCapSurvivesHealedSurfaceRecreation() throws {
        let fixture = try makeSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        var activeView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )

        for _ in 0..<CommandBridgeEnactor.maxRespawnAttempts {
            let healed = try driveSessionEnd(
                on: activeView,
                terminalSessionID: fixture.deadSessionID,
                reason: .daemonDied
            )
            #expect(healed)
            #expect(activeView.ignoresProcessExitAfterCommandBridgeHeal)

            let healedSession = try #require(fixture.store.session(id: fixture.session.id))
            let nextView = runtime.surfaceView(
                sessionStore: fixture.store,
                session: healedSession,
                pane: fixture.deadPane,
                enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
            )
            #expect(nextView !== activeView)
            activeView = nextView
        }

        let healed = try driveSessionEnd(
            on: activeView,
            terminalSessionID: fixture.deadSessionID,
            reason: .daemonDied
        )
        #expect(!healed)
        #expect(activeView.commandBridgeErrorLatched)
        #expect(!activeView.ignoresProcessExitAfterCommandBridgeHeal)
    }

    @Test("first attach restores chrome only for the surviving daemon", arguments: [false, true])
    func firstAttachChrome(created: Bool) throws {
        let fixture = try makeAgentFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: fixture.store, session: fixture.session, pane: fixture.agentPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        view.commandBridgeSessionID = fixture.agentSessionID
        view.handleCommandBridgeStatusEvents([
            try #require(
                Self.attachedEvent(
                    token: "tok", terminalSessionID: fixture.agentSessionID, created: created, daemonPid: 100,
                    daemonCreatedAt: 1_700_000_000
                ))
        ])
        let pane = try #require(fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.agentPane.id))
        #expect(pane.agentKind == (created ? .shell : .codex))
        #expect(pane.agentExecutionState == (created ? (AgentKind.shell.initialSessionState.executionState ?? .idle) : .thinking))
        #expect(pane.attentionReason == (created ? nil : .permissionPrompt))
    }

    @Test("ordinary command completion keeps the bridge surface mounted", arguments: [Int16(0), -1])
    func ordinaryCommandCompletionKeepsBridgeSurfaceMounted(exitCode: Int16) throws {
        let fixture = try makeSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.deadSessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        view.commandBridgeSessionID = fixture.deadSessionID
        view.beginCommandBridgeStatusWatch(channel: channel)
        #expect(view.commandBridgeStatusWatcher?.isArmed == true)

        let now = Date().timeIntervalSinceReferenceDate
        view.commandExitCache.record(exitCode: 7, at: now)
        #expect(view.commandExitCache.hasFreshNonZeroExitCode(now: now))
        view.handleCommandFinished(exitCode: exitCode)

        #expect(view.commandExitCache.exitCode == (exitCode >= 0 ? exitCode : nil))
        #expect(!view.commandExitCache.hasFreshNonZeroExitCode(now: Date().timeIntervalSinceReferenceDate))
        #expect(!view.commandExitCache.shouldSignalSiblingPaneExit(now: Date().timeIntervalSinceReferenceDate, paneCount: 2))
        #expect(!CommandExitCache(exitCode: -1, recordedAt: now).hasFreshNonZeroExitCode(now: now))

        #expect(runtime.cachedSurfaceView(for: fixture.deadPane.id) === view)
        #expect(!view.ignoresProcessExitAfterCommandBridgeHeal)
        #expect(fixture.store.session(id: fixture.session.id)?.layout == fixture.layout)
    }

    @Test("process exit after session-end drain closes instead of respawning")
    func processExitAfterSessionEndDrainClosesInsteadOfRespawning() throws {
        let fixture = try makeSplitFixture()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let channel = try #require(AmxBackend.makeStatusChannel(for: fixture.deadSessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        view.commandBridgeSessionID = fixture.deadSessionID
        view.beginCommandBridgeStatusWatch(channel: channel)
        #expect(view.commandBridgeStatusWatcher?.isArmed == true)
        try writeSessionEndLine(
            to: channel,
            terminalSessionID: fixture.deadSessionID,
            reason: .shellExit
        )

        view.handleCommandFinished(exitCode: 0)

        #expect(runtime.cachedSurfaceView(for: fixture.deadPane.id) === view)
        #expect(fixture.store.session(id: fixture.session.id)?.layout == fixture.layout)

        view.closeAfterProcessExit(processAlive: false)

        let healedSession = try #require(fixture.store.session(id: fixture.session.id))
        #expect(healedSession.layout.pane(id: fixture.deadPane.id) == nil)
        #expect(healedSession.layout.pane(id: fixture.siblingPane.id) == fixture.siblingPane)
        #expect(healedSession.layout.paneCount == 1)
        #expect(!view.ignoresProcessExitAfterCommandBridgeHeal)
    }

    @Test(
        "closing healed sessions and pre-attach views frees recovery records",
        arguments: ["sessionTeardownFreesPreservedRecoveryRecord", "closeBeforeReattachFreesPreservedRecoveryRecord"])
    func closeFreesRecoveryRecord(scenario: String) async throws {
        switch scenario {
        case "sessionTeardownFreesPreservedRecoveryRecord":
            let fixture = try makeSplitFixture()
            let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
            let staleView = runtime.surfaceView(
                sessionStore: fixture.store,
                session: fixture.session,
                pane: fixture.deadPane,
                enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
            )

            // A daemon-death heal on an unmounted view (nil scrollContainer) bails after
            // `discardSurface` has already preserved the recovery record, so the record
            // outlives the evicted surface — exactly the orphan a later true close must
            // free rather than leak for the app's lifetime.
            try driveDaemonDeathHeal(on: staleView, terminalSessionID: fixture.deadSessionID)
            #expect(runtime.commandBridgeRecoveryRecords[fixture.deadSessionID] != nil)

            let healedSession = try #require(fixture.store.session(id: fixture.session.id))
            runtime.discardSurfaces(for: healedSession)

            #expect(runtime.commandBridgeRecoveryRecords[fixture.deadSessionID] == nil)
            #expect(runtime.commandBridgeRecoveryRecords.isEmpty)
        case "closeBeforeReattachFreesPreservedRecoveryRecord":
            let fixture = try makeSplitFixture()
            let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
            let staleView = runtime.surfaceView(
                sessionStore: fixture.store,
                session: fixture.session,
                pane: fixture.deadPane,
                enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
            )

            // Heal preserves the record and evicts the stale surface.
            try driveDaemonDeathHeal(on: staleView, terminalSessionID: fixture.deadSessionID)

            // Re-foreground builds a fresh view. Until it mounts and the `.bridgeAttach`
            // path runs, `commandBridgeSessionID` is still nil, so the record resolves
            // only via the pane's terminalSessionID — the case the discard fallback
            // covers. The record is still preserved from the heal.
            let healedSession = try #require(fixture.store.session(id: fixture.session.id))
            let freshView = runtime.surfaceView(
                sessionStore: fixture.store,
                session: healedSession,
                pane: fixture.deadPane,
                enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
            )
            #expect(freshView.commandBridgeSessionID == nil)
            #expect(!freshView.ignoresProcessExitAfterCommandBridgeHeal)
            #expect(runtime.commandBridgeRecoveryRecords[fixture.deadSessionID] != nil)

            // A genuine single-pane close in that pre-attach window must still free it.
            runtime.discardSurface(for: fixture.deadPane.id)
            #expect(runtime.commandBridgeRecoveryRecords[fixture.deadSessionID] == nil)
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    private func driveDaemonDeathHeal(
        on view: GhosttySurfaceNSView,
        terminalSessionID: TerminalSessionID
    ) throws {
        let healed = try driveSessionEnd(
            on: view,
            terminalSessionID: terminalSessionID,
            reason: .daemonDied
        )
        #expect(healed)
    }

    @discardableResult
    private func driveSessionEnd(
        on view: GhosttySurfaceNSView,
        terminalSessionID: TerminalSessionID,
        reason: SessionEndReason
    ) throws -> Bool {
        let channel = try #require(AmxBackend.makeStatusChannel(for: terminalSessionID))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        view.commandBridgeSessionID = terminalSessionID
        view.beginCommandBridgeStatusWatch(channel: channel)
        #expect(view.commandBridgeStatusWatcher?.isArmed == true)

        let event = try #require(Self.sessionEndEvent(
            token: channel.token,
            terminalSessionID: terminalSessionID,
            reason: reason
        ))
        view.handleCommandBridgeStatusEvents([event])
        return view.ignoresProcessExitAfterCommandBridgeHeal
    }

    private static func sessionEndEvent(
        token: String,
        terminalSessionID: TerminalSessionID,
        reason: SessionEndReason
    ) -> AmxStatusEvent? {
        let line = """
        {"event":"session-end","token":"\(token)","reason":"\(statusReason(reason))","code":0,"session":"\(terminalSessionID.rawValue)","ts":1700000001}
        """
        return AmxStatusEvent.parseLines(line + "\n", expectedToken: token).first
    }

    private static func attachedEvent(
        token: String,
        terminalSessionID: TerminalSessionID,
        created: Bool = true,
        daemonPid: Int,
        daemonCreatedAt: Int
    ) -> AmxStatusEvent? {
        let line = """
        {"event":"attached","token":"\(token)","created":\(created),"daemon_pid":\(daemonPid),"daemon_created_at":\(daemonCreatedAt),"session":"\(terminalSessionID.rawValue)","ts":1700000001}
        """
        return AmxStatusEvent.parseLines(line + "\n", expectedToken: token).first
    }

    private func writeSessionEndLine(
        to channel: AmxStatusChannel,
        terminalSessionID: TerminalSessionID,
        reason: SessionEndReason
    ) throws {
        let line = """
        {"event":"session-end","token":"\(channel.token)","reason":"\(Self.statusReason(reason))","code":0,"session":"\(terminalSessionID.rawValue)","ts":1700000001}
        """
        try (line + "\n").write(to: channel.fileURL, atomically: false, encoding: .utf8)
    }

    private static func statusReason(_ reason: SessionEndReason) -> String {
        switch reason {
        case .daemonDied: "daemon-died"
        case .detached: "detached"
        case .shellExit: "shell-exit"
        case .unknown: "unknown"
        }
    }

    private func makeSplitFixture() throws -> SplitFixture {
        let deadSessionID = try #require(TerminalSessionID(
            rawValue: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        ))
        let siblingSessionID = try #require(TerminalSessionID(
            rawValue: "ffffffff-ffff-4fff-8fff-ffffffffffff"
        ))
        let deadPane = TerminalPane(
            terminalSessionID: deadSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "dead daemon",
            workingDirectory: "/tmp/dead",
            executionPlan: .local
        )
        let siblingPane = TerminalPane(
            terminalSessionID: siblingSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "sibling",
            workingDirectory: "/tmp/sibling",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(deadPane),
            second: .pane(siblingPane),
            firstFraction: 0.37
        ))
        let session = TerminalSession(
            title: "split",
            workingDirectory: "/tmp/dead",
            layout: layout,
            activePaneID: deadPane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return SplitFixture(
            deadSessionID: deadSessionID,
            session: session,
            layout: layout,
            deadPane: deadPane,
            siblingPane: siblingPane,
            store: store
        )
    }

    private func makeAgentFixture() throws -> AgentFixture {
        let agentSessionID = try #require(TerminalSessionID(
            rawValue: "11111111-1111-4111-8111-111111111111"
        ))
        let agentPane = TerminalPane(
            terminalSessionID: agentSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "codex",
            workingDirectory: "/tmp/agent",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "/tmp/agent",
            layout: .pane(agentPane),
            activePaneID: agentPane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return AgentFixture(
            agentSessionID: agentSessionID,
            session: session,
            agentPane: agentPane,
            store: store
        )
    }

    private struct SplitFixture {
        let deadSessionID: TerminalSessionID
        let session: TerminalSession
        let layout: TerminalPaneLayout
        let deadPane: TerminalPane
        let siblingPane: TerminalPane
        let store: SessionStore
    }

    private struct AgentFixture {
        let agentSessionID: TerminalSessionID
        let session: TerminalSession
        let agentPane: TerminalPane
        let store: SessionStore
    }
}
