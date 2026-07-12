import AwesoMuxCore
import Foundation

/// The async make-before-break state machine for one remote-bridge attach.
///
/// One instance owns the serialized attach lifecycle for a single pane: it
/// stands up a fresh transport (mint → bind listener → reverse forward →
/// owner-only admission → atomic state-file publish) entirely before it touches
/// the previous generation, and breaks the old generation only after the
/// publish — the readiness commit. A failure anywhere before the commit rolls
/// back **only the new resources**; the old generation's state file, forward,
/// socket, and listener stay intact and working by construction.
///
/// Serialized per pane, single-flight: a second `attach` while one is preparing
/// cancels-and-restarts, mirroring `GhosttySurfaceNSView`'s
/// `pendingSurfaceCreationWorkItem` cancel-then-reschedule. The cancelled run
/// tears down whatever new resources it had staged and never touches the live
/// generation.
actor BridgeAttachPreflight {
    /// A bound local listener as this state machine needs to see it: where to
    /// point the reverse forward, and how to tear it down. Produced by the
    /// `makeListener` seam; the live default wraps a real
    /// `BridgeConnectionActor` (C1). This is the seam's return *shape*, not a
    /// competing listener abstraction — the preflight only ever needs these two
    /// things from whatever C1 exposes.
    struct PreparedListener: Sendable {
        let socketPath: String
        let shutdown: @Sendable () async -> Void
    }

    enum DegradedReason: Sendable, Equatable {
        /// `BridgeChannel.mint` returned nil — an unusable remote home.
        case mintFailed
        /// The local listener would not bind (spec step 2).
        case listenerFailed
        /// The bridge-ready pane command could not be assembled.
        case commandFailed
        /// The reverse forward would not establish (spec step 3, forward).
        case forwardFailed
        /// The remote socket stat'd not-owner-only, or the probe failed (step 3).
        case admissionRejected
        /// The atomic state-file publish failed (spec step 4).
        case publishFailed
    }

    enum Outcome: Sendable, Equatable {
        /// The new generation is live and published; `command` is the
        /// env-prefixed remote command the caller spawns the pane with.
        case ready(channel: BridgeChannel, command: String)
        /// Fail-open to no-bridge; the terminal stays usable. The old
        /// generation, if any, is untouched.
        case degraded(DegradedReason)
        /// A newer attach superseded this one before it committed.
        case cancelled
    }

    struct Request: Sendable {
        let session: TerminalSessionID
        let remote: RemoteTarget
        let controlPath: String
        let remoteHome: String
        let helperPath: String
        /// Builds the pane-spawn command once the channel's state-file path is
        /// minted. Production uses this boundary to put the bridge env wrapper
        /// inside SSH's remote command rather than on the local `amx` process.
        let commandBuilder: @Sendable (BridgeChannel) -> String?
    }

    // Closures with live defaults, not protocols — one real implementation each.
    typealias ExecChannel = @Sendable (_ command: String, _ stdin: Data?) async throws -> Data
    typealias MakeListener = @Sendable (_ token: String, _ session: TerminalSessionID) async throws -> PreparedListener

    private let ledger: BridgeSocketLedger
    private let execChannel: ExecChannel
    private let makeListener: MakeListener
    private let now: @Sendable () -> Date

    /// The live generation's listener, retained so the *next* attach can shut
    /// it down after its own publish. The matching remote socket path lives in
    /// the ledger (the deletion authority); this holds only the local handle
    /// the ledger cannot.
    private var current: PreparedListener?
    private var inFlight: Task<Outcome, Never>?
    /// Distinguishes "my run finished and nothing superseded it" from "a newer
    /// attach already replaced me" when clearing `inFlight`, without relying on
    /// `Task` identity (which it does not expose).
    private var requestCounter = 0

    init(
        ledger: BridgeSocketLedger,
        now: @escaping @Sendable () -> Date = Date.init,
        execChannel: @escaping ExecChannel = BridgeAttachPreflight.liveExecChannel,
        makeListener: @escaping MakeListener = BridgeAttachPreflight.liveMakeListener
    ) {
        self.ledger = ledger
        self.now = now
        self.execChannel = execChannel
        self.makeListener = makeListener
    }

    /// Runs one attach, serialized against any in-flight attach for this pane.
    /// A concurrent call cancels the predecessor (which unwinds its own staged
    /// resources and resolves `.cancelled`) before this one starts, so two
    /// runs never race on the live generation.
    func attach(_ request: Request) async -> Outcome {
        requestCounter += 1
        let myID = requestCounter
        let predecessor = inFlight
        predecessor?.cancel()

        let task = Task { [weak self] in
            // Let the predecessor fully unwind first — its rollback touches
            // only its own staged resources, but serializing keeps the command
            // stream and `current` free of interleaving.
            _ = await predecessor?.value
            guard let self, !Task.isCancelled else { return Outcome.cancelled }
            return await self.run(request)
        }
        inFlight = task
        let outcome = await task.value
        // Only the latest requester clears the slot; an older one that a newer
        // attach already superseded must not stomp the newer task's handle.
        guard requestCounter == myID else {
            // A newer attach superseded this one. If we already committed
            // `.ready`, return that outcome so the caller's stale path can
            // `discardCommittedBridgeGeneration` — remapping to `.cancelled`
            // previously dropped cleanup duty onto a successor that may never
            // publish (review finding R-2).
            return outcome
        }
        inFlight = nil
        return outcome
    }

    // MARK: - Sequence

    private func run(_ request: Request) async -> Outcome {
        // 1. previousGeneration from the ledger (the fresh-epoch 0 → gen 1 case
        //    is exactly a first attach or a post-restart attach).
        let previousGeneration = await ledger.previousGeneration(for: request.session)

        // 2. Mint. `localSocketPath` is a mint passthrough filled in after the
        //    listener binds below — binding is the live side effect the pure
        //    mint cannot perform, and the listener needs this run's token, so
        //    the token must exist first. Nothing external exists yet, so a mint
        //    failure needs no rollback.
        guard let minted = BridgeChannel.mint(
            session: request.session,
            previousGeneration: previousGeneration,
            localSocketPath: "",
            remoteHome: request.remoteHome
        ) else {
            return .degraded(.mintFailed)
        }
        if Task.isCancelled { return .cancelled }

        // 3. Bind the NEW listener — the first new resource.
        let listener: PreparedListener
        do {
            listener = try await makeListener(minted.token, request.session)
        } catch {
            return .degraded(.listenerFailed)
        }
        let channel = BridgeChannel(
            token: minted.token,
            gen: minted.gen,
            localSocketPath: listener.socketPath,
            remoteSocketPath: minted.remoteSocketPath,
            stateFilePath: minted.stateFilePath,
            session: minted.session
        )
        guard let readyCommand = request.commandBuilder(channel) else {
            await listener.shutdown()
            return .degraded(.commandFailed)
        }
        if Task.isCancelled {
            await listener.shutdown()
            return .cancelled
        }

        // 4. Establish the NEW reverse forward.
        do {
            _ = try await execChannel(
                AmxBackend.bridgeReverseForwardCommand(
                    controlPath: request.controlPath, remote: request.remote, channel: channel
                ),
                nil
            )
        } catch {
            // A thrown exec cannot prove the forward never registered: a
            // timeout or cancellation can race a `-O forward` the master
            // already accepted. Cancelling an unestablished forward is a
            // harmless no-op (spec finding 16a), so always attempt the cancel
            // rather than leak a forward on the ambiguous-completion path.
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .degraded(.forwardFailed)
        }
        if Task.isCancelled {
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .cancelled
        }

        // 5. Owner-only admission on the just-bound remote socket. The
        //    bind→stat→publish window is a TOCTOU a same-UID remote process
        //    could exploit by re-binding after the check — but a same-UID
        //    process is already inside the trust boundary (spec Security
        //    analysis), and the per-attach token still gates every frame, so
        //    the worst case stays no-misdelivery.
        let admissionOutput: Data
        do {
            admissionOutput = try await execChannel(
                AmxBackend.bridgeRemoteSocketAdmissionCommand(
                    controlPath: request.controlPath, remote: request.remote,
                    remoteSocketPath: channel.remoteSocketPath
                ),
                nil
            )
        } catch {
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .degraded(.admissionRejected)
        }
        guard AmxBackend.bridgeAdmissionPassed(
            statOutput: String(decoding: admissionOutput, as: UTF8.self)
        ) else {
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .degraded(.admissionRejected)
        }
        if Task.isCancelled {
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .cancelled
        }

        // 6. Atomic state-file publish — the readiness commit.
        guard let write = AmxBackend.bridgeStateFileWriteCommand(
            controlPath: request.controlPath, remote: request.remote, channel: channel
        ) else {
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .degraded(.publishFailed)
        }
        do {
            _ = try await execChannel(write.command, write.stdinData)
        } catch {
            // A thrown publish is treated as failed and rolled back to the
            // prior generation (spec step-4 rollback). The one ambiguous case —
            // the remote `rename(2)` actually landed but the local ssh was
            // killed before returning 0 — leaves the published state file
            // naming this new, now-torn-down generation. That is
            // degraded-never-wrong: the new token matches no live listener
            // (this one is closing; the old one holds a different token), so no
            // frame can be misdelivered, and the next attach re-mints and
            // re-publishes (the AMX_STATUS_TOKEN self-healing model). Verifying
            // the write would need an extra read the spec does not mandate.
            await rollbackNew(request: request, channel: channel, listener: listener)
            return .degraded(.publishFailed)
        }

        // Past the readiness commit the new generation is the published truth;
        // a late cancellation no longer rolls back, and the OLD generation is
        // now broken deliberately.
        let previousEntry = await ledger.commit(
            session: request.session,
            generation: channel.gen,
            remoteSocketPath: channel.remoteSocketPath,
            mintedAt: now()
        )

        // 7. Break the old generation, only now. Its teardown commands are
        //    best-effort no-ops when the master is already gone or rejects the
        //    cancel (spec finding 16 a/b/c) — a failure here never demotes a
        //    committed `ready`.
        await breakOldGeneration(request: request, previousEntry: previousEntry)
        current = listener

        return .ready(
            channel: channel,
            command: readyCommand
        )
    }

    /// Tears down this run's own staged forward + listener + the exact remote
    /// socket this run minted. The ledger is the sole deletion authority for
    /// *committed* paths; an uncommitted mint never entered the ledger, so
    /// rolling back without an exact-path `rm` permanently leaked
    /// `/tmp/awesomux-bridge-*.sock` on every failed admission/publish
    /// (review finding Codex #3).
    private func rollbackNew(request: Request, channel: BridgeChannel, listener: PreparedListener) async {
        _ = try? await execChannel(
            AmxBackend.bridgeReverseForwardCancelCommand(
                controlPath: request.controlPath, remote: request.remote,
                remoteSocketPath: channel.remoteSocketPath,
                localSocketPath: channel.localSocketPath
            ),
            nil
        )
        _ = try? await execChannel(
            AmxBackend.bridgeRemoteSocketRemoveCommand(
                controlPath: request.controlPath,
                remote: request.remote,
                remoteSocketPath: channel.remoteSocketPath
            ),
            nil
        )
        await listener.shutdown()
    }

    /// Cancels the previous forward, removes its remote socket by the exact
    /// ledger path, and closes its listener. The old listener handle lives in
    /// `current`; the old remote path comes from the ledger entry `commit` just
    /// replaced — the pairing is exact (a live `current` implies a prior commit
    /// for this session in this run). All three steps are best-effort.
    private func breakOldGeneration(request: Request, previousEntry: BridgeSocketLedger.Entry?) async {
        guard let oldListener = current else { return }
        // Revoke the old token locally at the readiness commit before any slow
        // SSH cleanup. The remote commands use captured paths and do not need a
        // live listener; keeping it open would let a superseded helper continue
        // sending authenticated frames while cancel/rm waits on the network.
        await oldListener.shutdown()
        if let previousEntry {
            // Cancel-the-old-forward and rm-the-old-socket act on the same
            // already-known old path, neither reads the other's result, both
            // best-effort — so run them concurrently rather than serializing
            // two ssh round trips on the make-before-break path that gates the
            // pane spawn (review finding). Both ride the same ControlMaster,
            // which handles concurrent local clients fine.
            let exec = execChannel
            let cancelCommand = AmxBackend.bridgeReverseForwardCancelCommand(
                controlPath: request.controlPath, remote: request.remote,
                remoteSocketPath: previousEntry.remoteSocketPath,
                localSocketPath: oldListener.socketPath
            )
            let removeCommand = AmxBackend.bridgeRemoteSocketRemoveCommand(
                controlPath: request.controlPath, remote: request.remote,
                remoteSocketPath: previousEntry.remoteSocketPath
            )
            async let cancel: Void = { _ = try? await exec(cancelCommand, nil) }()
            async let remove: Void = { _ = try? await exec(removeCommand, nil) }()
            _ = await (cancel, remove)
        }
    }

    // MARK: - Live seam defaults

    /// Runs one exec channel over the shared ControlMaster and returns its
    /// stdout. `BoundedCommandRunner` executes the assembled `ssh` command
    /// through the login shell so `-S <ControlPath>` and the piped stdin
    /// behave exactly as the assembly built them.
    private static let liveExecChannel: ExecChannel = { command, stdin in
        try await BridgeExecChannel.run(command: command, stdin: stdin)
    }

    /// Binds a real C1 listener for this attach. The bound socket path and a
    /// shutdown hook are all the *preflight* needs to point a forward at it and
    /// tear it down.
    ///
    /// ⚠️ Placeholder pending integration: this default deliberately does NOT
    /// call `connection.start()` or wire a `BridgeConnectionSupervisor` to
    /// drain `connection.frames` — starting the accept loop with no drainer
    /// would buffer frames unboundedly. The integration task that gives
    /// `BridgeAttachPreflight` its first caller must supply a `makeListener`
    /// that also stands up the supervisor (and retains it for the pane's
    /// lifetime), or a bridge bound here would accept the forward but never
    /// process a single frame. There is no caller of `attach(_:)` yet, so this
    /// placeholder is inert rather than a live defect.
    private static let liveMakeListener: MakeListener = { token, session in
        let connection = try BridgeConnectionActor(
            expectedToken: token,
            expectedSession: session.rawValue
        )
        return PreparedListener(socketPath: connection.socketPath) {
            await connection.shutdown()
        }
    }
}
