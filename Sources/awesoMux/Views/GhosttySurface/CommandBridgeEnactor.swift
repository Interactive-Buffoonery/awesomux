import AppKit
import AwesoMuxCore

/// Owns command-bridge lifecycle state and maps bridge observations to app
/// effects: attach, local-shell fallback, remount, error latch, reconnect, and
/// normal exit. The pure per-decision policies (`BridgeSurfaceCommandPolicy`,
/// `BridgeSessionEndPolicy`, `CommandBridgeRespawnLedger`) live in `AwesoMuxCore`;
/// this type sequences them and enacts the results against the host view, store,
/// and runtime.
///
/// `GhosttySurfaceNSView` (the ``CommandBridgeEnactorHost``) stays the unsafe
/// AppKit/libghostty adapter and forwards its two ingress paths — the libghostty
/// process-exit callback and the `amx` status feed — into this enactor.
@MainActor
final class CommandBridgeEnactor {
    static let maxRespawnAttempts = CommandBridgeRespawnLedger.defaultMaxRespawnAttempts
    /// How long a fresh daemon incarnation must survive before its attach
    /// refills the respawn budget. Below this, an attach-then-die counts as a
    /// failed respawn and keeps the budget draining toward `.error`. Tuned long
    /// enough to clear a crash-on-spawn loop, short enough that a genuinely
    /// recovered session refills promptly.
    ///
    /// Ceiling: this bounds only crash loops whose period is shorter than this
    /// grace window. A daemon that survives `budgetRefillGrace` each cycle
    /// refills its budget via `CommandBridgeRespawnLedger.refillBudget` and
    /// respawns indefinitely — by design: sustained uptime reads as "mostly
    /// working" and the non-destructive respawn is preferable to latching error.
    /// Upgrade path if abuse surfaces: replace the hard reset-on-grace with a
    /// sliding-window attempt count (e.g. attempts in the last N seconds).
    static let budgetRefillGrace: TimeInterval = 5

    /// `unowned` is safe only because the host strongly owns this enactor (via a
    /// `lazy var`), so the enactor can never outlive the host — every deferred
    /// closure captures the enactor `[weak self]`, and a live enactor implies a
    /// live host. Never retain the enactor beyond the host's lifetime (e.g. in a
    /// runtime registry or a longer-lived closure) or this becomes a dangling access.
    private unowned let host: CommandBridgeEnactorHost

    var sessionID: TerminalSessionID? {
        didSet {
            guard sessionID != oldValue else {
                return
            }
            recoveryRecord = sessionID.map {
                host.runtime.commandBridgeRecoveryRecord(for: $0)
            }
        }
    }
    var errorLatched = false
    var exitResolutionPending = false
    var exitProbeInFlight = false
    private var legacyExitProbeGeneration = 0
    /// True while the async bridge attach preflight (INT-698 D4) is resolving for
    /// this pane. Blocks `createSurfaceIfNeeded` re-entry the same way
    /// `exitProbeInFlight` does: the surface stays nil during the preflight's
    /// off-main ssh round trips, so cold-start/resize layout passes re-enter — and
    /// without this guard each would mint a second status channel and kick a second
    /// preflight. The preflight actor's own single-flight is the second line of
    /// defense; this is the first.
    var bridgePreflightInFlight = false
    /// Per-attach status side-channel (lifecycle JSONL file + forgery token).
    /// Non-nil exactly when the patched amx status protocol is in use; its
    /// presence is what selects the policy-driven exit path over the legacy
    /// exit-code + `amx list` probe fallback.
    var statusChannel: AmxStatusChannel?
    /// kqueue watcher feeding `handleStatusEvents`. Stopped (and niled) on
    /// surface disposal and on a session re-point.
    var statusWatcher: AmxStatusFileWatcher?
    /// True after the host view has been evicted from `GhosttyRuntime.surfaceViews`
    /// as the stale half of an in-place command-bridge heal. Late libghostty close
    /// callbacks can still target the retained userdata for the old native surface;
    /// once evicted, the view must never route those callbacks through normal pane
    /// close/recycle logic.
    var ignoresProcessExitAfterHeal = false
    /// Runtime-owned recovery state for the current command-bridge session.
    /// Borrowed so heals that discard/recreate the view keep the bounded-respawn
    /// budget and daemon-incarnation history.
    var recoveryRecord: CommandBridgeRecoveryRecord?
    var respawnLedger: CommandBridgeRespawnLedger {
        get {
            recoveryRecord?.respawnLedger ?? CommandBridgeRespawnLedger()
        }
        set {
            if let recoveryRecord {
                recoveryRecord.respawnLedger = newValue
            } else if let sessionID {
                let record = host.runtime.commandBridgeRecoveryRecord(for: sessionID)
                record.respawnLedger = newValue
                recoveryRecord = record
            }
        }
    }
    /// Latest `session-end` reason the watcher decoded, awaiting consumption by
    /// the process-exit path. The attach client writes session-end just before
    /// it exits, so this is set before libghostty fires the process-exit
    /// callback; cleared after the exit decision consumes it.
    var latestSessionEndReason: SessionEndReason?
    /// Exit code paired with `latestSessionEndReason` from the status feed's
    /// `session-end` event. Lets the end policy tell a remote clean `exit`
    /// (ssh code 0 → close the pane) from a dropped connection (→ error).
    /// Set and cleared in lockstep with `latestSessionEndReason`.
    var latestSessionEndCode: Int?
    /// Pending budget-refill work scheduled when a fresh daemon attaches. Fires
    /// after the grace window to refill the respawn budget. This deliberately
    /// uses cancel-on-invalidate instead of capturing session/pane identity:
    /// session end, native-surface disposal, session repoint, and replacement by
    /// a newer incarnation all cancel the exact pending item before stale work
    /// can refill the shared recovery record. See
    /// `CommandBridgeRespawnLedger.refillBudget`.
    var budgetRefillWorkItem: DispatchWorkItem?
    var sessionExistsProvider: @MainActor (TerminalSessionID) async -> Bool = {
        await AmxBackend.sessionExists($0)
    }
    var announceSessionRespawnedFresh: () -> Void = {
        TerminalAccessibilityAnnouncer.announceSessionRespawnedFresh()
    }
    var announceErrorEntered: () -> Void = {
        TerminalAccessibilityAnnouncer.announceErrorEntered()
    }

