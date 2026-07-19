import AwesoMuxCore
import Dispatch
import Foundation

/// Owns every prepared or live `awesomux-bridge-v1` generation the app is
/// currently running and is the single place the runtime tears one down. Held by `GhosttyRuntime`,
/// mirroring the `commandBridgeRecoveryRecords` ownership pattern (a
/// `@MainActor`-isolated dictionary on the same class).
///
/// A "generation" is the channel + the
/// connection supervisor/actor that drains it + the ledger entry that records
/// its remote socket path. This type retains the supervisor (through the
/// `shutdown` closure), holds the exact minted paths (through the channel), and
/// composes with `BridgeSocketLedger` — the sole deletion authority and the
/// `previousGeneration` source — never globbing and never bypassing it.
///
/// **Isolation: `@MainActor`, not `actor`.** The two runtime hooks force it.
/// `GhosttyRuntime.discardSurface` runs on the main actor and must dispatch a
/// teardown without an actor hop stranding it; `applicationWillTerminate` is a
/// synchronous main-actor call that has to run a **bounded** best-effort sweep
/// before the process exits — impossible against an `actor`, whose methods can
/// only be reached with an `await` quit cannot perform. Matching
/// `commandBridgeRecoveryRecords`' main-actor isolation is also what lets the
/// discard hook read and mutate this registry inline.
@MainActor
final class BridgeGenerationRegistry {
    /// One live bridge generation. Mirrors `BridgeAttachPreflight`'s
    /// `PreparedListener` closure-seam shape (`shutdown: @Sendable () async ->
    /// Void`) rather than reaching into `BridgeConnectionSupervisor` directly:
    /// the closure both performs the listener/actor/supervisor teardown and,
    /// by capturing the supervisor, retains it for the pane's lifetime.
    struct Generation: Sendable {
        let controlPath: String
        let remote: RemoteTarget
        /// The exact per-attach channel. Its `remoteSocketPath` is byte-for-byte
        /// the value the ledger committed for this generation (both come from the
        /// same mint), and `localSocketPath` — which the ledger does not store —
        /// is the other half of the `-O cancel` pair.
        let channel: BridgeChannel
        /// Tears down this generation's local listener + connection actor +
        /// supervisor. Best-effort, idempotent on the supervisor's side.
        let shutdown: @Sendable () async -> Void
        /// Shared with the attach task while this generation is staged. Quit
        /// requests termination through it and orders cleanup after any remote
        /// mutation that was already active.
        let terminationBarrier: BridgePreflightTerminationBarrier?

        init(
            controlPath: String,
            remote: RemoteTarget,
            channel: BridgeChannel,
            shutdown: @escaping @Sendable () async -> Void,
            terminationBarrier: BridgePreflightTerminationBarrier? = nil
        ) {
            self.controlPath = controlPath
            self.remote = remote
            self.channel = channel
            self.shutdown = shutdown
            self.terminationBarrier = terminationBarrier
        }
    }

    /// Runs one already-assembled teardown command over the shared
    /// ControlMaster. Best-effort: teardown swallows every throw (master death,
    /// app restart, a cancel the master rejects — the spec's step-5 no-op
    /// shapes), so this seam only has to *attempt* the command.
    typealias ExecChannel = @Sendable (_ command: String) async throws -> Data
    /// The synchronous twin used only by the app-quit sweep, where no `await`
    /// is available. Blocks until its command finishes; the registry bounds the
    /// *total* sweep off-thread, so this seam needs no timeout of its own.
    typealias SyncExec = @Sendable (_ command: String) -> Void

    private let ledger: BridgeSocketLedger
    private let execChannel: ExecChannel
    private let syncExec: SyncExec
    private var generations: [TerminalSessionID: Generation] = [:]
    private var stagedGenerations: [String: Generation] = [:]
    /// Exact generations removed from staged/live ownership whose asynchronous
    /// cleanup has not completed. Quit may safely retry their idempotent commands.
    private var retiringGenerations: [String: Generation] = [:]
    private var isTerminating = false

    init(
        ledger: BridgeSocketLedger,
        execChannel: @escaping ExecChannel = BridgeGenerationRegistry.liveExecChannel,
        syncExec: @escaping SyncExec = BridgeGenerationRegistry.liveSyncExec
    ) {
        self.ledger = ledger
        self.execChannel = execChannel
        self.syncExec = syncExec
    }

