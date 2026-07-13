import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// INT-698 D4 keystone wiring, tested through the pure decisions the surface-view
// hot path is factored into (`BridgeAttachDecision`) plus the compare-and-clear
// invariant of the session-keyed coordinator store. No live ssh, socket, or
// runtime — the branch logic and the store race defenses in isolation.
@Suite("Bridge attach decisions")
struct BridgeAttachDecisionTests {
    private static let session = TerminalSessionID(rawValue: "d4-decisions")!
    private static let remote = RemoteTarget(user: "alice", host: "box")!

    // MARK: - Enable gate

    @Test("gate on only when remote AND agent chrome AND a base attach command, un-latched")
    func gateAllPreconditions() {
        #expect(BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: true, isRemote: true, agentChromeEnabled: true,
            attachCommandAvailable: true, errorLatched: false
        ))
    }

    @Test("gate off for a local pane")
    func gateOffLocal() {
        #expect(!BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: true, isRemote: false, agentChromeEnabled: true,
            attachCommandAvailable: true, errorLatched: false
        ))
    }

    @Test("gate off when the agent-integrations master switch is off")
    func gateOffAgentChromeDisabled() {
        #expect(!BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: true, isRemote: true, agentChromeEnabled: false,
            attachCommandAvailable: true, errorLatched: false
        ))
    }

    @Test("gate off with the command bridge master toggle off, no attach command, or latched")
    func gateOffOtherPreconditions() {
        #expect(!BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: false, isRemote: true, agentChromeEnabled: true,
            attachCommandAvailable: true, errorLatched: false
        ))
        #expect(!BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: true, isRemote: true, agentChromeEnabled: true,
            attachCommandAvailable: false, errorLatched: false
        ))
        #expect(!BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: true, isRemote: true, agentChromeEnabled: true,
            attachCommandAvailable: true, errorLatched: true
        ))
    }

    @Test("anyProviderEnabled tracks the master agent-integrations switch")
    func anyProviderEnabled() {
        #expect(!AgentIntegrationsConfig.defaultValue.anyProviderEnabled)
        var config = AgentIntegrationsConfig.defaultValue
        config.codex.enabled = true
        #expect(config.anyProviderEnabled)
    }

    // MARK: - Final command selection (fail-open posture)

    private func channel() throws -> BridgeChannel {
        try #require(BridgeChannel.mint(
            session: Self.session, previousGeneration: 0,
            localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
        ))
    }

    @Test("ready spawns the preflight's env-prefixed command")
    func finalCommandReady() throws {
        let readyCommand = "env AWESOMUX_BRIDGE_STATE=/Users/example/.awesomux/bridge/x.json zmx attach x"
        let outcome = BridgeAttachPreflight.Outcome.ready(channel: try channel(), command: readyCommand)
        #expect(BridgeAttachDecision.finalCommand(for: outcome, baseCommand: "BASE") == readyCommand)
    }

    @Test("degraded attaches with the base command, byte-identical, NO bridge env")
    func finalCommandDegradedByteIdentical() {
        let base = "env -u AMX_STATUS_FILE ZMX_DIR=/tmp amx attach x ssh -o ControlMaster=auto alice@box"
        for reason in [
            BridgeAttachPreflight.DegradedReason.mintFailed,
            .listenerFailed, .commandFailed, .forwardFailed, .admissionRejected, .publishFailed
        ] {
            let command = BridgeAttachDecision.finalCommand(for: .degraded(reason), baseCommand: base)
            #expect(command == base)
            // The safety guarantee: a degraded attach carries none of the bridge
            // injection — no state file, no helper, no session var.
            #expect(command?.contains("AWESOMUX_BRIDGE_") == false)
        }
    }

    @Test("cancelled spawns nothing — a superseding attach owns the pane")
    func finalCommandCancelled() {
        #expect(BridgeAttachDecision.finalCommand(for: .cancelled, baseCommand: "BASE") == nil)
    }

    // MARK: - Helper path convention (contributor ruling)

    @Test("helper path is the fixed convention beside the bridge state dir")
    func helperPathConvention() {
        #expect(BridgeAttachDecision.helperPath(remoteHome: "/Users/example")
            == "/Users/example/.awesomux/bin/awesomux-bridge-helper")
        // Trailing-slash / root-home normalization so no `//` is baked in.
        #expect(BridgeAttachDecision.helperPath(remoteHome: "/home/ed/")
            == "/home/ed/.awesomux/bin/awesomux-bridge-helper")
        #expect(BridgeAttachDecision.helperPath(remoteHome: "/")
            == "/.awesomux/bin/awesomux-bridge-helper")
    }

    // MARK: - Respawn re-mints a fresh token

    @Test("each mint produces a distinct forgery token (a respawn re-mints)")
    func mintReMintsFreshToken() throws {
        let first = try channel()
        let second = try #require(BridgeChannel.mint(
            session: Self.session, previousGeneration: first.gen,
            localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
        ))
        #expect(first.token != second.token)
        #expect(second.gen == first.gen + 1)
    }

    // MARK: - Coordinator store compare-and-clear

    @MainActor
    private func makeCoordinator() -> BridgePermissionCoordinator {
        BridgePermissionCoordinator(
            expectedToken: "tok",
            expectedSession: Self.session.rawValue,
            paneTitle: { "pane" },
            sendDecision: { _, _ in },
            announce: { _, _ in }
        )
    }

    @Test("clearLive only drops the slot when it still names the same coordinator")
    @MainActor
    func storeClearLiveCompareAndMatch() {
        let store = BridgeCoordinatorStore()
        let first = makeCoordinator()
        let second = makeCoordinator()

        store.setLive(session: Self.session, coordinator: first)
        // A re-mint replaced the live slot with `second`. The superseded
        // generation's teardown must NOT evict the successor.
        store.setLive(session: Self.session, coordinator: second)
        store.clearLive(session: Self.session, ifMatches: first)
        #expect(store.coordinator(for: Self.session) === second)

        // The successor's own teardown clears it.
        store.clearLive(session: Self.session, ifMatches: second)
        #expect(store.coordinator(for: Self.session) == nil)
    }

    @Test("takeStaged removes the entry so a later discard is a no-op")
    @MainActor
    func storeStagingHandoff() {
        let store = BridgeCoordinatorStore()
        let coordinator = makeCoordinator()
        store.stage(
            token: "tokA",
            BridgeCoordinatorStore.StagedBridgeRuntime(coordinator: coordinator, teardown: {})
        )
        let pulled = store.takeStaged(token: "tokA")
        #expect(pulled?.coordinator === coordinator)
        // Promotion won; the trio's own rollback discard now finds nothing.
        #expect(store.takeStaged(token: "tokA") == nil)
        store.discardStaged(token: "tokA") // no crash, no-op
    }
}
