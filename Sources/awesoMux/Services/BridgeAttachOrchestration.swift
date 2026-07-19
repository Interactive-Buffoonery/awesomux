import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Observation

/// The three full-runtime decisions the D4 keystone makes on the surface-view
/// hot path, factored out as pure functions so they are unit-testable without a
/// live `GhosttyRuntime`, `ssh`, or a bound socket. Everything stateful (the
/// preflight actor, the connection actor, the coordinator store) is wired around
/// these; the branch logic itself lives here.
///
/// The standing posture is fail-open to
/// no-bridge: every not-`ready` outcome must still hand the pane a usable attach.
enum BridgeAttachDecision {
    /// Whether `createSurfaceIfNeeded` kicks the async bridge preflight for this
    /// surface creation, instead of taking today's synchronous
    /// `prepareAttach` → `createSurface` path.
    ///
    /// The gate (contributor ruling): the pane is remote AND the agent-integrations
    /// master switch is on. `bridgeEnabled` (the command-bridge master toggle)
    /// and `attachCommandAvailable`/`!errorLatched` are the same preconditions
    /// today's attach already requires — a preflight over a pane that has no
    /// attach command, or one already latched to error, would have nothing to
    /// wrap.
    static func shouldRunPreflight(
        bridgeEnabled: Bool,
        isRemote: Bool,
        agentChromeEnabled: Bool,
        attachCommandAvailable: Bool,
        errorLatched: Bool
    ) -> Bool {
        bridgeEnabled && isRemote && agentChromeEnabled && attachCommandAvailable && !errorLatched
    }

    /// The command the pane is actually spawned with, given a preflight outcome
    /// and the base attach command `prepareAttach` already minted.
    ///
    /// - `.ready`: the preflight already env-prefixed the base command with the
    ///   `AWESOMUX_BRIDGE_*` values (`bridgeEnvironmentPrefixedRemoteCommand`),
    ///   so its `command` is what runs.
    /// - `.degraded`: fail-open to no-bridge — the pane attaches with the base
    ///   command, byte-identical to a bridge-off remote attach. No bridge env.
    /// - `.cancelled`: a superseding attach owns the pane; this run spawns
    ///   nothing (returns nil, and the caller must NOT create a surface).
    static func finalCommand(
        for outcome: BridgeAttachPreflight.Outcome,
        baseCommand: String
    ) -> String? {
        switch outcome {
        case .ready(_, let command):
            return command
        case .degraded:
            return baseCommand
        case .cancelled:
            return nil
        }
    }

    /// The remote helper path, resolved against the captured `$HOME` (contributor
    /// ruling): a fixed convention beside the `~/.awesomux/bridge` state dir.
    /// The attach only assumes the convention when a compatible helper is
    /// already available. A separate user-approved handoff remediation may
    /// install or update it. `remoteHome` is already an absolute path (helpers
    /// never expand `~`), so this is pure string
    /// composition with the same
    /// trailing-slash normalization `BridgeChannel.mint` applies to the state
    /// path so `/` (root home) can't bake a `//`.
    static func helperPath(remoteHome: String) -> String {
        var home = remoteHome
        while home.hasSuffix("/") { home.removeLast() }
        return home + "/.awesomux/bin/awesomux-bridge-helper"
    }
}

/// Whether an `AgentIntegrationsConfig` counts as "agent chrome on" for the
/// bridge gate — any provider enabled. The bridge exists to give a remote agent
/// the same sidebar chrome a local one gets; if the user has turned every agent
/// integration off, there is nothing for the bridge to surface, so the preflight
/// (which opens ssh exec channels and binds a socket) should not run.
extension AgentIntegrationsConfig {
    var anyProviderEnabled: Bool {
        claudeCode.enabled || codex.enabled || grok.enabled || openCode.enabled || pi.enabled
    }
}