    /// Genuine pane/session close tears the generation down; a heal/respawn
    /// preserves it for transfer to the successor's re-mint (the spec's
    /// recovery-record survival contract — D2 step 5 breaks the old generation
    /// only after the new one publishes). Mirrors `discardSurface`'s
    /// `!preservesRecoveryRecord` gate as a pure function so the runtime's
    /// routing decision is unit-testable without a live surface.
    nonisolated static func shouldTearDown(preservesRecoveryRecord: Bool) -> Bool {
        !preservesRecoveryRecord
    }

    /// Records a freshly-published generation for `session`, replacing any prior
    /// entry. Replacing does **not** tear the prior generation down: on a
    /// reattach the make-before-break attach sequence (D2 step 5) already broke
    /// the old transport before this re-registration, and a heal transfers the
    /// same generation forward. The successor owns the break; the registry only
    /// tracks the current handle.
    func register(_ generation: Generation, for session: TerminalSessionID) {
        stagedGenerations.removeValue(forKey: generation.channel.token)
        guard !isTerminating else {
            generation.terminationBarrier?.requestTermination()
            return
        }
        generations[session] = generation
    }

    /// Makes a prepared generation visible to the synchronous quit sweep before
    /// preflight performs its first remote mutation. It remains staged by token
    /// until readiness promotion moves it into the live session slot or rollback
    /// removes it after cleaning up its own resources.
    func stageForTermination(_ generation: Generation) {
        guard !isTerminating else {
            generation.terminationBarrier?.requestTermination()
            return
        }
        stagedGenerations[generation.channel.token] = generation
    }

    func discardStaged(token: String) {
        stagedGenerations.removeValue(forKey: token)
    }

    /// Tears down `session`'s live generation: cancel the reverse forward, `rm`
    /// the remote socket by its exact ledger path, shut the local
    /// listener/actor/supervisor, and forget the ledger entry. This is both the
    /// genuine-close path (discard hook) and the explicit teardown API the D4
    /// enactor paths (session re-point / local-shell fallback / error latch)
    /// call.
    ///
    /// Idempotent: the entry is removed synchronously before the first `await`,
    /// so a second call — or an unknown session — is a silent no-op, and two
    /// racing teardowns can never double-run the commands. Every command is
    /// best-effort (`try?`); a failed cancel/rm degrades, never errors, and
    /// never logs secrets.
    /// The channel token of the generation currently registered for `session`,
    /// or nil. Lets a caller capture generation identity *synchronously* at
    /// teardown-decision time and tear down only THAT generation via
    /// `teardown(for:ifToken:)`, so a successor re-mint registered between the
    /// capture and the (async, fire-and-forget) teardown is never wrongly
    /// removed. The same successor-protection shape as
    /// `BridgeSocketLedger.forget(_:ifMatches:)`.
    func currentToken(for session: TerminalSessionID) -> String? {
        generations[session]?.channel.token
    }

    /// Atomically moves and returns the currently registered generation so a
    /// same-session replacement can occupy the live slot while quit retains
    /// visibility until the old generation's asynchronous teardown completes.
    func takeGeneration(for session: TerminalSessionID) -> Generation? {
        guard let generation = generations.removeValue(forKey: session) else {
            return nil
        }
        retiringGenerations[generation.channel.token] = generation
        return generation
    }

    /// Tears down `session`'s generation only if it still names `token`. A stale
    /// enactor teardown (error latch / re-point fired, then the pane reconnected
    /// and registered a fresh generation before this async task ran) finds a
    /// different token and no-ops, so it can never break the successor. The token
    /// check and the removal share one MainActor step — no suspension between the
    /// guard here and the `removeValue` in `teardown(for:)` — so the compare and
    /// the act are atomic.
    func teardown(for session: TerminalSessionID, ifToken token: String) async {
        guard generations[session]?.channel.token == token else { return }
        await teardown(for: session)
    }

    func teardown(for session: TerminalSessionID) async {
        guard let generation = generations.removeValue(forKey: session) else {
            return
        }
        retiringGenerations[generation.channel.token] = generation
        await tearDown(generation, for: session)
        retiringGenerations.removeValue(forKey: generation.channel.token)
    }