    init(host: CommandBridgeEnactorHost) {
        self.host = host
    }

    private var runtime: GhosttyRuntime { host.runtime }
    private var sessionStore: SessionStore { host.sessionStore }
    private var hostSessionID: TerminalSession.ID { host.sessionID }
    private var paneID: TerminalPane.ID { host.paneID }

    // MARK: - Attach / local-shell fork

    /// Decide attach-vs-local-shell for a surface creation and, on `.bridgeAttach`,
    /// mint the status channel, arm the watcher, and record the bridge session.
    /// Returns the command string the host passes to `runtime.createSurface`
    /// (nil = plain local shell). Called from `createSurfaceIfNeeded`.
    func prepareAttach(for pane: TerminalPane, bridgeEnabled: Bool) -> String? {
        // Mint the per-attach status channel up front so the attach command
        // carries `AMX_STATUS_FILE`/`AMX_STATUS_TOKEN`. A fresh channel per
        // surface creation guarantees a respawn never reads a stale feed.
        // `makeStatusChannel` is optional: a failed secure pre-create (file
        // squat, EACCES) returns nil, in which case we attach WITHOUT a status
        // channel and the exit handler degrades to its legacy exitCode + `amx
        // list` probe (its `statusChannel == nil` path).
        let channel: AmxStatusChannel? = bridgeEnabled
            ? AmxBackend.makeStatusChannel(for: pane.terminalSessionID)
            : nil
        let remote = pane.executionPlan.remoteTarget
        let attachCommand: String? = {
            guard bridgeEnabled else { return nil }
            if let channel {
                return AmxBackend.attachCommand(for: pane.terminalSessionID, status: channel, remote: remote)
            }
            return AmxBackend.attachCommand(for: pane.terminalSessionID, remote: remote)
        }()
        let policyResult = BridgeSurfaceCommandPolicy.command(
            bridgeEnabled: bridgeEnabled,
            attachCommandAvailable: attachCommand != nil,
            executionPlan: pane.executionPlan
        )
        switch policyResult {
        case .bridgeAttach:
            // No pre-attach existence check: `amx attach` recreates a dead
            // daemon (zmx ensureSession), so an established-but-dead session
            // respawns a fresh shell silently instead of latching to blank
            // (INT-571). A live daemon reconnects with full scrollback.
            sessionID = pane.terminalSessionID
            beginStatusWatch(channel: channel)
            return attachCommand
        case .remoteUnavailable:
            // A remote-tagged group whose attach command couldn't be built —
            // bundled `amx` missing, OR the command bridge globally disabled —
            // must never fall through to a local shell: the user could type
            // secrets into what looks like the remote host but is actually
            // their own machine. Same orphaned-status-channel cleanup as
            // `.localShell` below, but surface a visible error latch instead of
            // a plain shell.
            if let channel {
                try? FileManager.default.removeItem(at: channel.fileURL)
            }
            // Latch synchronously so `createSurfaceIfNeeded`'s post-return guard
            // blocks the local-shell fallthrough (ADR-0022 trust boundary — a
            // remote-tagged pane must never spawn a typable LOCAL shell). But
            // DEFER `markError`'s @Observable store writes: `prepareAttach` runs
            // inside `createSurfaceIfNeeded`, which runs inside SwiftUI's layout
            // pass. Mutating observed state there re-enters the sidebar hosting
            // controller's `rootView` update mid-layout and trips AppKit's "more
            // Update Constraints passes than views" runaway guard — an uncaught
            // NSException that beachballs then kills the app. One runloop hop
            // lands the error chrome in a fresh, non-reentrant layout pass.
            errorLatched = true
            DispatchQueue.main.async { [weak self] in self?.markError() }
            return nil
        case .localShell:
            // Non-remote panes only (a remote group now routes to
            // `.remoteUnavailable` above whether or not the bridge is on). Two
            // sub-cases land here: (a) the bridge is disabled — already cleared
            // by the pre-guard in `createSurfaceIfNeeded`; or (b) the bridge is
            // on but no attach command could be built (bundled `amx` missing).
            // Only (b) is worth a diagnostic, which the host emits.
            // The status channel was pre-created above, but this branch never
            // arms a watcher, so its `stop()` cleanup never fires. Remove the
            // orphaned file here so the degraded sub-case doesn't leak one
            // `.status.jsonl` per surface create.
            if let channel {
                try? FileManager.default.removeItem(at: channel.fileURL)
            }
            clearStateForLocalShellFallback()
            return nil
        }
    }

