import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Bridge preflight lifecycle")
struct BridgePreflightLifecycleTests {
    @Test("disabling bridge policy invalidates a suspended preflight")
    func policyDisableInvalidatesSuspendedPreflight() async throws {
        let fixture = try makeFixture()
        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        let originalGeneration = fixture.view.lifecycleState.bridgePreflightGeneration
        #expect(fixture.view.commandBridgeEnactor.sessionID == fixture.pane.terminalSessionID)
        #expect(fixture.view.commandBridgeEnactor.statusChannel != nil)

        fixture.policy.bridgeEnabled = false
        fixture.view.update(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        #expect(fixture.view.lifecycleState.bridgePreflightGeneration > originalGeneration)
        await fixture.preflight.resumeRequest(0, returning: .degraded(.forwardFailed))
        await fixture.preflight.waitForCompletionCount(1)

        #expect(fixture.surfaceCommands.values.isEmpty)
        #expect(!fixture.view.commandBridgeEnactor.bridgePreflightInFlight)
        #expect(fixture.view.commandBridgeEnactor.sessionID == nil)
        #expect(fixture.view.commandBridgeEnactor.statusChannel == nil)
        #expect(fixture.view.lifecycleState.bridgePreflightTask == nil)
    }

    @Test("changing the remote target retires the old bridge generation off-window")
    func remoteTargetChangeRetiresOldGenerationOffWindow() async throws {
        let fixture = try makeFixture()
        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)

        let teardown = BridgePreflightTeardownSignal()
        let registry = BridgeGenerationRegistry(
            ledger: fixture.runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        fixture.runtime.bridgeGenerationRegistry = registry
        let channel = try #require(
            BridgeChannel.mint(
                session: fixture.pane.terminalSessionID,
                previousGeneration: 0,
                localSocketPath: "/tmp/old-target.sock",
                remoteHome: "/Users/alice"
            ))
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/old-target.ctl",
                remote: try #require(RemoteTarget(user: "alice", host: "old-box")),
                channel: channel,
                shutdown: { await teardown.signal() }
            ),
            for: fixture.pane.terminalSessionID
        )

        var retargetedPane = fixture.pane
        retargetedPane.executionPlan = .ssh(
            SSHExecution(
                target: try #require(RemoteTarget(user: "alice", host: "new-box"))
            ))
        var retargetedSession = fixture.session
        retargetedSession.layout = .pane(retargetedPane)
        fixture.view.update(
            sessionStore: fixture.store,
            session: retargetedSession,
            pane: retargetedPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        await teardown.wait()
        #expect(await teardown.wasSignalled)

        await fixture.preflight.resumeRequest(0, returning: .cancelled)
        await fixture.preflight.waitForCompletionCount(1)
    }

    @Test("disabling agent chrome replaces a suspended preflight exactly once")
    func chromeDisableReplacesSuspendedPreflightOnce() async throws {
        let fixture = try makeFixture()
        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        let originalGeneration = fixture.view.lifecycleState.bridgePreflightGeneration
        let window = hostInSettledWindow(fixture.view)
        defer { window.close() }

        fixture.policy.chromeEnabled = false
        fixture.view.update(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        await fixture.surfaceCommands.waitForCount(1)
        #expect(fixture.view.lifecycleState.bridgePreflightGeneration > originalGeneration)

        await fixture.preflight.resumeRequest(0, returning: .degraded(.forwardFailed))
        await fixture.preflight.waitForCompletionCount(1)
        await drainMainQueue()

        #expect(fixture.surfaceCommands.values == ["base-\(fixture.pane.terminalSessionID.rawValue)"])
    }

    @Test("repointing invalidates a suspended preflight generation")
    func repointInvalidatesSuspendedPreflightGeneration() async throws {
        let fixture = try makeFixture()
        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        let originalGeneration = fixture.view.lifecycleState.bridgePreflightGeneration
        let window = hostInSettledWindow(fixture.view)
        defer { window.close() }

        var repointedPane = fixture.pane
        repointedPane.terminalSessionID = .generate()
        var repointedSession = fixture.session
        repointedSession.layout = .pane(repointedPane)
        repointedSession.activePaneID = repointedPane.id
        fixture.view.update(
            sessionStore: fixture.store,
            session: repointedSession,
            pane: repointedPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        #expect(fixture.view.lifecycleState.bridgePreflightGeneration > originalGeneration)
        await fixture.preflight.waitForRequestCount(2)
        await fixture.preflight.resumeRequest(0, returning: .degraded(.forwardFailed))
        await fixture.preflight.resumeRequest(1, returning: .degraded(.forwardFailed))
        await fixture.preflight.waitForCompletionCount(2)

        #expect(fixture.surfaceCommands.values == ["base-\(repointedPane.terminalSessionID.rawValue)"])
    }

    @Test("discarding a view invalidates its suspended preflight")
    func discardInvalidatesSuspendedPreflight() async throws {
        let fixture = try makeFixture()
        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)

        fixture.runtime.discardSurface(for: fixture.pane.id)
        await fixture.preflight.resumeRequest(0, returning: .degraded(.forwardFailed))
        await fixture.preflight.waitForCompletionCount(1)
        await drainMainQueue()

        #expect(fixture.runtime.cachedSurfaceView(for: fixture.pane.id) == nil)
        #expect(fixture.surfaceCommands.values.isEmpty)
    }

    @Test("an unchanged ready preflight spawns its prepared command once")
    func unchangedReadySpawnsOnce() async throws {
        let fixture = try makeFixture()
        let channel = BridgeChannel(
            token: "ready-token",
            gen: 1,
            localSocketPath: "/tmp/ready-local.sock",
            remoteSocketPath: "/tmp/ready-remote.sock",
            stateFilePath: "/Users/alice/.awesomux/bridge/ready.json",
            session: fixture.pane.terminalSessionID
        )

        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        await fixture.preflight.resumeRequest(
            0,
            returning: .ready(channel: channel, command: "ready-command")
        )
        await fixture.surfaceCommands.waitForCount(1)

        #expect(fixture.surfaceCommands.values == ["ready-command"])
    }

    @Test("a failed surface creation discards the committed staged generation")
    func failedSurfaceCreationDiscardsCommittedStagedGeneration() async throws {
        let fixture = try makeFixture()
        let token = "surface-create-failure-token"
        let staged = try fixture.runtime.buildStagedBridgeTrio(
            token: token,
            session: fixture.pane.terminalSessionID,
            paneID: fixture.pane.id,
            workspaceSessionID: fixture.session.id,
            sessionStore: fixture.store
        )
        let stagedRuntime = try #require(
            fixture.runtime.bridgeCoordinatorStore.takeStaged(token: token)
        )
        let teardown = BridgePreflightTeardownSignal()
        fixture.runtime.bridgeCoordinatorStore.stage(
            token: token,
            BridgeCoordinatorStore.StagedBridgeRuntime(
                coordinator: stagedRuntime.coordinator,
                teardown: {
                    await stagedRuntime.teardown()
                    await teardown.signal()
                }
            )
        )
        let channel = BridgeChannel(
            token: token,
            gen: 1,
            localSocketPath: staged.socketPath,
            remoteSocketPath: "/tmp/failed-create-remote.sock",
            stateFilePath: "/Users/alice/.awesomux/bridge/failed-create.json",
            session: fixture.pane.terminalSessionID
        )
        #expect(FileManager.default.fileExists(atPath: staged.socketPath))

        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        await fixture.preflight.resumeRequest(
            0,
            returning: .ready(channel: channel, command: "ready-command")
        )
        await fixture.surfaceCommands.waitForCount(1)
        await teardown.wait()

        #expect(fixture.view.surface == nil)
        #expect(
            fixture.runtime.bridgeGenerationRegistry?.currentToken(
                for: fixture.pane.terminalSessionID
            ) == nil
        )
        #expect(!FileManager.default.fileExists(atPath: staged.socketPath))
        #expect(
            fixture.runtime.bridgeCoordinatorStore.coordinator(
                for: fixture.pane.terminalSessionID
            ) == nil
        )
    }

    @Test("ready acknowledgment cannot replay an old command after repoint")
    func readyAcknowledgmentCannotReplayOldCommandAfterRepoint() async throws {
        let fixture = try makeFixture()
        let acknowledgment = SuspendedStage<Void>()
        fixture.view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in "/Users/alice" },
            helperSupportsBridge: { _, _, _ in true },
            attach: { _, request in await fixture.preflight.attach(request) },
            acknowledgeReady: { _, _ in await acknowledgment.wait() }
        )
        let channel = BridgeChannel(
            token: "acknowledgment-token",
            gen: 1,
            localSocketPath: "/tmp/acknowledgment-local.sock",
            remoteSocketPath: "/tmp/acknowledgment-remote.sock",
            stateFilePath: "/Users/alice/.awesomux/bridge/acknowledgment.json",
            session: fixture.pane.terminalSessionID
        )

        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        await fixture.preflight.resumeRequest(
            0,
            returning: .ready(channel: channel, command: "old-target-command")
        )
        await acknowledgment.waitUntilSuspended()
        #expect(fixture.surfaceCommands.values == ["old-target-command"])

        var repointedPane = fixture.pane
        repointedPane.terminalSessionID = .generate()
        repointedPane.executionPlan = .ssh(
            SSHExecution(
                target: try #require(RemoteTarget(user: "alice", host: "new-box"))
            ))
        var repointedSession = fixture.session
        repointedSession.layout = .pane(repointedPane)
        fixture.view.update(
            sessionStore: fixture.store,
            session: repointedSession,
            pane: repointedPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        await acknowledgment.resume(returning: ())
        await acknowledgment.waitUntilCompleted()
        await drainMainQueue()
        #expect(fixture.surfaceCommands.values == ["old-target-command"])
    }

    @Test("an unchanged degraded preflight spawns its base command once")
    func unchangedDegradedSpawnsOnce() async throws {
        let fixture = try makeFixture()

        fixture.view.createSurfaceIfNeeded()
        await fixture.preflight.waitForRequestCount(1)
        await fixture.preflight.resumeRequest(0, returning: .degraded(.admissionRejected))
        await fixture.surfaceCommands.waitForCount(1)

        #expect(fixture.surfaceCommands.values == ["base-\(fixture.pane.terminalSessionID.rawValue)"])
    }

    @Test("remote home failure remains a single fail-open spawn")
    func remoteHomeFailureFailsOpenOnce() async throws {
        let fixture = try makeFixture()
        fixture.view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in nil },
            helperSupportsBridge: { _, _, _ in
                Issue.record("helper probe must not run without a remote home")
                return false
            },
            attach: { _, _ in
                Issue.record("attach must not run without a remote home")
                return .cancelled
            }
        )

        fixture.view.createSurfaceIfNeeded()
        await fixture.surfaceCommands.waitForCount(1)

        #expect(fixture.surfaceCommands.values == ["base-\(fixture.pane.terminalSessionID.rawValue)"])
    }

    @Test("invalidation during remote home resolution stops before helper probing")
    func invalidationDuringHomeResolutionStopsBeforeHelper() async throws {
        let fixture = try makeFixture()
        let home = SuspendedStage<String?>()
        fixture.view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in await home.wait() },
            helperSupportsBridge: { _, _, _ in
                Issue.record("helper probe must not run after home-stage invalidation")
                return true
            },
            attach: { _, _ in
                Issue.record("attach must not run after home-stage invalidation")
                return .cancelled
            }
        )

        fixture.view.createSurfaceIfNeeded()
        await home.waitUntilSuspended()
        fixture.policy.chromeEnabled = false
        fixture.view.update(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        await home.resume(returning: "/Users/alice")
        await home.waitUntilCompleted()
        await drainMainQueue()

        #expect(fixture.surfaceCommands.values.isEmpty)
        #expect(fixture.view.lifecycleState.bridgePreflightTask == nil)
    }

    @Test("invalidation during helper probing stops before attach")
    func invalidationDuringHelperProbeStopsBeforeAttach() async throws {
        let fixture = try makeFixture()
        let helper = SuspendedStage<Bool>()
        fixture.view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in "/Users/alice" },
            helperSupportsBridge: { _, _, _ in await helper.wait() },
            attach: { _, _ in
                Issue.record("attach must not run after helper-stage invalidation")
                return .cancelled
            }
        )

        fixture.view.createSurfaceIfNeeded()
        await helper.waitUntilSuspended()
        fixture.policy.chromeEnabled = false
        fixture.view.update(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        await helper.resume(returning: true)
        await helper.waitUntilCompleted()
        await drainMainQueue()

        #expect(fixture.surfaceCommands.values.isEmpty)
        #expect(fixture.view.lifecycleState.bridgePreflightTask == nil)
    }

    @Test("incompatible helper remains a single fail-open spawn")
    func incompatibleHelperFailsOpenOnce() async throws {
        let fixture = try makeFixture()
        fixture.view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in "/Users/alice" },
            helperSupportsBridge: { _, _, _ in false },
            attach: { _, _ in
                Issue.record("attach must not run for an incompatible helper")
                return .cancelled
            }
        )

        fixture.view.createSurfaceIfNeeded()
        await fixture.surfaceCommands.waitForCount(1)

        #expect(fixture.surfaceCommands.values == ["base-\(fixture.pane.terminalSessionID.rawValue)"])
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func hostInSettledWindow(_ view: GhosttySurfaceNSView) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.frame = frame
        let window = BridgePreflightTestWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()

        let settledAt = ContinuousClock.now - .seconds(3)
        view.lifecycleState.windowFrameSettleState.lastFrame = window.frame
        view.lifecycleState.windowFrameSettleState.firstObservedAt = settledAt
        view.lifecycleState.windowFrameSettleState.lastChangeAt = settledAt
        view.lifecycleState.coldStartCreationState.anchorAt = settledAt
        view.lifecycleState.coldStartCreationState.lastObservedWidth = frame.width
        view.lifecycleState.coldStartCreationState.widthStableSince = settledAt
        return window
    }

    private func makeFixture() throws -> Fixture {
        let terminalSessionID = try #require(
            TerminalSessionID(
                rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            ))
        let remote = try #require(RemoteTarget(user: "alice", host: "box"))
        let pane = TerminalPane(
            terminalSessionID: terminalSessionID,
            title: "bridge",
            workingDirectory: "/tmp/bridge",
            executionPlan: .ssh(SSHExecution(target: remote))
        )
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
        let policy = PolicyBox()
        let preflight = SuspendedPreflight()
        let surfaceCommands = SurfaceCommandRecorder()
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        runtime.bridgeGenerationRegistry = BridgeGenerationRegistry(
            ledger: runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        runtime.configureCommandBridgeEnabledProvider { policy.bridgeEnabled }
        runtime.configureAgentIntegrationsProvider {
            policy.chromeEnabled
                ? AgentIntegrationsConfig(claudeCode: AgentIntegrationSetup(enabled: true))
                : .defaultValue
        }
        runtime.createSurfaceOverride = { _, _, _, command in
            surfaceCommands.record(command)
            return nil
        }
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        view.commandBridgeEnactor.attachCommandProvider = { session, _, _ in
            "base-\(session.rawValue)"
        }
        view.lifecycleState.bridgePreflightDependencies = BridgePreflightDependencies(
            resolveRemoteHome: { _, _ in "/Users/alice" },
            helperSupportsBridge: { _, _, _ in true },
            attach: { _, request in await preflight.attach(request) }
        )

        return Fixture(
            runtime: runtime,
            store: store,
            session: session,
            pane: pane,
            view: view,
            policy: policy,
            preflight: preflight,
            surfaceCommands: surfaceCommands
        )
    }

    private struct Fixture {
        let runtime: GhosttyRuntime
        let store: SessionStore
        let session: TerminalSession
        let pane: TerminalPane
        let view: GhosttySurfaceNSView
        let policy: PolicyBox
        let preflight: SuspendedPreflight
        let surfaceCommands: SurfaceCommandRecorder
    }
}