    /// Tears down a committed generation that never became this registry's live
    /// entry. This is the stale-preflight completion path: a successor may
    /// already be registered for the same session, so cleanup must use the stale
    /// generation's captured resources without inserting or removing the live
    /// dictionary entry. Local authority and the ledger retire before this
    /// returns, releasing the preflight successor barrier; exact-path remote
    /// cleanup continues independently through commands with their own bounds.
    func discardCommitted(_ generation: Generation, for session: TerminalSessionID) async {
        stagedGenerations.removeValue(forKey: generation.channel.token)
        retiringGenerations[generation.channel.token] = generation
        await retireLocalAuthority(generation, for: session)
        let commands = remoteTeardownCommands(for: generation)
        let exec = execChannel
        let token = generation.channel.token
        // Do not hold a same-session successor behind unreachable-host cleanup.
        // These commands carry only the stale generation's captured paths; the
        // state-file command additionally checks the stale socket basename, and
        // each exec has the command runner's existing bound.
        Task.detached { [weak self] in
            await Self.runRemoteTeardown(commands: commands, exec: exec)
            await self?.finishRetiring(token: token)
        }
    }

    /// Completes teardown for a live generation already removed synchronously
    /// with `takeGeneration(for:)`.
    func tearDownExtracted(_ generation: Generation, for session: TerminalSessionID) async {
        retiringGenerations[generation.channel.token] = generation
        await tearDown(generation, for: session)
        retiringGenerations.removeValue(forKey: generation.channel.token)
    }

    private func finishRetiring(token: String) {
        retiringGenerations.removeValue(forKey: token)
    }

    var hasTerminationWork: Bool {
        !generations.isEmpty || !stagedGenerations.isEmpty || !retiringGenerations.isEmpty
    }

    private func tearDown(_ generation: Generation, for session: TerminalSessionID) async {
        // Delete this generation's OWN exact minted socket path, captured with
        // the entry — never a post-`await` ledger read keyed only by `session`.
        // The captured value is byte-for-byte what the ledger committed for this
        // generation (register receives the same minted channel), so this
        // honors the sole-deletion-authority invariant (exact minted path, never
        // a glob, only a socket the registry itself registered) while staying
        // race-free: a re-mint that commits a successor under the same session
        // key mid-teardown cannot redirect this cancel/rm onto the successor's
        // socket.
        await retireLocalAuthority(generation, for: session)
        await Self.runRemoteTeardown(
            commands: remoteTeardownCommands(for: generation),
            exec: execChannel
        )
    }

    private func retireLocalAuthority(
        _ generation: Generation,
        for session: TerminalSessionID
    ) async {
        await generation.shutdown()
        await ledger.forget(session, ifMatches: generation.channel.remoteSocketPath)
    }

    private func remoteTeardownCommands(for generation: Generation) -> [String] {
        let remoteSocketPath = generation.channel.remoteSocketPath
        return [
            AmxBackend.bridgeReverseForwardCancelCommand(
                controlPath: generation.controlPath,
                remote: generation.remote,
                remoteSocketPath: remoteSocketPath,
                localSocketPath: generation.channel.localSocketPath
            ),
            AmxBackend.bridgeRemoteSocketRemoveCommand(
                controlPath: generation.controlPath,
                remote: generation.remote,
                remoteSocketPath: remoteSocketPath
            ),
            // Finding #7: the state file is per-session (`<session>.json`), so a
            // make-before-break re-mint overwrites it in place — only a GENUINE
            // close leaves it orphaned. Same captured-exact-path discipline as the
            // socket rm above, plus the generation-identity guard: the awaits
            // above suspend long enough for a close-then-reopen successor to
            // publish at this same path, and the builder's grep-guard keeps this
            // delete off the successor's live file.
            AmxBackend.bridgeStateFileRemoveCommand(
                controlPath: generation.controlPath,
                remote: generation.remote,
                stateFilePath: generation.channel.stateFilePath,
                remoteSocketPath: remoteSocketPath
            )
        ]
    }