    /// Break this pane's live bridge generation (INT-698 D4 teardown parity):
    /// cancel the reverse forward, `rm` the remote socket by exact ledger path,
    /// shut the listener/supervisor/coordinator, and drop the per-session
    /// preflight. Fire-and-forget (teardown is async best-effort) and idempotent
    /// (the registry no-ops an unknown session). This mirrors the genuine-close
    /// teardown the `discardSurface` hook already runs; the three callers here —
    /// local-shell fallback, session re-point, error latch — are the other
    /// lifecycle events that end a bridge generation WITHOUT going through that
    /// hook. A heal/respawn deliberately does NOT call this: the generation is
    /// transferred and D2's attach step 5 breaks the old one only after the
    /// successor publishes (the recovery-record survival contract).
    private func tearDownBridgeGeneration(for session: TerminalSessionID?) {
        guard let session else { return }
        runtime.forgetBridgeAttachPreflight(for: session)
        // Capture the live generation's identity SYNCHRONOUSLY now, then tear
        // down only that exact generation. A reconnect that re-mints a successor
        // for the same session between here and the async teardown carries a
        // different token, so this stale teardown no-ops on it instead of
        // breaking the successor's live transport.
        guard let registry = runtime.bridgeGenerationRegistry,
              let token = registry.currentToken(for: session) else {
            return
        }
        Task { await registry.teardown(for: session, ifToken: token) }
    }

    func clearStateForLocalShellFallback() {
        let recoverySessionID = recoveryRecord?.terminalSessionID
            ?? sessionID
        tearDownBridgeGeneration(for: recoverySessionID)
        // A pane falling back from a bridge session to a local shell must not
        // inherit the dead bridge session's OSC 9;4 progress — the old view's
        // expiry timer died with it, so nothing else would ever clear it
        // (INT-609). Gated on having actually been bridged: this method also
        // runs on every `createSurfaceIfNeeded` for plain local panes (before
        // the `surface == nil` guard), where clearing would stomp live
        // progress from the running shell.
        if recoverySessionID != nil {
            sessionStore.updatePane(
                sessionID: hostSessionID,
                paneID: paneID,
                progressReport: TerminalProgressReport(state: .remove)
            )
        }
        sessionID = nil
        errorLatched = false
        exitResolutionPending = false
        exitProbeInFlight = false
        // Clear the established-bridge metadata so the Path Bar's cwd poll stops
        // keying this pane as a live bridge pane: after a fallback to local
        // shell the bridge session is gone, but the poll would otherwise keep
        // querying its dead id every ~4s. A later bridge re-attach re-writes
        // `established`. `updateTerminalBackendMetadata` no-ops when already empty.
        sessionStore.updateTerminalBackendMetadata(
            sessionID: hostSessionID,
            paneID: paneID,
            metadata: .empty
        )
        // The status feed and respawn budget are bridge-only. Tearing them down
        // here covers both callers: the bridge-disabled local-shell fallback and
        // the `.markExited` clean-exit route. `stop()` is idempotent.
        statusWatcher?.stop()
        statusWatcher = nil
        statusChannel = nil
        latestSessionEndReason = nil
        latestSessionEndCode = nil
        budgetRefillWorkItem?.cancel()
        budgetRefillWorkItem = nil
        if let recoverySessionID {
            runtime.discardCommandBridgeRecoveryRecord(for: recoverySessionID)
        }
    }