/// The session-keyed lookup the D4 keystone owns (contributor ruling: "keep it on
/// GhosttyRuntime or the enactor, matching how `commandBridgeRecoveryRecords` is
/// keyed"). Held by `GhosttyRuntime`, `@MainActor`-isolated like its sibling
/// record store, so the banner, the focus command, and the make-before-break
/// teardown all read/mutate it inline with no actor hop.
///
/// It carries two maps, and the split is load-bearing for the make-before-break
/// invariant:
///
///  - **`staged`, keyed by the per-attach TOKEN.** `makeListener` (D2 step 3,
///    bind) builds the supervisor/coordinator trio *before* the attach commits,
///    but the banner must keep showing the OLD generation's coordinator until
///    the new one publishes (spec: the old generation stays fully working until
///    the readiness commit). So a freshly-built trio is *staged* by token, not
///    promoted to the live banner slot; a rollback (pre-commit failure) discards
///    the staged entry and never touches the live one. The ready handler pulls
///    the staged trio and promotes it.
///  - **`live`, keyed by SESSION.** The banner/focus lookup. Set only at the
///    readiness commit; cleared by compare-and-match so a torn-down old
///    generation can never evict the successor that replaced it (mirrors
///    `BridgeSocketLedger.forget(_:ifMatches:)`).
@MainActor
@Observable
final class BridgeCoordinatorStore {
    /// A built-but-not-yet-committed attach generation's user-facing half: the
    /// permission coordinator the banner will show, plus the idempotent teardown
    /// that shuts the whole trio (connection actor + supervisor + coordinator)
    /// and self-evicts from both maps.
    struct StagedBridgeRuntime {
        let coordinator: BridgePermissionCoordinator
        let teardown: @Sendable () async -> Void
    }

    /// `@ObservationIgnored`: staging churn (bind, rollback, promotion) must not
    /// re-render the banner — only the `live` slot the banner reads does.
    @ObservationIgnored private var staged: [String: StagedBridgeRuntime] = [:]
    /// Observed: the banner + focus lookup reads `coordinator(for:)`, so
    /// `setLive`/`clearLive` re-render the pane that shows this session.
    private var live: [TerminalSessionID: BridgePermissionCoordinator] = [:]

    func stage(token: String, _ runtime: StagedBridgeRuntime) {
        staged[token] = runtime
    }

    /// Pulls a staged trio at the readiness commit. Removing it here is what
    /// makes the trio's own `discardStaged` a no-op afterward (promotion won).
    func takeStaged(token: String) -> StagedBridgeRuntime? {
        staged.removeValue(forKey: token)
    }

    /// Rollback path: a staged trio whose attach never committed. Idempotent.
    func discardStaged(token: String) {
        staged.removeValue(forKey: token)
    }

    /// The readiness commit: the banner now shows this generation's coordinator.
    func setLive(session: TerminalSessionID, coordinator: BridgePermissionCoordinator) {
        live[session] = coordinator
    }

    /// Compare-and-clear: only drop the live slot if it still names THIS
    /// coordinator. A re-mint replaces `live[session]` with the successor at its
    /// own readiness commit; the superseded generation's teardown then finds a
    /// different coordinator and leaves it, exactly as the ledger's
    /// `forget(_:ifMatches:)` protects the successor's socket path.
    func clearLive(session: TerminalSessionID, ifMatches coordinator: BridgePermissionCoordinator) {
        if live[session] === coordinator {
            live.removeValue(forKey: session)
        }
    }

    /// The banner + focus-command lookup: the current generation's coordinator
    /// for `session`, or nil when no bridge generation is live for it.
    func coordinator(for session: TerminalSessionID) -> BridgePermissionCoordinator? {
        live[session]
    }
}

/// Late-bound relay from a coordinator's fire-and-forget `sendDecision` to its
/// supervisor. The supervisor is built *after* the coordinator (the coordinator
/// is the supervisor's frame-sink target), so the reference is set once, on the
/// MainActor, right after construction. Weak so the router never keeps a
/// torn-down generation's supervisor alive. The bounded pending count prevents
/// an authenticated peer that stops reading from creating an unbounded number
/// of fire-and-forget decision tasks.
@MainActor
final class BridgeDecisionRouter {
    weak var supervisor: BridgeConnectionSupervisor?
    private var pendingCount = 0
    private var isClosing = false

    func enqueue(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation) {
        guard pendingCount < BridgeTunables.outboundDecisionCap else {
            guard !isClosing else { return }
            isClosing = true
            Task { [weak self, weak supervisor] in
                await supervisor?.shutdown()
                await MainActor.run { self?.isClosing = false }
            }
            return
        }
        pendingCount += 1
        Task { [weak self, weak supervisor] in
            _ = await supervisor?.sendPermissionDecision(envelope: envelope, generation: generation)
            await MainActor.run { self?.pendingCount -= 1 }
        }
    }
}

// MARK: - GhosttyRuntime bridge trio assembly (INT-698 D4, items B/C/D)