@MainActor
private final class BridgePreflightTestWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

@MainActor
private final class PolicyBox {
    var bridgeEnabled = true
    var chromeEnabled = true
}

private final class SurfaceCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String?] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var values: [String?] {
        lock.withLock { commands }
    }

    func record(_ command: String?) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            commands.append(command)
            let ready = waiters.filter { commands.count >= $0.count }.map(\.continuation)
            waiters.removeAll { commands.count >= $0.count }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    func waitForCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if commands.count >= count {
                    return true
                }
                waiters.append((count, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor SuspendedPreflight {
    private struct RequestState {
        let continuation: CheckedContinuation<BridgeAttachPreflight.Outcome, Never>
    }

    private var requests: [RequestState] = []
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completionCount = 0
    private var completionCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func attach(_ request: BridgeAttachPreflight.Request) async -> BridgeAttachPreflight.Outcome {
        let outcome = await withCheckedContinuation {
            requests.append(RequestState(continuation: $0))
            resumeRequestCountWaiters()
        }
        completionCount += 1
        resumeCompletionCountWaiters()
        return outcome
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation {
            requestCountWaiters.append((count, $0))
        }
    }

    func resumeRequest(_ index: Int, returning outcome: BridgeAttachPreflight.Outcome) {
        requests[index].continuation.resume(returning: outcome)
    }

    func waitForCompletionCount(_ count: Int) async {
        guard completionCount < count else { return }
        await withCheckedContinuation {
            completionCountWaiters.append((count, $0))
        }
    }

    private func resumeRequestCountWaiters() {
        let ready = requestCountWaiters.filter { requests.count >= $0.count }
        requestCountWaiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeCompletionCountWaiters() {
        let ready = completionCountWaiters.filter { completionCount >= $0.count }
        completionCountWaiters.removeAll { completionCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor SuspendedStage<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
        }
        completed = true
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
        return value
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func waitUntilCompleted() async {
        guard !completed else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }
}

private actor BridgePreflightTeardownSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var wasSignalled: Bool { signalled }

    func signal() {
        signalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