    // MARK: - Ingress: process-exit callback

    /// Returns `true` when the enactor consumed the process-exit (bridge pane);
    /// `false` lets the host take its normal recycle/close path.
    func handleProcessExit(processAlive: Bool) -> Bool {
        // Recursion floor: the `.markExited` arm of `decideExitFromStatus` nils
        // `sessionID` and then re-enters `host.closeAfterProcessExit` to take the
        // normal clean-exit path. This nil check is what makes that re-entry fall
        // through instead of looping back into bridge supervision.
        guard sessionID != nil else {
            return recoverAttachedRuntimeDeathIfNeeded(processAlive: processAlive)
        }

        guard !processAlive else {
            return true
        }

        if exitProbeInFlight || exitResolutionPending {
            return true
        }

        if let exitCode = host.commandExitCache.exitCode {
            beginExitSupervision(exitCode: exitCode)
        } else {
            scheduleCloseResolution()
        }
        return true
    }

    private func recoverAttachedRuntimeDeathIfNeeded(processAlive: Bool) -> Bool {
        // The attach client can cache a normal-looking exit code while the pane
        // is still an established bridge pane. Treat the durable pane metadata as
        // authoritative here; clean shell exits clear it before re-entering the
        // normal close path.
        guard !processAlive,
              runtime.isCommandBridgeEnabled,
              let currentPane = sessionStore.session(id: hostSessionID)?.layout.pane(id: paneID),
              currentPane.terminalBackendMetadata == AmxBackend.establishedSessionMetadata else {
            return false
        }

        sessionID = currentPane.terminalSessionID
        latestSessionEndReason = .unknown
        latestSessionEndCode = nil
        errorLatched = false
        exitResolutionPending = false
        exitProbeInFlight = true
        host.commandExitCache.clear()

        if host.hasNativeSurface {
            host.disposeNativeSurface(resetHostedLayer: true)
        }

        decideExitFromStatus()
        return true
    }

    /// Consumed from `handleCommandFinished`: the shell wrapper's `stop_command`
    /// fires immediately before close and carries the exit code. Returns `true`
    /// when this is a bridge pane and supervision took over.
    func handleCommandFinished(exitCode: Int16) -> Bool {
        guard sessionID != nil else {
            return false
        }
        beginExitSupervision(exitCode: exitCode)
        return true
    }

    // MARK: - Ingress: status feed

    /// Mint and arm the status watcher for a freshly-built bridge attach.
    /// Called from the `.bridgeAttach` lifecycle path. Replaces any prior
    /// watcher (a previous attach for the same pane) so only one feed is live.
    func beginStatusWatch(channel: AmxStatusChannel?) {
        // Drop a stale watcher before handling the new channel. This matters
        // even when the new attach is the legacy/no-status path.
        statusWatcher?.stop()
        statusWatcher = nil
        statusChannel = nil

        guard let channel else {
            return
        }
        statusChannel = channel
        // `onEvents` is declared `@MainActor` by the watcher, and the watcher
        // dispatches on the main queue, so the callback already runs on the
        // main actor — no hop needed here. The `[weak self]` capture keeps the
        // watcher from extending the enactor's lifetime.
        let watcher = AmxStatusFileWatcher(channel: channel) { [weak self] events in
            self?.handleStatusEvents(events)
        }
        statusWatcher = watcher
        watcher.start()
    }