extension GhosttyRuntime {
    /// The `makeListener` seam the placeholder in `BridgeAttachPreflight` left
    /// unwired: binds a real `BridgeConnectionActor`, stands up the
    /// supervisor + permission coordinator + read-model adapter, fans the
    /// supervisor's frames to both consumers, starts the accept loop, and stages
    /// the trio for the ready handler to promote. Captures only `Sendable` values
    /// (self, the store, ids) — never the AppKit view — so the `@Sendable`
    /// closure is clean; live pane context is resolved on the MainActor at use.
    @MainActor
    func makeBridgeListener(
        paneID: TerminalPane.ID,
        workspaceSessionID: TerminalSession.ID,
        sessionStore: SessionStore
    ) -> BridgeAttachPreflight.MakeListener {
        { [weak self] token, session in
            guard let self else {
                // Runtime gone: hand back an inert listener over a bare connection
                // actor. The preflight can still bind + return a socket path, so
                // the pane attaches; with no supervisor there is simply no frame
                // processing — the degraded-but-safe shape.
                let connection = try BridgeConnectionActor(
                    expectedToken: token,
                    expectedSession: session.rawValue
                )
                return BridgeAttachPreflight.PreparedListener(socketPath: connection.socketPath) {
                    await connection.shutdown()
                }
            }
            let built = try await self.buildStagedBridgeTrio(
                token: token,
                session: session,
                paneID: paneID,
                workspaceSessionID: workspaceSessionID,
                sessionStore: sessionStore
            )
            // Start the accept loop only after the drainer (supervisor) is wired,
            // so the very first frame is processed — the placeholder's warning.
            await built.supervisor.start()
            return BridgeAttachPreflight.PreparedListener(
                socketPath: built.socketPath,
                shutdown: built.teardown
            )
        }
    }

    /// Builds one generation's supervisor + coordinator + adapter, fans the
    /// sinks, and stages the trio by token. Returns the supervisor (to start) and
    /// the socket path (to point the forward at). The `teardown` it stages is the
    /// single idempotent shutdown both the make-before-break rollback/break-old
    /// (via `PreparedListener.shutdown`) and the registry (genuine close, via the
    /// generation's `shutdown`) run.
    @MainActor
    func buildStagedBridgeTrio(
        token: String,
        session: TerminalSessionID,
        paneID: TerminalPane.ID,
        workspaceSessionID: TerminalSession.ID,
        sessionStore: SessionStore
    ) throws -> (supervisor: BridgeConnectionSupervisor, socketPath: String, teardown: @Sendable () async -> Void) {
        let connection = try BridgeConnectionActor(
            expectedToken: token,
            expectedSession: session.rawValue
        )

        let router = BridgeDecisionRouter()
        let coordinator = BridgePermissionCoordinator(
            expectedToken: token,
            expectedSession: session.rawValue,
            paneTitle: { [weak sessionStore] in
                sessionStore?.session(id: workspaceSessionID)?.layout.pane(id: paneID)?.title ?? ""
            },
            paneDescriptor: { [weak sessionStore] in
                TerminalAccessibilityAnnouncer.paneDescriptor(
                    for: paneID,
                    in: sessionStore?.session(id: workspaceSessionID)
                )
            },
            sendDecision: { [router] envelope, generation in
                router.enqueue(envelope, generation: generation)
            },
            permissionEnabled: { [weak self] in
                // Same master-switch source as the attach-time preflight gate,
                // read live so a mid-session toggle-off stops permission prompts.
                self?.agentIntegrations.anyProviderEnabled ?? false
            },
            pendingCountChanged: { [weak sessionStore] oldCount, newCount in
                sessionStore?.updatePermissionPromptAttention(
                    sessionID: workspaceSessionID,
                    paneID: paneID,
                    countDelta: newCount - oldCount,
                    hasPending: newCount > 0
                )
            }
        )

        let adapter = BridgeAgentStatusAdapter(
            consent: { [weak self] in
                AgentRuntimeConsent(
                    enabledFileDropSources: AgentRuntimeConsent.enabledFileDropSources(
                        from: self?.agentIntegrations ?? .defaultValue
                    )
                )
            },
            applyEvent: { [weak self, weak sessionStore] event, _ in
                guard let sessionStore else { return }
                // Live focus read: the frame's `session` already matched the
                // pane at handshake, so we apply straight to the bound pane
                // rather than re-resolving the terminal session id.
                let focused = self?.cachedSurfaceView(for: paneID)?.terminalIsFocused ?? false
                _ = sessionStore.applyAgentRuntimeEvent(
                    event,
                    to: workspaceSessionID,
                    paneID: paneID,
                    terminalIsFocused: focused
                )
            },
            surfaceHandoff: { _, _ in
                // INT-699 owns the scp + inbox-path derivation + the
                // pane-facing surface. The bridge only NOTIFIES; there is nothing
                // for D4 to do with the notice yet, so drop it rather than invent a
                // surface INT-699 will define. Wire the real surfacing when INT-699
                // lands.
            }
        )

        // Route each validated frame to the ONE consumer that owns its type,
        // via a cheap non-isolated enum switch BEFORE any MainActor hop
        // (review finding): fanning every frame to both sinks paid two hops
        // where each type needs at most one, and a chatty per-second
        // agent-status heartbeat × N panes lands those wasted hops on the same
        // actor the sidebar renders on. `permissionDecision` is app→helper and
        // never arrives inbound — routed to neither.
        let frameSink: BridgeConnectionSupervisor.FrameSink = { envelope, generation in
            switch envelope.message {
            case .agentStatus, .paneRename, .handoffNotify:
                await adapter.frameSink(envelope, generation)
            case .permissionRequest, .permissionResolved:
                await coordinator.frameSink(envelope, generation)
            case .permissionDecision:
                break
            }
        }
        let connectionLostSink: BridgeConnectionSupervisor.ConnectionLostSink = { [weak coordinator] _ in
            // A replacement `hello` closed the old connection WITHIN this
            // generation: default-deny its pendings locally, write nothing to the
            // dead fd. The generation's socket/forward are unchanged, so the
            // registry is untouched — a whole-generation teardown is its job,
            // driven by the discard hook / enactor teardown parity, not this.
            await coordinator?.handleConnectionLost()
        }

        let supervisor = BridgeConnectionSupervisor(
            connectionActor: connection,
            expectedToken: token,
            expectedSession: session.rawValue,
            frameSink: frameSink,
            connectionLostSink: connectionLostSink
        )
        router.supervisor = supervisor

        let store = bridgeCoordinatorStore
        let teardown: @Sendable () async -> Void = {
            await supervisor.shutdown()
            await MainActor.run {
                coordinator.teardownState()
                store.discardStaged(token: token)
                store.clearLive(session: session, ifMatches: coordinator)
            }
        }

        store.stage(
            token: token,
            BridgeCoordinatorStore.StagedBridgeRuntime(coordinator: coordinator, teardown: teardown)
        )
        return (supervisor, connection.socketPath, teardown)
    }

