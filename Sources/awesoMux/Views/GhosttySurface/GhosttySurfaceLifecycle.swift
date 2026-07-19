import AppKit
import AwesoMuxCore
import GhosttyKit

extension GhosttySurfaceNSView {
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scale
            CATransaction.commit()
        }

        sizeDidChange(contentSize)
        if surface == nil {
            scheduleSurfaceCreationIfNeeded()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Window drag finished: re-derive from the settled geometry and apply.
        // We force the immediate path rather than trusting `inLiveResize` to
        // already read false inside this callback — that keeps the settled size
        // authoritative even if AppKit/SwiftUI reports the view as still live
        // here. Re-deriving from `contentSize` (rather than replaying a captured
        // state) makes the final size correct regardless of how the last
        // in-drag layout pass landed.
        updateSurfaceSize(contentSize, creatingIfNeeded: false, forceImmediateApply: true)
    }

    func updateMouseOverLink(_ link: String?) {
        guard mouseOverLink != link else {
            return
        }

        mouseOverLink = link
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        updateLinkPeek(for: link)
    }

    /// Handles `GHOSTTY_ACTION_MOUSE_SHAPE`. Ghostty's own app stores this
    /// in a `@Published` `pointerStyle` consumed by its NSScrollView wrapper's
    /// `documentCursor` (`SurfaceScrollView.swift:146`) — awesoMux has no such
    /// wrapper (and the plan's Global Constraints say not to add one), so this
    /// feeds the existing `resetCursorRects()`/`addCursorRect` mechanism that
    /// `updateMouseOverLink` above already uses.
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        guard let style = GhosttyCursorMapper.style(for: shape) else {
            // Unknown/unmapped shape: leave the current cursor unchanged,
            // matching Ghostty's own `default: return` (SurfaceView_AppKit.swift:528-530).
            return
        }

        terminalCursorShape = style.nsCursor
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    /// Handles `GHOSTTY_ACTION_MOUSE_VISIBILITY`. Direct port of Ghostty's
    /// `setCursorVisibility` (`SurfaceView_AppKit.swift:533-539`) — mouse-hide-
    /// while-typing is the only caller today, so `NSCursor.setHiddenUntilMouseMoves`
    /// is the right primitive rather than manual show/hide bookkeeping.
    func setCursorVisibility(_ visible: Bool) {
        terminalCursorVisible = visible
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    func applyTerminalColorScheme(_ colorScheme: ghostty_color_scheme_e) {
        // libghostty's surface mutation APIs must be invoked on the main
        // thread. `NSView` inherits `@MainActor` from AppKit, so this method
        // is MainActor-isolated by default — do not relax to `nonisolated`
        // without routing through `MainActor.run`.
        guard let surface else {
            return
        }

        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-color-scheme-apply \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                scheme=\(Self.terminalColorSchemeName(colorScheme), privacy: .public)
                """
            )
        }
        ghostty_surface_set_color_scheme(surface, colorScheme)
    }

    func updateCellSize(backingWidth: Double, backingHeight: Double) {
        let backingSize = NSSize(width: backingWidth, height: backingHeight)
        cellSize = convertFromBacking(backingSize)
        scrollContainer?.surfaceMetricsDidChange()

        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-cell-size \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                backing_px=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(backingSize), privacy: .public) \
                points=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(self.cellSize), privacy: .public)
                """
            )
        }
    }

    func updateScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
        scrollbar = SurfaceScrollbar(total: total, offset: offset, length: length)
        scrollContainer?.surfaceMetricsDidChange()

        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-scrollbar \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                total=\(total, privacy: .public) \
                offset=\(offset, privacy: .public) \
                length=\(length, privacy: .public)
                """
            )
        }
    }

    static func terminalColorSchemeName(_ colorScheme: ghostty_color_scheme_e) -> String {
        // Imported C enums can't use `@unknown default` (the type isn't
        // `@frozen` in the Swift sense), so a regular `default` branch is
        // the right guard against libghostty growing a third value.
        switch colorScheme {
        case GHOSTTY_COLOR_SCHEME_LIGHT: return "light"
        case GHOSTTY_COLOR_SCHEME_DARK: return "dark"
        default: return "unknown"
        }
    }

    func createSurfaceIfNeeded() {
        let commandBridgeEnabled = runtime.isCommandBridgeEnabled
        // Don't clear when an error is already latched: for a remote pane with the
        // bridge disabled, `prepareAttach` latches `.remoteUnavailable` and defers
        // `markError()` one runloop hop. `surface` stays nil, so later layout
        // passes (cold-start settle, resize) re-enter here; an unconditional clear
        // would reset `errorLatched`, re-run prepareAttach, and schedule a second
        // markError() — a duplicate "Session error" VoiceOver announcement.
        if !commandBridgeEnabled, !commandBridgeEnactor.errorLatched {
            clearCommandBridgeStateForLocalShellFallback()
        }

        guard surface == nil,
              runtime.isReady,
              !commandBridgeEnactor.exitResolutionPending,
              !commandBridgeEnactor.exitProbeInFlight,
              !commandBridgeEnactor.bridgePreflightInFlight,
              !commandBridgeEnactor.errorLatched else {
            return
        }

        pendingSurfaceCreationWorkItem?.cancel()
        pendingSurfaceCreationWorkItem = nil
        coldStartCreationState = ColdStartSurfaceCreationState()
        windowFrameSettleState = WindowFrameSettleState()
        logSurfaceGeometryDiagnostics(event: "surface-create-before")
        // The enactor decides attach-vs-local-shell, mints/arms the status
        // channel on attach, and clears bridge state on fallback. A nil command
        // with the bridge enabled means the bundled `amx` was missing — the one
        // fallback sub-case worth a diagnostic (bridge-disabled fallback is
        // expected and silent).
        let bridgeCommand = commandBridgeEnactor.prepareAttach(
            for: pane,
            bridgeEnabled: commandBridgeEnabled
        )
        if commandBridgeEnabled, bridgeCommand == nil {
            logSurfaceGeometryDiagnostics(event: "surface-create-bridge-command-missing")
        }
        if commandBridgeEnactor.errorLatched {
            // The entry guard above already required `errorLatched == false` to
            // reach `prepareAttach`, so a true value here can only have come
            // from THIS call — `.remoteUnavailable` (ADR-0022 trust boundary):
            // a remote-tagged pane whose attach command couldn't be built. Must
            // not fall through to `createSurface(command: nil)`, which would
            // spawn a silent, typable LOCAL shell masquerading as the remote
            // host. Leave the pane blank + latched; the top-of-function guard
            // blocks re-creation until the latch clears.
            logSurfaceGeometryDiagnostics(event: "surface-create-remote-unavailable-latched")
            return
        }

        // INT-698 D4: a remote pane with agent chrome on takes the async
        // make-before-break bridge preflight instead of the synchronous spawn.
        // Every other pane (local, or bridge chrome off) is byte-identical to
        // today — the sync `finishSurfaceCreation` below is the untouched path.
        let isRemote = pane.executionPlan.remoteTarget != nil
        if BridgeAttachDecision.shouldRunPreflight(
            bridgeEnabled: commandBridgeEnabled,
            isRemote: isRemote,
            agentChromeEnabled: runtime.isBridgeChromeEnabled,
            attachCommandAvailable: bridgeCommand != nil,
            errorLatched: commandBridgeEnactor.errorLatched
        ), let baseCommand = bridgeCommand {
            beginBridgePreflight(baseCommand: baseCommand)
            return
        }

        finishSurfaceCreation(command: bridgeCommand)
    }

    /// The synchronous spawn + post-create bookkeeping, shared by the local /
    /// bridge-off path (called inline from `createSurfaceIfNeeded`) and the async
    /// bridge preflight's ready/degraded completion. `command` is the exact
    /// attach string: the D1 env-prefixed remote command on a live bridge, the
    /// bare attach command on a degraded/no-bridge attach, or nil for a plain
    /// local shell.
    func finishSurfaceCreation(command: String?) {
        terminalPromptObserved = false
        var environment = runtime.agentRuntimeEnvironment(
            sessionID: sessionID,
            paneID: paneID,
            enabledFileDropSources: enabledAgentRuntimeFileDropSources,
            applyEvent: { [weak self] event in
                self?.applyAgentRuntimeEvent(event)
            }
        ).environment
        environment = CompactTerminalKind.applyingSpawnMarkers(
            to: environment,
            kind: sessionStore.compactTerminalKind
        )
        let createdSurface = runtime.createSurface(
            attachedTo: self,
            workingDirectory: pane.workingDirectory,
            environment: environment,
            command: command
        )
        if let createdSurface {
            commandBridgeEnactor.errorLatched = false
            nativeSurfaceWasDisposed = false
            nextMouseSurfaceIncarnationID += 1
            mouseSurfaceIncarnationID = nextMouseSurfaceIncarnationID
            surface = createdSurface
            // A VoiceOver accessor firing mid-heal (surface == nil) could have
            // cached an empty read from the OLD surface; don't let it leak
            // into this new surface's first 500ms of life.
            terminalAccessibilityScreenContentsCache.invalidate()
            updateSurfaceDisplayID()
            // Only start the poll if the window is actually visible; a surface
            // created while occluded would otherwise spin to no-op until the
            // first visibility edge. The occlusion/attach handlers start it when
            // the window appears.
            if windowIsVisible {
                startVisibleStateSampling()
            }
            if command != nil {
                // Write-only breadcrumb for now: INT-571 removed the preflight
                // that read this (`hasEstablishedSessionMetadata`), so nothing in
                // the bridge path consumes `established` today. Retained — not
                // removed — because the deferred create-vs-reattach signal (the
                // zmx session-end-reason follow-up) will read it to tell a fresh
                // respawn from a live reconnect. Don't build on its value until
                // that lands; don't delete it before then.
                sessionStore.updateTerminalBackendMetadata(
                    sessionID: sessionID,
                    paneID: paneID,
                    metadata: AmxBackend.establishedSessionMetadata
                )
            } else {
                // Fresh local shell, no bridge reattach: any restored `.waiting`
                // is dead and nothing else clears it (non-bridged panes have no
                // attach hook). No-ops for a genuinely fresh pane (INT-672).
                sessionStore.resetPaneAgentChromeToShell(sessionID: sessionID, paneID: paneID)
            }
        }
        logSurfaceGeometryDiagnostics(event: "surface-create-after")
        runtime.refreshShellActivity(in: sessionStore)
        sizeDidChange(contentSize)
        needsDisplay = true
    }

    /// Kicks the async bridge attach preflight (INT-698 D4 item A). Sets the
    /// in-flight latch (blocks `createSurfaceIfNeeded` re-entry while the surface
    /// stays nil across the ssh round trips), resolves the remote `$HOME` once per
    /// attach over the exec channel (item 2), then runs the make-before-break
    /// preflight and hands the outcome to `finishBridgePreflight`. The whole flow
    /// is one MainActor task whose `await`s yield rather than pin the main thread
    /// (the ssh work runs off-main inside `BridgeExecChannel`), mirroring
    /// `beginExitSupervision`'s `Task { @MainActor … await AmxBackend.sessionExists }`.
    private func beginBridgePreflight(baseCommand: String) {
        guard let remote = pane.executionPlan.remoteTarget else {
            // Lost the remote target between the gate and here — fail open.
            finishSurfaceCreation(command: baseCommand)
            return
        }
        commandBridgeEnactor.bridgePreflightInFlight = true
        let controlPath = AmxBackend.sshControlPath()
        let terminalSessionID = pane.terminalSessionID
        let preflight = runtime.bridgeAttachPreflight(
            for: terminalSessionID,
            paneID: paneID,
            workspaceSessionID: sessionID,
            sessionStore: sessionStore
        )
        logSurfaceGeometryDiagnostics(event: "surface-create-bridge-preflight-begin")
        Task { @MainActor [weak self] in
            let home = await Self.cachedRemoteHome(controlPath: controlPath, remote: remote)
            guard let self else { return }
            guard let home else {
                // $HOME capture failed → no usable state path → fail open to a
                // no-bridge attach with the base command.
                self.finishBridgePreflight(outcome: nil, baseCommand: baseCommand, controlPath: controlPath, remote: remote, expectedTerminalSessionID: terminalSessionID)
                return
            }
            let helperPath = BridgeAttachDecision.helperPath(remoteHome: home)
            guard await Self.remoteHelperSupportsBridge(
                controlPath: controlPath,
                remote: remote,
                helperPath: helperPath
            ) else {
                // Missing/incompatible helper identifies the unmanaged or
                // unprepared-target path. Keep the terminal usable, but perform
                // no forward, directory creation, or state-file publication.
                self.finishBridgePreflight(outcome: nil, baseCommand: baseCommand, controlPath: controlPath, remote: remote, expectedTerminalSessionID: terminalSessionID)
                return
            }
            let request = BridgeAttachPreflight.Request(
                session: terminalSessionID,
                remote: remote,
                controlPath: controlPath,
                remoteHome: home,
                helperPath: helperPath,
                commandBuilder: { [status = self.commandBridgeEnactor.statusChannel] channel in
                    AmxBackend.bridgeAttachCommand(
                        for: terminalSessionID,
                        status: status,
                        remote: remote,
                        stateFilePath: channel.stateFilePath,
                        helperPath: helperPath
                    )
                }
            )
            let outcome = await preflight.attach(request)
            self.finishBridgePreflight(outcome: outcome, baseCommand: baseCommand, controlPath: controlPath, remote: remote, expectedTerminalSessionID: terminalSessionID)
        }
    }

    /// Per-host single-flight cache of the resolved remote `$HOME`, keyed by ssh
    /// destination (`user@host`). Stores the in-flight *resolution task*, not just
    /// the final string, so two panes attaching to the same host at once share
    /// one ssh round trip instead of racing two (the spec's "resolve exactly once
    /// per host and reuse", see `bridgeHomeResolutionCommand`). A user's home on a
    /// given host is process-stable, so a succeeded task is kept for the process
    /// lifetime; keying by `sshDestination` matches that documented "per host"
    /// contract and deliberately does not try to detect a mid-session ssh-config
    /// alias re-point (out of scope for a process cache).
    @MainActor private static var remoteHomeTasks: [String: Task<String?, Never>] = [:]

    /// Returns the remote `$HOME`, awaiting the in-flight per-host resolution when
    /// one exists and otherwise starting exactly one. Cache read/write stays on
    /// the main actor; only the first miss pays the ssh round trip. A failed
    /// resolution is not cached — the creating call clears its own slot so the
    /// next attach retries.
    @MainActor static func cachedRemoteHome(controlPath: String, remote: RemoteTarget) async -> String? {
        let key = remote.sshDestination
        if let inFlight = remoteHomeTasks[key] {
            return await inFlight.value
        }
        let task = Task { await resolveRemoteHome(controlPath: controlPath, remote: remote) }
        remoteHomeTasks[key] = task
        let home = await task.value
        if home == nil {
            // Only the creating call reaches here for a failed slot: the failed
            // task stays in the dict until now, so any concurrent caller awaited
            // it (hit the in-flight branch) rather than starting a new one. Under
            // MainActor serialization that makes this removal race-free — it can
            // never clobber a newer successful task, because none could have been
            // created while this one still occupied the slot.
            remoteHomeTasks[key] = nil
        }
        return home
    }

    /// Resolves the remote `$HOME` over the shared ControlMaster (spec: the
    /// one-time `$HOME` capture; also `mkdir -p ~/.awesomux/bridge`). `nonisolated`
    /// so the ssh work runs off the main actor. Returns nil on any failure — an
    /// unusable home fails the attach open to no-bridge, never wrong.
    nonisolated static func resolveRemoteHome(controlPath: String, remote: RemoteTarget) async -> String? {
        let command = AmxBackend.bridgeHomeResolutionCommand(controlPath: controlPath, remote: remote)
        guard let data = try? await BridgeExecChannel.run(command: command, stdin: nil) else {
            return nil
        }
        let home = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"), !home.contains("\0") else { return nil }
        return home
    }

    /// Read-only managed-target gate. A compatible installed helper is the
    /// capability marker until richer target profiles land; absent or garbage
    /// output fails open to a normal remote terminal with rich chrome disabled.
    nonisolated static func remoteHelperSupportsBridge(
        controlPath: String,
        remote: RemoteTarget,
        helperPath: String
    ) async -> Bool {
        let command = AmxBackend.bridgeHelperVersionCommand(
            controlPath: controlPath,
            remote: remote,
            helperPath: helperPath
        )
        guard let data = try? await BridgeExecChannel.run(command: command, stdin: nil) else {
            return false
        }
        return !BridgeDoctorSignals.compatibleProtocols(
            helperVersionOutput: String(decoding: data, as: UTF8.self),
            appSupported: Set(BridgeConnectionSupervisor.supportedProtocols)
        ).isEmpty
    }

    /// The async preflight's MainActor completion. Clears the in-flight latch,
    /// re-checks the creation guards (state can move during the ssh round trips),
    /// promotes a `ready` generation, then spawns via `finishSurfaceCreation`.
    /// `outcome == nil` is the pre-preflight `$HOME`-capture failure (fail open).
    private func finishBridgePreflight(
        outcome: BridgeAttachPreflight.Outcome?,
        baseCommand: String,
        controlPath: String,
        remote: RemoteTarget,
        expectedTerminalSessionID: TerminalSessionID
    ) {
        // Keep `bridgePreflightInFlight` true until this method returns so a
        // published live-coordinator Observation cannot re-enter
        // `createSurfaceIfNeeded` while `surface` is still nil (review R-4).
        defer { commandBridgeEnactor.bridgePreflightInFlight = false }

        // The view may have been re-pointed to a DIFFERENT terminal session while
        // the preflight ran (`update` → `handleSessionRepoint`) — a result minted
        // for the old session must never spawn its stale attach command into the
        // repointed pane, nor register under the new key. The pane may also have
        // genuinely CLOSED: the Task's strong `self` keeps a discarded view alive
        // through the ssh round trips, so `surface == nil` alone reads creatable —
        // the runtime-cache identity check is what tells "waiting to spawn" from
        // "already evicted". Plus the ordinary entry guards.
        let stale = pane.terminalSessionID != expectedTerminalSessionID
        let canCreate = surface == nil
            && runtime.isReady
            && runtime.cachedSurfaceView(for: paneID) === self
            && !commandBridgeEnactor.exitResolutionPending
            && !commandBridgeEnactor.exitProbeInFlight
            && !commandBridgeEnactor.errorLatched

        guard !stale, canCreate else {
            if case .ready(let channel, _)? = outcome {
                // A COMMITTED generation (forward up, state file published, trio
                // staged) whose pane is gone must be torn down through the
                // registry, never just dropped — register-then-teardown reuses
                // the exact-path cancel/rm/shutdown, and `ifToken` protects a
                // successor that raced in (review finding: the orphaned-forward
                // window between readiness commit and registration).
                runtime.discardCommittedBridgeGeneration(
                    session: expectedTerminalSessionID,
                    channel: channel,
                    controlPath: controlPath,
                    remote: remote
                )
            }
            logSurfaceGeometryDiagnostics(event: "surface-create-bridge-preflight-stale")
            return
        }

        if case .ready(let channel, _)? = outcome {
            runtime.promoteBridgeGeneration(
                session: expectedTerminalSessionID,
                channel: channel,
                controlPath: controlPath,
                remote: remote
            )
        }

        guard let outcome else {
            logSurfaceGeometryDiagnostics(event: "surface-create-bridge-preflight-failed")
            finishSurfaceCreation(command: baseCommand)
            return
        }
        guard let command = BridgeAttachDecision.finalCommand(for: outcome, baseCommand: baseCommand) else {
            // .cancelled — a superseding attach owns the pane; spawn nothing.
            logSurfaceGeometryDiagnostics(event: "surface-create-bridge-preflight-cancelled")
            return
        }
        // Distinct breadcrumbs per outcome: a degraded attach also proceeds to
        // spawn (fail-open), and logging it as "-ready" cost a live-smoke
        // debugging session a half hour chasing a phantom post-publish
        // teardown. Name the degraded reason so the log alone answers "did the
        // bridge come up, and if not, which step said no."
        if case .degraded(let reason) = outcome {
            logSurfaceGeometryDiagnostics(
                event: "surface-create-bridge-preflight-degraded-\(reason)"
            )
        } else {
            logSurfaceGeometryDiagnostics(event: "surface-create-bridge-preflight-ready")
        }
        finishSurfaceCreation(command: command)
    }

    func clearCommandBridgeStateForLocalShellFallback() {
        commandBridgeEnactor.clearStateForLocalShellFallback()
    }

    func mountedSizeDidChange(_ size: CGSize) {
        updateSurfaceSize(size, creatingIfNeeded: true)
    }

    func sizeDidChange(_ size: CGSize) {
        updateSurfaceSize(size, creatingIfNeeded: false)
    }

    func updateSurfaceSize(
        _ size: CGSize,
        creatingIfNeeded: Bool,
        forceImmediateApply: Bool = false
    ) {
        contentSize = size

        if creatingIfNeeded {
            scheduleSurfaceCreationIfNeeded()
        }

        guard surface != nil,
              size.width > 0,
              size.height > 0 else {
            return
        }

        let backingSize = backingSize(for: size)
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        // `CGFloat.ulpOfOne` (~2.22e-16) is too tight — during display
        // reconfiguration (screen disconnect, main-display switch) the
        // per-axis backing scales can transiently disagree by more than that
        // even though they're conceptually the same value. `1e-6` keeps the
        // intent (catch a genuinely anisotropic backing) without DEBUG
        // crashes on normal screen-switching workflows.
        assert(abs(xScale - yScale) < 1e-6)
        let geometry = SurfaceBackingGeometry(
            pointSize: size,
            backingScale: xScale
        )
        let state = SurfaceBackingState(
            geometry: geometry,
            isVisible: windowIsVisible
        )

        switch SurfaceResizeUpdatePolicy.decision(
            lastApplied: lastAppliedSurfaceBackingState,
            next: state,
            isInLiveResize: forceImmediateApply ? false : inLiveResize
        ) {
        case .applyImmediately:
            applySurfaceBackingState(state)

        case .deferUntilSettled:
            // Coalesced: a window live-resize is in progress. We suppress the
            // per-frame push and let `viewDidEndLiveResize` re-derive and apply
            // the settled size once the drag finishes. `contentSize` (set above)
            // keeps tracking the latest proposed size, so the flush is current.
            break

        case .skip:
            break
        }
    }

    func applySurfaceBackingState(_ state: SurfaceBackingState) {
        guard lastAppliedSurfaceBackingState != state,
              let surface else {
            return
        }

        logSurfaceGeometryDiagnostics(
            event: "surface-set-size",
            geometry: state.geometry,
            visible: state.isVisible
        )

        ghostty_surface_set_content_scale(
            surface,
            state.geometry.scale,
            state.geometry.scale
        )
        ghostty_surface_set_size(surface, state.geometry.width, state.geometry.height)
        logNativeSurfaceSizeDiagnostics(event: "surface-native-size-after-set")
        pushSurfaceOcclusion(surface, isVisible: state.isVisible, source: "backing-state-apply")
        lastAppliedSurfaceBackingState = state
        invalidateSurfaceAfterResize()
    }

    /// Called by the scroll container whenever this view is adopted by a
    /// container it wasn't already parented under. A remount can cross
    /// containers within the same window (split collapse, pane swap), in which
    /// case `viewDidMoveToWindow` never fires — and libghostty self-drives
    /// rendering (the synchronous `draw(_:)` fallback is gone since #285), so a
    /// surface whose last pushed state is stale has nothing else to correct it.
    /// Invalidating the applied state forces the next size update onto the
    /// `applyImmediately` path, which re-pushes scale, size, and occlusion and
    /// refreshes the display. That update is `mount()`'s own trailing
    /// `synchronizeLayout()`, which runs right after this and carries the
    /// adopting container's settled geometry — an eager push here would fire
    /// at the PREVIOUS container's stale `contentSize` and reflow the PTY
    /// twice per adoption (review finding).
    func surfaceWasRemounted() {
        lastAppliedSurfaceBackingState = nil
        updateSurfaceDisplayID()
        if surface != nil, windowIsVisible {
            startVisibleStateSampling()
        }
    }

    /// Single funnel for `ghostty_surface_set_occlusion` so every visibility
    /// push is observable. Occlusion is what pauses/resumes libghostty's
    /// self-driven renderer; a surface that never sees a `visible=true` push
    /// after a remount stays paused and renders blank (INT-600).
    func pushSurfaceOcclusion(
        _ surface: ghostty_surface_t,
        isVisible: Bool,
        source: String
    ) {
        ghostty_surface_set_occlusion(surface, isVisible)
        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-occlusion-push \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                visible=\(isVisible, privacy: .public) \
                source=\(source, privacy: .public)
                """
            )
        }
    }

    func scheduleSurfaceCreationIfNeeded() {
        guard surface == nil,
              runtime.isReady,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return
        }

        guard windowIsVisible else {
            coldStartCreationState = ColdStartSurfaceCreationState()
            windowFrameSettleState = WindowFrameSettleState()
            logSurfaceGeometryDiagnostics(event: "surface-create-hidden-deferred")
            return
        }

        // A genuinely warm pane (a surface already exists, this pane never
        // entered the cold-start wait, AND its width is already at/above the
        // floor) is laid out into the already-settled window, so its first
        // proposal is the real width — spawn immediately. Everything else (a
        // cold-start pane, or a late-mounting sibling still below the floor)
        // falls through to the settle path. `createSurfaceIfNeeded` cancels any
        // pending work.
        let paneEnteredColdStartWait = coldStartCreationState.anchorAt != nil
        if ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: isColdStartSurfacePhase,
            paneEnteredColdStartWait: paneEnteredColdStartWait,
            width: contentSize.width
        ) {
            createSurfaceIfNeeded()
            return
        }

        // Cold start: SwiftUI/AppKit can step the window through intermediate
        // frames while scene placement, screen constraints, and split layout
        // settle. Spawning mid-ramp bakes a too-narrow PTY that one-shot
        // `.zshrc` tools (fastfetch) never reflow (INT-548). Hold until the
        // window frame stops moving, THEN run the width settle. `windowIsVisible`
        // above already implies a non-nil window; the guard is defensive so a
        // surprise nil window re-checks rather than silently skipping the frame
        // settle and falling back to the pre-fix width-only path.
        guard let window else {
            scheduleColdStartRecheck(event: "surface-create-awaiting-window")
            return
        }
        switch WindowFrameSettlePolicy.decision(
            state: &windowFrameSettleState,
            windowFrame: window.frame,
            now: ContinuousClock.now
        ) {
        case .proceed:
            break
        case .wait:
            scheduleColdStartRecheck(event: "surface-create-window-frame-settling")
            return
        }

        switch ColdStartSurfaceCreationPolicy.decision(
            state: &coldStartCreationState,
            width: contentSize.width,
            now: ContinuousClock.now
        ) {
        case .create:
            createSurfaceIfNeeded()

        case .wait:
            // Re-check on a backstop timer: width changes re-drive scheduling via
            // the layout path, but a width that goes quiet still needs one poll to
            // confirm it held long enough to count as settled.
            scheduleColdStartRecheck(event: "surface-create-cold-start-deferred")
        }
    }

    /// Schedule one backstop re-check of surface creation. Shared by the
    /// window-frame settle and the cold-start width settle — both clear on
    /// timing the layout path doesn't always re-surface on its own.
    private func scheduleColdStartRecheck(event: String) {
        pendingSurfaceCreationWorkItem?.cancel()
        // `asyncAfter(deadline:)` to `.main` guarantees main-thread execution,
        // but the closure is not statically MainActor-isolated — assert it so
        // the contract survives a future `nonisolated`/refactor, matching the
        // `deinit` and notification-block convention in this file pair.
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.pendingSurfaceCreationWorkItem = nil
                self.scheduleSurfaceCreationIfNeeded()
            }
        }
        pendingSurfaceCreationWorkItem = workItem
        logSurfaceGeometryDiagnostics(event: event)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.coldStartCreationPollInterval,
            execute: workItem
        )
    }

    func backingSize(for size: CGSize) -> NSSize {
        if window != nil {
            return convertToBacking(NSRect(origin: .zero, size: size)).size
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    func applyTerminalBackstopBackgroundColor() {
        layer?.backgroundColor = TerminalBackstopBackground
            .color(for: runtime.resolvedTerminalBackgroundHex())?
            .cgColor
    }

    func resetLayerAfterNativeSurfaceTeardown() {
        let replacementLayer = CALayer()
        replacementLayer.contentsScale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? layer?.contentsScale
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        replacementLayer.needsDisplayOnBoundsChange = true
        replacementLayer.frame = bounds

        // Ghostty's macOS Metal renderer re-hosts by assigning `view.layer`
        // before `wantsLayer` (vendor/ghostty/src/renderer/Metal.zig); the iOS
        // path adds a sublayer instead. This reset relies on that macOS
        // invariant being preserved upstream.
        layer = replacementLayer
        wantsLayer = true
        applyTerminalBackstopBackgroundColor()
        setNeedsDisplay(bounds)
    }

    func logNativeSurfaceSizeDiagnostics(event: String) {
        guard Self.terminalDiagnosticsEnabled,
              let surface else {
            return
        }

        let size = ghostty_surface_size(surface)
        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=\(event, privacy: .public) \
            pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
            native_px=\(size.width_px)x\(size.height_px, privacy: .public) \
            cell_px=\(size.cell_width_px)x\(size.cell_height_px, privacy: .public) \
            grid=\(size.columns)x\(size.rows, privacy: .public)
            """
        )
    }

    func logSurfaceGeometryDiagnostics(
        event: String,
        geometry: SurfaceBackingGeometry? = nil,
        visible: Bool? = nil
    ) {
        guard Self.terminalDiagnosticsEnabled else { return }

        let geometryFields: String
        if let geometry {
            geometryFields = """
            backing_px=\(geometry.width)x\(geometry.height) \
            backing_scale=\(GhosttySurfaceDiagnosticsFormat.coordinateDescription(geometry.scale))
            """
        } else {
            geometryFields = "backing_px=unset backing_scale=unset"
        }

        let visibleField = visible.map { String($0) } ?? "unset"
        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=\(event, privacy: .public) \
            pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
            bounds_points=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(self.bounds.size), privacy: .public) \
            frame_points=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(self.frame.size), privacy: .public) \
            window_attached=\(self.window != nil, privacy: .public) \
            visible=\(visibleField, privacy: .public) \
            \(geometryFields, privacy: .public)
            """
        )
    }

    func refreshSurfaceDisplay() {
        guard let surface else {
            return
        }

        ghostty_surface_refresh(surface)
        needsDisplay = true
    }

    // A resized Ghostty surface may already have accepted the new PTY geometry
    // while AppKit keeps stale layer contents around the old bounds. Refresh
    // Ghostty and invalidate both view and layer bounds so prompt redraws do
    // not leave duplicated pixels after sidebar snaps or split changes.
    private func invalidateSurfaceAfterResize() {
        refreshSurfaceDisplay()
        setNeedsDisplay(bounds)
        layer?.setNeedsDisplay()
        layer?.setNeedsDisplay(bounds)
    }

    var windowIsVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    var terminalIsFocused: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    var sessionIsSelectedInKeyWindow: Bool {
        window?.isKeyWindow == true && sessionStore.selectedSessionID == sessionID
    }

    func updateWindowObservation() {
        // Scope removal to the previously-observed window so we don't sweep
        // away unrelated occlusion observers if any are added later.
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: observedWindow
            )
        }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        observedWindow = window
        guard let window else {
            lastKnownOcclusionVisible = false
            return
        }

        lastKnownOcclusionVisible = windowIsVisible

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        // didBecomeKey + activeSpaceDidChange are belt-and-suspenders for
        // tiling window managers (AeroSpace, yabai) that don't always toggle
        // NSWindow.OcclusionState the way Mission Control / Spaces do.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // Repace libghostty's internal CVDisplayLink when the window moves to a
        // screen with a different refresh rate (mirrors Ghostty.app's
        // windowDidChangeScreen). Also fires on initial placement.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
    }

    @objc func windowDidChangeScreen(_ notification: Notification) {
        updateSurfaceDisplayID()
    }

    @objc func windowDidChangeOcclusionState(_ notification: Notification) {
        // Capture once: the refresh decision and the libghostty notification
        // must agree on the same occlusion snapshot.
        let isVisible = windowIsVisible

        guard let surface else {
            let wasVisible = lastKnownOcclusionVisible
            lastKnownOcclusionVisible = isVisible
            if isVisible, !wasVisible {
                scheduleSurfaceCreationIfNeeded()
            }
            return
        }

        if let state = lastAppliedSurfaceBackingState {
            if state.isVisible != isVisible {
                lastAppliedSurfaceBackingState = SurfaceBackingState(
                    geometry: state.geometry,
                    isVisible: isVisible
                )
                pushSurfaceOcclusion(surface, isVisible: isVisible, source: "occlusion-change")
            }
        } else {
            // Geometry hasn't been applied yet (surface freshly created and
            // not laid out, or rebuilt after a free). Push occlusion now and
            // let the next geometry update fill in size/scale — applying
            // either half is fine; libghostty just needs at least one
            // visibility hint before it pauses the render loop.
            pushSurfaceOcclusion(surface, isVisible: isVisible, source: "occlusion-change-pre-geometry")
        }

        // Edge-gate: occlusion fires liberally during Mission Control,
        // Spaces, and Stage Manager transitions. Only act on the visibility
        // edges. With N panes mounted, each notification fires every surface's
        // handler — without this gate that's an "occlusion storm" of redundant
        // refreshes per visibility flap.
        let wasVisible = lastKnownOcclusionVisible
        lastKnownOcclusionVisible = isVisible
        if isVisible, !wasVisible {
            refreshSurfaceDisplay()
            // Re-pace the display link in case the window returned on a
            // different screen, and resume the passive sampler (suspended
            // below while occluded so it isn't waking 4×/sec to no-op).
            updateSurfaceDisplayID()
            startVisibleStateSampling()
        } else if !isVisible, wasVisible {
            stopVisibleStateSampling()
        }
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        // Tiling-WM safety net: AeroSpace/yabai may bring the window forward
        // via paths that don't toggle NSWindowOcclusionState. didBecomeKey
        // is a more reliable "user is looking at this window again" signal.
        guard windowIsVisible else { return }
        guard surface != nil else {
            scheduleSurfaceCreationIfNeeded()
            return
        }
        refreshSurfaceDisplay()
        // Tiling WMs may not toggle occlusion, so re-pace the display link and
        // (idempotently) resume the sampler here too. Backstops the nil-screen
        // case where `windowDidChangeScreen` no-op'd mid-drag.
        updateSurfaceDisplayID()
        startVisibleStateSampling()
    }

    @objc func activeSpaceDidChange(_ notification: Notification) {
        // Same belt-and-suspenders as didBecomeKey but covers the case where
        // the user returns to the awesoMux workspace without bringing the
        // window forward (e.g. it was already key on the destination Space).
        guard windowIsVisible else { return }
        guard surface != nil else {
            scheduleSurfaceCreationIfNeeded()
            return
        }
        refreshSurfaceDisplay()
        updateSurfaceDisplayID()
        startVisibleStateSampling()
    }
}