    private nonisolated static func runRemoteTeardown(
        commands: [String],
        exec: @escaping ExecChannel
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask { _ = try? await exec(command) }
            }
        }
    }

    /// App-quit sweep: a best-effort, **bounded** `-O cancel` + exact-path
    /// `rm -f` for every prepared, live, or retiring generation, run before the
    /// process exits. Never blocks quit beyond `budget` (~2 s across all entries).
    ///
    /// The sweep runs off the main thread and the wait is hard-capped, so a slow
    /// or unreachable remote can never hold quit past the budget. When the wait
    /// times out we return anyway and let the background work finish detached.
    /// `-O cancel` is local IPC to the ControlMaster (fast even when the remote
    /// is unreachable); only the remote `rm` can stall, and it is self-bounding —
    /// it rides the master, whose injected `ServerAliveInterval` tears a dead
    /// connection down within ~tens of seconds, so an orphaned child reaped by
    /// launchd after quit is bounded, not indefinite, and its work is beneficial
    /// (it still cleans the remote socket if the link recovers). We deliberately
    /// do NOT kill it on timeout: terminating mid-`rm` would only abort useful
    /// cleanup, landing in the same spec-accepted degraded state as never running
    /// it — the orphaned forward points at a listener that vanished with the app,
    /// the helper's next connect fails silent, and the inert socket file is
    /// removed by the next attach's exact-path `rm` or surfaced by the doctor.
    /// Listeners are not shut down and the ledger is not forgotten here: both die
    /// with the process, and the ledger does not survive a run.
    ///
    /// Paths come from each held generation's channel — the exact minted values,
    /// identical to the ledger's committed entries, never a glob. The ledger is
    /// an `actor` and this path is synchronous, so it cannot be read here; the
    /// channel is the same authority's value captured at register time.
    func drainForTermination(budget: TimeInterval = 2) {
        isTerminating = true
        guard
            !generations.isEmpty || !stagedGenerations.isEmpty || !retiringGenerations.isEmpty
        else {
            return
        }

        let visibleGenerations =
            Array(generations.values)
            + Array(stagedGenerations.values)
            + Array(retiringGenerations.values)
        for generation in visibleGenerations {
            generation.terminationBarrier?.requestTermination()
        }
        let commands = visibleGenerations.flatMap { generation -> [(String, BridgePreflightTerminationBarrier?)] in
            let commands = [
                AmxBackend.bridgeReverseForwardCancelCommand(
                    controlPath: generation.controlPath,
                    remote: generation.remote,
                    remoteSocketPath: generation.channel.remoteSocketPath,
                    localSocketPath: generation.channel.localSocketPath
                ),
                AmxBackend.bridgeRemoteSocketRemoveCommand(
                    controlPath: generation.controlPath,
                    remote: generation.remote,
                    remoteSocketPath: generation.channel.remoteSocketPath
                ),
                AmxBackend.bridgeStateFileRemoveCommand(
                    controlPath: generation.controlPath,
                    remote: generation.remote,
                    stateFilePath: generation.channel.stateFilePath,
                    remoteSocketPath: generation.channel.remoteSocketPath
                )
            ]
            return commands.map { ($0, generation.terminationBarrier) }
        }
        generations.removeAll()
        stagedGenerations.removeAll()
        retiringGenerations.removeAll()

        // Fan the per-generation command chains out concurrently (review
        // finding): a single-file loop shared one `budget` clock across ALL
        // generations, so with several live panes the later generations got
        // no cleanup time — a silent scaling cliff. One dispatched block per
        // command bounds the budget by the SLOWEST single command instead of
        // their sum. All ride the same ControlMaster, which serves concurrent
        // local clients fine.
        let exec = syncExec
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        for (command, terminationBarrier) in commands {
            queue.async(group: group) {
                terminationBarrier?.waitUntilDrained()
                exec(command)
            }
        }
        _ = group.wait(timeout: .now() + budget)
    }

    /// The app-approval termination path. Unlike `drainForTermination`, this
    /// does not release AppKit's deferred-termination reply until every active
    /// preflight mutation has drained and every exact-path cleanup attempt has
    /// completed. Production mutation and cleanup execs each use
    /// `BridgeExecChannel`'s 15-second hard bound and cleanup fans out, so the
    /// total deferral is bounded to roughly 30 seconds in the worst case.
    func drainForTerminationBeforeExit() async {
        isTerminating = true
        guard hasTerminationWork else { return }

        let visibleGenerations =
            Array(generations.values)
            + Array(stagedGenerations.values)
            + Array(retiringGenerations.values)
        for generation in visibleGenerations {
            generation.terminationBarrier?.requestTermination()
        }
        let cleanupEntries = visibleGenerations.map {
            (remoteTeardownCommands(for: $0), $0.terminationBarrier)
        }
        generations.removeAll()
        stagedGenerations.removeAll()
        retiringGenerations.removeAll()

        let exec = execChannel
        await withTaskGroup(of: Void.self) { group in
            for (commands, terminationBarrier) in cleanupEntries {
                group.addTask {
                    await terminationBarrier?.waitUntilDrainedAsync()
                    await Self.runRemoteTeardown(commands: commands, exec: exec)
                }
            }
        }
    }

    // MARK: - Live seam defaults

    private static let liveExecChannel: ExecChannel = { command in
        try await BridgeExecChannel.run(command: command, stdin: nil)
    }

    private static let liveSyncExec: SyncExec = { command in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Best-effort: a spawn failure during quit is a silent no-op — nothing
        // to recover, and nothing worth logging (never a secret) on the way out.
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