    /// Disposal path for a COMMITTED (`.ready`) preflight outcome whose pane is
    /// gone or no longer creatable (review finding): the transport is already
    /// published (forward up, state file written, ledger advanced, trio staged),
    /// so it must be torn down through the registry — the one owner of the
    /// exact-path `-O cancel` + `rm` + trio shutdown — never just dropped.
    /// Register-then-teardown reuses those paths verbatim; `ifToken` (this
    /// generation's own token) protects a successor that races in between the
    /// two steps.
    @MainActor
    func discardCommittedBridgeGeneration(
        session: TerminalSessionID,
        channel: BridgeChannel,
        controlPath: String,
        remote: RemoteTarget
    ) {
        promoteBridgeGeneration(session: session, channel: channel, controlPath: controlPath, remote: remote)
        guard let registry = bridgeGenerationRegistry else { return }
        let token = channel.token
        Task { await registry.teardown(for: session, ifToken: token) }
    }

    /// The readiness commit (spec attach step 4+): promote the staged coordinator
    /// to the live banner slot and register the generation with the registry so
    /// genuine-close teardown (discard hook, enactor parity) can break it. A
    /// re-mint replaces the prior live coordinator + registry entry here; the
    /// preflight already broke the old transport (D2 step 5) before this runs, and
    /// the old trio's teardown clears its own live slot only if still matched.
    @MainActor
    func promoteBridgeGeneration(
        session: TerminalSessionID,
        channel: BridgeChannel,
        controlPath: String,
        remote: RemoteTarget
    ) {
        guard let staged = bridgeCoordinatorStore.takeStaged(token: channel.token) else {
            return
        }
        bridgeCoordinatorStore.setLive(session: session, coordinator: staged.coordinator)
        bridgeGenerationRegistry?.register(
            BridgeGenerationRegistry.Generation(
                controlPath: controlPath,
                remote: remote,
                channel: channel,
                shutdown: staged.teardown
            ),
            for: session
        )
    }
}
