import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// INT-698 D4 item E: the three enactor lifecycle events that end a bridge
// generation WITHOUT going through the `discardSurface` hook must break it via
// `BridgeGenerationRegistry.teardown` — and `notifyNativeSurfaceDisposed` (the
// front half of a respawn) must NOT, so the generation is transferred, not
// destroyed. Driven through a real enactor + view + runtime with a spy registry
// whose generation `shutdown` fulfils an async flag.
@MainActor
@Suite("Bridge attach teardown wiring")
struct BridgeAttachTeardownWiringTests {
    private static let remote = RemoteTarget(user: "alice", host: "box")!

    // MARK: - Fixture

    private struct Fixture {
        let runtime: GhosttyRuntime
        let view: GhosttySurfaceNSView
        let terminalSessionID: TerminalSessionID
        var enactor: CommandBridgeEnactor { view.commandBridgeEnactor }
    }

    private func makeFixture() throws -> Fixture {
        let terminalSessionID = try #require(TerminalSessionID(
            rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ))
        let pane = TerminalPane(
            terminalSessionID: terminalSessionID,
            title: "bridge",
            workingDirectory: "/tmp/bridge",
            executionPlan: .local
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
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return Fixture(runtime: runtime, view: view, terminalSessionID: terminalSessionID)
    }

    /// Installs a spy registry over the runtime's shared ledger and registers one
    /// generation whose `shutdown` fulfils `flag`. The exec channel is a no-op so
    /// no real ssh runs; teardown still reaches the generation's `shutdown`.
    private func installSpyGeneration(
        _ fixture: Fixture,
        flag: AsyncFlag
    ) throws {
        let registry = BridgeGenerationRegistry(
            ledger: fixture.runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        fixture.runtime.bridgeGenerationRegistry = registry
        let channel = try #require(BridgeChannel.mint(
            session: fixture.terminalSessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/l.sock",
            remoteHome: "/Users/example"
        ))
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl",
                remote: Self.remote,
                channel: channel,
                shutdown: { await flag.signal() }
            ),
            for: fixture.terminalSessionID
        )
        fixture.enactor.sessionID = fixture.terminalSessionID
    }

    // MARK: - Teardown fires

    @Test("markError breaks the live bridge generation")
    func markErrorTearsDown() async throws {
        let fixture = try makeFixture()
        let flag = AsyncFlag()
        try installSpyGeneration(fixture, flag: flag)

        fixture.enactor.markError()
        await flag.wait()
        #expect(await flag.isSet)
    }

    @Test("session re-point breaks the live bridge generation")
    func repointTearsDown() async throws {
        let fixture = try makeFixture()
        let flag = AsyncFlag()
        try installSpyGeneration(fixture, flag: flag)

        fixture.enactor.handleSessionRepoint()
        await flag.wait()
        #expect(await flag.isSet)
    }

    @Test("local-shell fallback breaks the live bridge generation")
    func localShellFallbackTearsDown() async throws {
        let fixture = try makeFixture()
        let flag = AsyncFlag()
        try installSpyGeneration(fixture, flag: flag)

        fixture.enactor.clearStateForLocalShellFallback()
        await flag.wait()
        #expect(await flag.isSet)
    }

    @Test("genuine close extracts the old generation before a same-session replacement")
    func genuineCloseExtractsOldGenerationBeforeReplacement() async throws {
        let fixture = try makeFixture()
        let registry = BridgeGenerationRegistry(
            ledger: fixture.runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        fixture.runtime.bridgeGenerationRegistry = registry
        let old = try #require(
            BridgeChannel.mint(
                session: fixture.terminalSessionID,
                previousGeneration: 0,
                localSocketPath: "/tmp/old.sock",
                remoteHome: "/Users/example"
            ))
        let shutdownGate = BridgeTeardownGate()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/old.ctl",
                remote: Self.remote,
                channel: old,
                shutdown: { await shutdownGate.wait() }
            ),
            for: fixture.terminalSessionID
        )
        fixture.enactor.sessionID = fixture.terminalSessionID

        fixture.enactor.clearStateForLocalShellFallback()
        guard registry.currentToken(for: fixture.terminalSessionID) == nil else {
            Issue.record("the closing generation must leave the live slot synchronously")
            return
        }

        let replacement = try #require(
            BridgeChannel.mint(
                session: fixture.terminalSessionID,
                previousGeneration: old.gen,
                localSocketPath: "/tmp/replacement.sock",
                remoteHome: "/Users/example"
            ))
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/replacement.ctl",
                remote: Self.remote,
                channel: replacement,
                shutdown: {}
            ),
            for: fixture.terminalSessionID
        )

        await shutdownGate.waitUntilSuspended()
        #expect(registry.currentToken(for: fixture.terminalSessionID) == replacement.token)
        await shutdownGate.release()
        await shutdownGate.waitUntilCompleted()
        #expect(registry.currentToken(for: fixture.terminalSessionID) == replacement.token)
    }

    // MARK: - Dispose preserves

    @Test("notifyNativeSurfaceDisposed PRESERVES the generation (front half of a respawn)")
    func disposePreservesGeneration() async throws {
        let fixture = try makeFixture()
        let flag = AsyncFlag()
        let registry = BridgeGenerationRegistry(
            ledger: fixture.runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        fixture.runtime.bridgeGenerationRegistry = registry
        let channel = try #require(BridgeChannel.mint(
            session: fixture.terminalSessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/l.sock",
            remoteHome: "/Users/example"
        ))
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl",
                remote: Self.remote,
                channel: channel,
                shutdown: { await flag.signal() }
            ),
            for: fixture.terminalSessionID
        )
        fixture.enactor.sessionID = fixture.terminalSessionID

        fixture.enactor.notifyNativeSurfaceDisposed()
        // Let any erroneously-scheduled teardown Task run.
        await Task.yield()
        #expect(!(await flag.isSet))

        // The generation genuinely survived: an explicit teardown NOW fires it.
        await registry.teardown(for: fixture.terminalSessionID)
        #expect(await flag.isSet)
    }

    @Test("D3 heal gate: a preserved recovery record is not torn down")
    func healGateShouldTearDown() {
        #expect(!BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: true))
        #expect(BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: false))
    }

    // MARK: - Successor protection (stale-teardown race defense)

    @Test("teardown ifToken no-ops on a successor re-mint, tears down its own token")
    func teardownIfTokenProtectsSuccessor() async throws {
        let fixture = try makeFixture()
        let registry = BridgeGenerationRegistry(
            ledger: fixture.runtime.bridgeSocketLedger,
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        let session = fixture.terminalSessionID

        let old = try #require(BridgeChannel.mint(
            session: session, previousGeneration: 0,
            localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
        ))
        let oldFlag = AsyncFlag()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl", remote: Self.remote, channel: old,
                shutdown: { await oldFlag.signal() }
            ),
            for: session
        )
        let staleToken = try #require(registry.currentToken(for: session))

        // A reconnect re-mints a successor for the same session (replaces entry).
        let new = try #require(BridgeChannel.mint(
            session: session, previousGeneration: old.gen,
            localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
        ))
        #expect(new.token != old.token)
        let newFlag = AsyncFlag()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl", remote: Self.remote, channel: new,
                shutdown: { await newFlag.signal() }
            ),
            for: session
        )

        // The stale (old-token) teardown must NOT break the successor.
        await registry.teardown(for: session, ifToken: staleToken)
        #expect(!(await newFlag.isSet))

        // The successor's own token still tears it down.
        let liveToken = try #require(registry.currentToken(for: session))
        await registry.teardown(for: session, ifToken: liveToken)
        #expect(await newFlag.isSet)
    }
}

/// Async flag: an actor-backed one-shot the spy generation's `shutdown` fulfils,
/// so a test can await a fire-and-forget teardown deterministically instead of
/// polling.
actor AsyncFlag {
    private var flagged = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSet: Bool { flagged }

    func signal() {
        flagged = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if flagged { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BridgeTeardownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
        }
        completed = true
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilCompleted() async {
        guard !completed else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }
}