    /// Consume status events on the main actor: an `attached` records the daemon
    /// incarnation (fresh-vs-reconnect) and arms an uptime-gated budget refill; a
    /// `session-end` records the reason the process-exit path later decides on
    /// and cancels any pending refill (the incarnation didn't prove healthy).
    func handleStatusEvents(_ events: [AmxStatusEvent]) {
        // A latched-error pane must be inert to further status events. A stray
        // or late `attached` line on the status file must not silently un-error
        // the pane (clearing agent chrome + false-announcing "Session restarted")
        // while the user is looking at an error state. The latch is only cleared
        // on the legitimate recovery path (decideExitFromStatus on
        // .respawnFresh/.reconnect, or the async legacy probe) — which runs before
        // any new status events can arrive on a recycled pane.
        guard shouldProcessCommandBridgeStatusEvents(errorLatched: errorLatched) else {
            return
        }
        for event in events {
            switch event.kind {
            case let .attached(created, daemonPid, daemonCreatedAt):
                let incarnation = AmxDaemonIncarnation(pid: daemonPid, createdAt: daemonCreatedAt)
                let outcome = respawnLedger.recordAttach(incarnation)
                // `created` on a first attach means amx launched a new daemon
                // (prior one gone), so any restored `.waiting` is dead. Safe
                // versus a live reattach: `created` == brand-new session, no
                // running agent (INT-672).
                if outcome == .fresh {
                    onFreshDaemonIncarnation()
                } else if outcome == .firstAttach && created {
                    sessionStore.resetPaneAgentChromeToShell(
                        sessionID: hostSessionID,
                        paneID: paneID
                    )
                }
                // Arm an uptime-gated budget refill, but NOT on a `.reconnect`.
                // A reconnect re-attaches to the SAME live daemon and spends no
                // budget; rescheduling here would cancel a still-pending refill
                // clock armed for a prior `.fresh` incarnation (the scheduler
                // cancels the existing work item first), so that fresh daemon —
                // if it then crashes — never got its budget refilled. Only a
                // fresh (or first) attach starts a new grace window. We still do
                // NOT refill on attach alone — a crash-looping daemon attaches on
                // every respawn, so an attach-time reset would make the `.error`
                // cap unreachable. The refill fires only if this incarnation
                // survives the grace window; a `session-end` before then cancels
                // it, keeping the budget draining toward `.error`.
                if outcome != .reconnect {
                    scheduleBudgetRefill()
                }

                // Confirm a pending manual remote reconnect (INT-697). The
                // `attached` event is the same recovery signal the heal path
                // already trusts, so we key off it for all outcomes. On the
                // first attach after `beginManualReconnect` this nils the
                // overlay state and un-sticks a bridge-death `.error` — a
                // same-incarnation `.reconnect` never routes through
                // `resetPaneAgentChromeToShell`, so without this the sidebar
                // would stay `.error` forever after a successful reconnect. It
                // no-ops (returns false) for every ordinary attach, so this is
                // inert outside a reconnect.
                //
                // Read the reconnect payload BEFORE confirm clears it, so the
                // recovery announcement names the host that was actually dialed
                // rather than whatever the live group target resolves to now —
                // the group can move mid-handshake (fix #9). Skip the
                // announcement when a FRESH incarnation already announced
                // "Session restarted" this same event: one announcement per
                // event (fix #10b).
                let reconnectState = sessionStore.session(id: hostSessionID)?
                    .layout.pane(id: paneID)?.remoteReconnect
                if sessionStore.confirmPaneRemoteReconnected(
                    sessionID: hostSessionID,
                    paneID: paneID
                ), outcome != .fresh {
                    let reconnectedHost = reconnectState.flatMap {
                        $0.context.dialedLocalRestart ? nil : $0.context.target.host
                    }
                    TerminalAccessibilityAnnouncer.announceRemoteReconnected(
                        host: reconnectedHost,
                        paneDescriptor: TerminalAccessibilityAnnouncer.paneDescriptor(
                            for: paneID,
                            in: sessionStore.session(id: hostSessionID)
                        )
                    )
                }
            case let .sessionEnd(reason, code):
                // The incarnation that just ended did not clear the grace window,
                // so cancel its pending refill.
                budgetRefillWorkItem?.cancel()
                budgetRefillWorkItem = nil
                latestSessionEndReason = reason
                latestSessionEndCode = code

                // Drive the exit decision NOW from this authoritative signal,
                // rather than waiting for libghostty's process-exit callback.
                // The bridge command sets `wait_after_command`, so on the attach
                // client's exit libghostty parks the surface at "Process exited.
                // Press any key to close" and does NOT deliver a prompt
                // process-exit — so a runtime daemon-death respawn driven off
                // that callback never fires (the pane just sits there). The
                // status-channel session-end is the reliable runtime signal; act
                // on it. `beginExitSupervision` disposes the surface first, so
                // the pane is recreated before the "press any key" screen is ever
                // shown. Guarded against double-drive by the in-flight /
                // resolution flags — a later process-exit (e.g. on a keypress, or
                // once libghostty does fire it) no-ops via the same guards in
                // `handleProcessExit`. exitCode is nil because the armed watcher
                // makes the status path authoritative (it's read before the
                // exitCode branch in supervision).
                if !exitProbeInFlight,
                   !exitResolutionPending,
                   statusWatcher?.isArmed == true {
                    beginExitSupervision(exitCode: nil)
                }
            }
        }
    }

    /// Schedule the grace-gated respawn-budget refill. Replaces any prior pending
    /// refill so only the latest incarnation's window is live. On fire, refills
    /// the budget — the session has now survived long enough to count as
    /// recovered rather than mid-crash-loop.
    private func scheduleBudgetRefill() {
        budgetRefillWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.budgetRefillWorkItem = nil
                self.respawnLedger.refillBudget()
            }
        }
        budgetRefillWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.budgetRefillGrace,
            execute: workItem
        )
    }

    /// Hook fired when an `attached` event reports a daemon incarnation distinct
    /// from the last one seen — i.e. the session was respawned, not reconnected.
    ///
    /// Clears stale agent chrome on the pane so a respawned shell does not inherit
    /// the dead incarnation's agent identity (kind, execution state, attention).
    /// Called only on fresh incarnation; reconnects to a live daemon skip this so
    /// chrome for an ongoing agent run is correctly preserved.
    func onFreshDaemonIncarnation() {
        guard runtime.isCommandBridgeEnabled else {
            return
        }
        sessionStore.resetPaneAgentChromeToShell(sessionID: hostSessionID, paneID: paneID)
        announceSessionRespawnedFresh()
    }

    // MARK: - Manual reconnect

    /// User-initiated reconnect from the disconnected overlay (INT-697). Mirrors
    /// the `.respawnFresh` arm's re-attach mechanically — no new spawn path — but
    /// is driven by a click instead of a status event.
    func beginManualReconnect() {
        // Idempotence: the first click clears the latch, so a racing second
        // click no-ops here (the disabled "Reconnecting…" button is the second
        // line of defense). Also refuse while an exit probe/resolution is still
        // in flight — that path will drive its own decision. The
        // `remoteReconnect != nil` guard is load-bearing now that the palette
        // "Reconnect Remote Pane" command is a second caller: it must no-op on a
        // pane that isn't showing the disconnected overlay (INT-697 fix #6).
        guard errorLatched,
              !exitProbeInFlight,
              !exitResolutionPending,
              sessionStore.session(id: hostSessionID)?
                  .layout.pane(id: paneID)?.remoteReconnect != nil else {
            return
        }
        // An explicit user retry earns a full crash budget; otherwise a
        // budget-exhausted `.error` (the only way a remote pane latches) would
        // re-cap on the very first respawn.
        respawnLedger.refillBudget()
        errorLatched = false
        // Flip the overlay to `.reconnecting` (keeping the captured target)
        // rather than clearing it: the disposed surface may be the window's only
        // native surface, so the respawn can take the deferred cold-start path.
        // The overlay stays painted until the `attached` confirmation covers
        // that gap. No-ops unless currently `.disconnected`.
        sessionStore.markPaneRemoteReconnecting(sessionID: hostSessionID, paneID: paneID)
        // Re-drive surface creation. `errorLatched = false` above reopens
        // `createSurfaceIfNeeded`'s guard; `prepareAttach` there rebuilds the
        // attach tail from live group state (current `remoteTarget`), so a
        // session moved between hosts dials the right one.
        host.scheduleSurfaceCreationIfNeeded()
    }

    // MARK: - Exit supervision

    func beginExitSupervision(exitCode: Int16?) {
        guard let sessionID,
              !exitProbeInFlight else {
            return
        }

        exitResolutionPending = false
        exitProbeInFlight = true
        host.commandExitCache.clear()

        // Snapshot whether the status feed was armed BEFORE disposing the surface:
        // `disposeNativeSurface()` calls `statusWatcher?.stop()`, which flips
        // `isArmed` to false. Reading it after dispose (as this did) made the
        // status-driven branch permanently unreachable — every exit fell through to
        // the legacy `exitCode`/`amx list` path, so a runtime daemon-death never
        // respawned via the authoritative session-end reason. Capture first.
        let statusFeedWasArmed = statusWatcher?.isArmed == true
        if statusFeedWasArmed, latestSessionEndReason == nil {
            statusWatcher?.drainPendingEvents()
        }

        if host.hasNativeSurface {
            host.disposeNativeSurface(resetHostedLayer: true)
        }

        // Patched-protocol path: a status watcher actually ARMED, so the attach
        // client's `session-end` reason (or its absence) is authoritative.
        // Decide synchronously via the pure policy — no `amx list` probe needed.
        // Gate on the watcher having been armed, not merely on a non-nil channel:
        // if arming silently failed (missing/unvalidatable file) the feed never
        // delivers, so a non-nil-channel-only gate would mis-decide off an empty
        // feed. The legacy exitCode + `sessionExists` path below is the fallback
        // for an unpatched amx / missing status file / failed arm.
        if statusFeedWasArmed {
            decideExitFromStatus()
            return
        }

        guard exitCode == 0 else {
            exitProbeInFlight = false
            markError()
            return
        }

        let hostSessionID = hostSessionID
        let paneID = paneID
        legacyExitProbeGeneration &+= 1
        let probeGeneration = legacyExitProbeGeneration
        let sessionExistsProvider = sessionExistsProvider
        Task { @MainActor [weak self, hostSessionID, paneID, sessionID, probeGeneration, sessionExistsProvider] in
            let sessionExists = await sessionExistsProvider(sessionID)
            guard let self else {
                return
            }
            guard self.legacyExitProbeGeneration == probeGeneration else {
                return
            }
            guard self.hostSessionID == hostSessionID,
                  self.paneID == paneID,
                  self.sessionID == sessionID else {
                self.exitProbeInFlight = false
                return
            }

            self.exitProbeInFlight = false
            guard let currentPane = self.sessionStore.session(id: hostSessionID)?.layout.pane(id: paneID),
                  currentPane.terminalSessionID == sessionID else {
                return
            }

            guard self.runtime.isCommandBridgeEnabled else {
                self.clearStateForLocalShellFallback()
                self.host.scheduleSurfaceCreationIfNeeded()
                return
            }

            guard sessionExists else {
                self.markError()
                return
            }

            self.errorLatched = false
            self.host.shellCommandFinishedIdleLatched = false
            guard let recovery = self.sessionStore.healCommandBridgePaneInPlace(
                sessionID: hostSessionID,
                paneID: paneID,
                metadata: AmxBackend.establishedSessionMetadata
            ) else {
                return
            }
            self.host.pane = recovery.pane
            self.host.paneID = recovery.paneID
            self.sessionID = recovery.terminalSessionID
            self.host.remountFreshSurfaceAfterCommandBridgeHeal(recovery)
        }
    }

    /// Status-driven exit decision: map the latest `session-end` reason (or its
    /// absence) through the pure `BridgeSessionEndPolicy`, then enact the result.
    /// Synchronous — the reason is already known, no async daemon probe needed.
    private func decideExitFromStatus() {
        let reason = latestSessionEndReason
        let exitCode = latestSessionEndCode
        let isRemote = host.pane.executionPlan.remoteTarget != nil
        let command = BridgeSessionEndPolicy.decide(
            reason: reason,
            bridgeEnabled: runtime.isCommandBridgeEnabled,
            isRemote: isRemote,
            exitCode: exitCode,
            respawnAttempts: respawnLedger.respawnAttempts,
            maxAttempts: Self.maxRespawnAttempts
        )

        // Consume the reason regardless of outcome so a later spurious exit on
        // the same pane can't re-decide off this same stale signal.
        latestSessionEndReason = nil
        latestSessionEndCode = nil

        switch command {
        case .respawnFresh, .reconnect:
            // Both mechanically re-attach: `amx attach` recreates a dead daemon
            // (respawnFresh) or reconnects a live one (reconnect). The only
            // difference is chrome handling on the next `attached` event, which
            // the incarnation hook owns.
            //
            // Only `.respawnFresh` spends a budget unit: it is crash recovery,
            // and the bounded-respawn cap exists to stop a crash loop. A
            // `.reconnect` is a user-initiated detach coming back to a live
            // daemon — a normal lifecycle event, NOT a failure — so metering it
            // against the crash budget would latch `.error` on a healthy session
            // for a detach-happy user. The fail-safe nil→respawnFresh case (the
            // attach client was killed before writing session-end, or the app
            // quit) lands here too — INT-571 validated that a silent
            // non-destructive respawn beats latching a blank/error pane.
            if command == .respawnFresh {
                respawnLedger.recordRespawnAttempt()
            }
            // Clear the in-flight flag before re-arming: `createSurfaceIfNeeded`
            // guards on `!exitProbeInFlight`, so it must read false for the
            // re-attach to proceed.
            exitProbeInFlight = false
            errorLatched = false
            host.shellCommandFinishedIdleLatched = false
            // A dead daemon's OSC 9;4 progress is definitely stale, and the
            // remounted view would paint it until the fresh incarnation's
            // `attached` event drains through `onFreshDaemonIncarnation`
            // (which owns the reset for ambiguous respawns — a nil/unknown
            // reason may be a same-daemon reconnect whose progress is live).
            // Clear it BEFORE remount so the new surface's first frame is
            // clean (INT-609).
            if reason == .daemonDied {
                sessionStore.updatePane(
                    sessionID: hostSessionID,
                    paneID: paneID,
                    progressReport: TerminalProgressReport(state: .remove)
                )
            }
            guard let recovery = sessionStore.healCommandBridgePaneInPlace(
                sessionID: hostSessionID,
                paneID: paneID,
                metadata: AmxBackend.establishedSessionMetadata
            ) else {
                return
            }
            host.pane = recovery.pane
            host.paneID = recovery.paneID
            sessionID = recovery.terminalSessionID
            host.remountFreshSurfaceAfterCommandBridgeHeal(recovery)

        case .markExited:
            // A clean shell exit (or bridge disabled): the session is genuinely
            // over, so route through the SAME path a normal non-bridge clean
            // process exit takes — let the pane close/recycle. Clearing the
            // bridge state first (which nils `sessionID` and the in-flight flag)
            // makes the re-entrant `host.closeAfterProcessExit` call see
            // `handleProcessExit` return false at its `sessionID != nil` guard,
            // so it falls through to the standard recycle/close branch instead of
            // re-entering supervision. This ordering — clear BEFORE close — is the
            // recursion floor; it must not be reordered. See the guard in
            // `handleProcessExit`.
            clearStateForLocalShellFallback()
            host.closeAfterProcessExit(processAlive: false)

        case .error:
            // Respawn budget exhausted — stop trying and surface the failure.
            // `markError` clears the in-flight flag itself.
            markError()
        }
    }

    func scheduleCloseResolution() {
        let hostSessionID = hostSessionID
        let paneID = paneID
        exitResolutionPending = true
        Task { @MainActor [weak self, hostSessionID, paneID] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else {
                return
            }
            guard self.hostSessionID == hostSessionID,
                  self.paneID == paneID else {
                self.exitResolutionPending = false
                return
            }
            guard self.exitResolutionPending else {
                return
            }
            guard self.sessionID != nil else {
                self.exitResolutionPending = false
                return
            }

            self.beginExitSupervision(exitCode: self.host.commandExitCache.exitCode)
        }
    }

    // MARK: - Host teardown hooks

    /// The host is disposing its native surface. Stop the status watcher and
    /// cancel the pending budget refill — a disposed surface has, by definition,
    /// not yet proven uptime. Deliberately does NOT clear `statusChannel`,
    /// `latestSessionEndReason`, or the recovery record: exit supervision disposes
    /// the surface as the FRONT HALF of a respawn and then reads the channel +
    /// reason to make the policy decision.
    func notifyNativeSurfaceDisposed() {
        statusWatcher?.stop()
        budgetRefillWorkItem?.cancel()
        budgetRefillWorkItem = nil
    }

    /// The host is re-pointing at a different terminal session. Re-pointing
    /// invalidates the old status feed and respawn budget: stop the watcher and
    /// drop the channel, reason, and recovery record so a stale session-end can't
    /// drive the new session's exit decision.
    func handleSessionRepoint() {
        let oldRecoverySessionID = recoveryRecord?.terminalSessionID
            ?? sessionID
        legacyExitProbeGeneration &+= 1
        tearDownBridgeGeneration(for: oldRecoverySessionID)
        sessionID = nil
        errorLatched = false
        exitResolutionPending = false
        exitProbeInFlight = false
        statusWatcher?.stop()
        statusWatcher = nil
        statusChannel = nil
        latestSessionEndReason = nil
        latestSessionEndCode = nil
        budgetRefillWorkItem?.cancel()
        budgetRefillWorkItem = nil
        if let oldRecoverySessionID {
            runtime.discardCommandBridgeRecoveryRecord(for: oldRecoverySessionID)
        }
    }

    func markError() {
        exitResolutionPending = false
        exitProbeInFlight = false
        errorLatched = true
        // A latched pane's bridge generation is dead — break it (teardown parity
        // with the local-shell-fallback and re-point paths, same session-id
        // fallback: the recovery record can outlive a nil'd `sessionID` in a
        // heal window). Idempotent; no-ops for a never-bridged pane.
        tearDownBridgeGeneration(for: recoveryRecord?.terminalSessionID ?? sessionID)
        // Clear the established-bridge metadata so the Path Bar's cwd poll stops
        // keying this pane as a live bridge pane — otherwise it keeps polling a
        // dead session id every ~4s forever after the error latch. A later
        // retry/recycle re-attach re-writes `established`, so the poll correctly
        // waits for re-confirmation. `updateTerminalBackendMetadata` no-ops when
        // already empty.
        sessionStore.updateTerminalBackendMetadata(
            sessionID: hostSessionID,
            paneID: paneID,
            metadata: .empty
        )
        sessionStore.recordPaneProcessError(
            in: hostSessionID,
            paneID: paneID,
            terminalIsFocused: host.terminalIsFocused
        )
        // A remote latch sets `remoteReconnect`, and the disconnected overlay
        // fires its own "Disconnected from <host>. Reconnect available."
        // announcement — the single voice for that transition. Suppress the
        // generic "Session error." here so VoiceOver doesn't speak both
        // (INT-697 fix #10a).
        let latchedRemoteReconnect = sessionStore.session(id: hostSessionID)?
            .layout.pane(id: paneID)?.remoteReconnect != nil
        if !latchedRemoteReconnect {
            announceErrorEntered()
        }
    }
}
