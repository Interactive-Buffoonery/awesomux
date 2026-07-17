import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import GhosttyKit
import os

/// AppKit bridge for one libghostty surface.
///
/// Keep this as one bridge type with focused extensions for surface lifecycle,
/// input, terminal events, process-exit handling, and text input. Introduce a
/// coordinator only if bridge ownership grows beyond those responsibilities or
/// unsafe native storage starts spreading beyond the single private field below.
final class GhosttySurfaceNSView: NSView {
    static let terminalDiagnosticsLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "TerminalDiagnostics"
    )
    static let terminalDiagnosticsEnabled =
        TerminalDiagnosticsConfiguration.isEnabled()
    /// Backstop re-check cadence while waiting for the cold-launch width to
    /// settle. Layout changes already re-drive scheduling through the size path;
    /// this timer covers the "width went quiet — now confirm it held" gap that
    /// no further layout event would surface. See `ColdStartSurfaceCreationPolicy`.
    ///
    /// Kept below `ColdStartSurfaceCreationPolicy.widthStabilityInterval` (0.1s)
    /// so a width that goes quiet is confirmed settled on the first poll after the
    /// stability window closes, not the second — otherwise a quiet settle pays up
    /// to two poll intervals of latency.
    static let coldStartCreationPollInterval: TimeInterval = 0.05

    let runtime: GhosttyRuntime
    weak var scrollContainer: GhosttySurfaceContainerView?
    var sessionStore: SessionStore
    var session: TerminalSession
    var sessionID: TerminalSession.ID
    var pane: TerminalPane
    var paneID: TerminalPane.ID
    var enabledAgentRuntimeFileDropSources: Set<AgentRuntimeSource>
    /// Whether a text-detected `grok` session may adopt the Grok agent kind (and
    /// thus its sidebar icon). The same setting gates Grok runtime events.
    /// Refreshed from settings on every `update(…)`, like the sources set above.
    var grokIconEnabled: Bool
    var mouseOverLink: String?
    /// INT-632: computed once at left mouseDown, reused unchanged for the
    /// paired mouseUp. Never recompute at release time — ⌘ can be released
    /// mid-gesture, and a press/release pair that disagreed on the injected
    /// Shift bit would desync libghostty's mouse-report suppression the same
    /// way INT-607 desynced press/release pairing before.
    var leftClickLinkBypassActive = false
    /// The cursor libghostty last requested via `GHOSTTY_ACTION_MOUSE_SHAPE`.
    /// `nil` until the first request arrives, matching Ghostty's own
    /// "ignore unknown shapes" default (see `GhosttyCursorMapper`).
    var terminalCursorShape: NSCursor?
    /// Mirrors Ghostty's `cursorVisible` (`SurfaceView_AppKit.swift:93`). Plain
    /// stored var, not `@Published` — nothing in awesoMux reads this reactively
    /// today; it only feeds `NSCursor.setHiddenUntilMouseMoves`.
    var terminalCursorVisible = true
    let searchState = SurfaceSearchState()
    var searchNeedleWorkItem: DispatchWorkItem?
    /// Dedupes `performSearchBinding` so a needle set programmatically
    /// (e.g. `search_selection`) and then echoed by the field's own
    /// `onChange` doesn't issue the same `search:<needle>` binding twice.
    var lastSearchedNeedle: String?
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var submittedSSHCommandBuffer = ""
    var submittedSSHCommandCaptureDisabled = false
    /// Timestamp of a command/control-modified key deferred by
    /// `performKeyEquivalent` to let AppKit's own responder chain try first.
    /// `doCommand` reads this to know whether to redispatch the event back
    /// through `performKeyEquivalent` instead of silently dropping it — see
    /// `GhosttySurfaceKeyEquivalentPolicy` for the full state machine and
    /// Ghostty's `SurfaceView_AppKit.swift:1246-1276` for why identity has to
    /// be tracked by timestamp rather than by holding the `NSEvent` itself.
    var lastPerformKeyEvent: TimeInterval?
    let agentOutputDetector = AgentOutputDetector()
    let handleCommandFinishedReducer = HandleCommandFinishedReducer()
    let visibleTextAgentStateReducer = VisibleTextAgentStateReducer()
    var commandExitCache = CommandExitCache()
    var shellCommandFinishedIdleLatched = false
    var terminalPromptObserved = false
    var lastAgentDetectionSample: TimeInterval = 0
    var lastDetectedVisibleText = ""
    /// Visible text as of the last `.valueChanged` accessibility post, so the
    /// sampler only announces once per distinct change instead of once per
    /// sample tick. See `scheduleAccessibilityValueChangeAnnouncement()`.
    var lastAccessibilityReportedVisibleText: String?
    private var accessibilityFocusRequested = false
    var hasObservedAgentActivity = false
    var lastRuntimeEventAppliedAt: TimeInterval?
    var lastRuntimeAttentionEventAppliedAt: TimeInterval?
    /// Owns command-bridge lifecycle state + sequencing; this view is the thin
    /// AppKit/libghostty adapter it enacts against (see ``CommandBridgeEnactor``).
    /// Lazy so `self` is fully initialized before the enactor captures it.
    lazy var commandBridgeEnactor = CommandBridgeEnactor(host: self)
    /// Forwarders for values the exit-supervision and heal paths poke directly. The enactor
    /// owns the state; these keep the runtime (`GhosttyRuntime.discardSurface`)
    /// and the existing view tests reading through the same names.
    var commandBridgeSessionID: TerminalSessionID? {
        get { commandBridgeEnactor.sessionID }
        set { commandBridgeEnactor.sessionID = newValue }
    }
    var commandBridgeErrorLatched: Bool {
        commandBridgeEnactor.errorLatched
    }
    var commandBridgeStatusWatcher: AmxStatusFileWatcher? {
        commandBridgeEnactor.statusWatcher
    }
    var ignoresProcessExitAfterCommandBridgeHeal: Bool {
        get { commandBridgeEnactor.ignoresProcessExitAfterHeal }
        set { commandBridgeEnactor.ignoresProcessExitAfterHeal = newValue }
    }
    var commandBridgeRecoveryRecord: CommandBridgeRecoveryRecord? {
        commandBridgeEnactor.recoveryRecord
    }
    var cellSize: NSSize = .zero
    var scrollbar: SurfaceScrollbar?

    /// Debounces the `.selectedTextChanged` VoiceOver announcement so a drag
    /// selection posts one announcement once it settles, not one per
    /// intermediate `GHOSTTY_ACTION_SELECTION_CHANGED` tick. Mirrors
    /// Ghostty's `accessibilitySelectionCancellable`
    /// (`SurfaceView_AppKit.swift:79-80,292-300`) but as a `DispatchWorkItem`
    /// instead of a Combine debounce — awesoMux doesn't otherwise depend on
    /// Combine in this directory, and the existing
    /// cancel-then-reschedule-`DispatchWorkItem` pattern already used for the
    /// enactor's `budgetRefillWorkItem` covers the same "debounce on the main
    /// queue" need without adding it.
    var accessibilitySelectionChangeWorkItem: DispatchWorkItem?

    /// Debounces the `.valueChanged` VoiceOver notification posted when the
    /// passive visible-state sampler detects new terminal output. Same
    /// cancel-then-reschedule `DispatchWorkItem` pattern as
    /// `accessibilitySelectionChangeWorkItem` above, for the same reason: a
    /// burst of PTY output (a command's stdout, an agent streaming a
    /// response) should collapse to one announcement once it settles, not
    /// one per sample tick.
    var accessibilityValueChangeWorkItem: DispatchWorkItem?

    /// How long `scheduleAccessibilityValueChangeAnnouncement()` waits
    /// before actually posting, once scheduled. MUST stay longer than the
    /// worst-case gap between two successive "content changed" detections
    /// during continuous streaming output — otherwise the debounce doesn't
    /// debounce: each sampler tick fires its own notification instead of
    /// the burst collapsing into one. That worst-case gap is
    /// `GhosttySurfaceTerminalEvents.visibleTextChangeThrottle` (0.5s) plus
    /// up to one more `visibleStateSampleInterval` (250ms) of poll jitter
    /// before the throttle window closes — ~750ms. 900ms clears that with
    /// margin. (Found in review: the original 100ms — copied from the
    /// user-driven `.selectedTextChanged` debounce, where it's correct
    /// because a drag-selection settles in milliseconds — was shorter than
    /// that gap, so it never actually debounced sustained PTY output.)
    static let accessibilityValueChangeDebounceWindow: DispatchTimeInterval = .milliseconds(900)

    /// Auto-clears a `progressReport` that never receives its OSC 9;4
    /// `remove` state — e.g. the emitting process is killed or crashes
    /// mid-report. Re-armed on every visible progress write, invalidated on
    /// `.remove` or teardown. Mirrors Ghostty's `progressReport` `didSet`
    /// timer (`SurfaceView_AppKit.swift:23-33`), which this port didn't
    /// originally carry over. See `updateProgressReport`.
    var progressReportExpiryWorkItem: DispatchWorkItem?
    static let progressReportExpiryInterval: DispatchTimeInterval = .seconds(15)
    static let searchNeedleDebounceInterval: DispatchTimeInterval = .milliseconds(300)

    /// Backs the trailing-edge write throttle in `updateProgressReport` —
    /// see `ProgressReportWriteThrottle` for the decision logic and
    /// `progressReportStoreWriteMinInterval` for the window.
    var progressReportThrottleWorkItem: DispatchWorkItem?
    var lastProgressReportStoreWriteAt: TimeInterval?
    /// ~10 writes/sec ceiling for progress-report store writes. See
    /// `ProgressReportWriteThrottle`'s doc comment for why the reducer's
    /// existing no-op guard doesn't already cover this.
    static let progressReportStoreWriteMinInterval: TimeInterval = 0.1

    /// Backs `terminalAccessibilityScreenContents()` — see
    /// `GhosttySurfaceAccessibilityScreenContentsCache` for why this exists
    /// and its invalidation triggers.
    var terminalAccessibilityScreenContentsCache = GhosttySurfaceAccessibilityScreenContentsCache()

    /// Owns focus-only left-click suppression plus press/release pairing for
    /// all mouse buttons. The AppKit bridge passes a per-surface-incarnation
    /// identity into it so a command-bridge respawn between press and release
    /// cannot send the release to the new surface.
    var mouseButtonPolicy = GhosttySurfaceMouseButtonPolicy<UInt64>()
    var nextMouseSurfaceIncarnationID: UInt64 = 0
    var mouseSurfaceIncarnationID: UInt64?
    var currentMouseSurfaceIdentity: UInt64? {
        surface == nil ? nil : mouseSurfaceIncarnationID
    }
    /// True after the previous left-button press was intentionally suppressed
    /// because it only transferred pane focus. The next left `mouseDown` consumes
    /// this to decide whether AppKit's `clickCount` proves the physical gesture
    /// is a double-click that needs a synthetic catch-up click for libghostty.
    var hasPendingFocusTransferClick = false

    /// Drives the passive shell-activity + agent-state-from-visible-text
    /// samplers, which also double as the trigger for the `.valueChanged`
    /// VoiceOver notification (see `sampleAgentStateFromVisibleText()`'s
    /// `lastAccessibilityReportedVisibleText` comparison) — new PTY output
    /// has no other push signal, so it rides the same visible-text diff
    /// rather than adding a second poll loop.
    /// These used to piggyback on the `draw(_:)` override; libghostty now owns
    /// presentation on its own renderer thread (see `GhosttySurfaceTerminalEvents`),
    /// so the samplers lost their per-frame trigger and run on this independent
    /// poll instead. The event-driven command submit/finish ladders still own
    /// precise transition timing — this is only the passive fallback.
    ///
    /// Ceiling: a fixed ~250ms poll re-reads each *visible* pane's viewport. If
    /// that ever shows on a profile, gate it on a libghostty content-change signal
    /// once one is exposed to the embedder.
    var visibleStateSamplingTask: Task<Void, Never>?
    var remoteHandoffTask: Task<Void, Never>?
    static let visibleStateSampleInterval: Duration = .milliseconds(250)

    /// Single unsafe storage slot for the libghostty surface handle.
    ///
    /// ARC may drop the last strong reference from nonisolated `deinit`, so the
    /// storage stays `nonisolated(unsafe)`. Route all other reads and writes
    /// through the MainActor-isolated `surface` accessor.
    nonisolated(unsafe) private var unsafeSurface: ghostty_surface_t?

    /// MainActor-isolated gateway for the libghostty surface handle.
    ///
    /// Intended touch-site files are `GhosttySurfaceNSView`,
    /// `GhosttySurfaceLifecycle`, `GhosttySurfaceTerminalEvents`,
    /// `GhosttySurfaceInputBridge`, and `GhosttySurfaceTextInputClient`.
    ///
    /// The pointer is single-owned here: `disposeNativeSurface()` must clear it
    /// before `ghostty_surface_free`, because freeing also releases the single
    /// `passRetained` userdata ref.
    @MainActor
    var surface: ghostty_surface_t? {
        get { unsafeSurface }
        set { unsafeSurface = newValue }
    }
    weak var observedWindow: NSWindow?
    var lastKnownOcclusionVisible: Bool = false
    var lastAppliedSurfaceBackingState: SurfaceBackingState?
    var pendingSurfaceCreationWorkItem: DispatchWorkItem?
    var coldStartCreationState = ColdStartSurfaceCreationState()
    var windowFrameSettleState = WindowFrameSettleState()
    var nativeSurfaceWasDisposed = false
    var contentSizeBacking: NSSize?
    var contentSize: NSSize {
        get { contentSizeBacking ?? frame.size }
        set { contentSizeBacking = newValue }
    }
    var hasNativeSurface: Bool {
        surface != nil
    }
    var isColdStartSurfacePhase: Bool {
        // Every pane mounted before any surface spawns is still seeing a
        // placeholder cold-launch width; defer its spawn until the width
        // settles. Once any surface exists the layout is settled and later
        // panes spawn immediately. See `ColdStartSurfaceCreationPolicy`.
        runtime.isColdStartSurfacePhase()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    // The panel chrome is movable-by-background; terminal drags are selection
    // and mouse reporting, never window moves.
    override var mouseDownCanMoveWindow: Bool { false }

    init(
        runtime: GhosttyRuntime,
        sessionStore: SessionStore,
        session: TerminalSession,
        pane: TerminalPane,
        enabledAgentRuntimeFileDropSources: Set<AgentRuntimeSource>,
        grokIconEnabled: Bool
    ) {
        self.runtime = runtime
        self.sessionStore = sessionStore
        self.session = session
        self.sessionID = session.id
        self.pane = pane
        self.paneID = pane.id
        self.enabledAgentRuntimeFileDropSources = enabledAgentRuntimeFileDropSources
        self.grokIconEnabled = grokIconEnabled
        // Match libghostty's embedded-apprt default Surface.size (800x600 px)
        // for the AppKit birth frame until the scroll-view wrapper publishes
        // the first real content size. The native surface is created later.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        wantsLayer = true
        applyTerminalBackstopBackgroundColor()
        layer?.needsDisplayOnBoundsChange = true
        setAccessibilityElement(true)

        logSurfaceGeometryDiagnostics(event: "surface-view-init")

        // The native libghostty surface is created after the scroll wrapper
        // publishes its mounted content size. Creating here would spawn the
        // shell against the embedded runtime's 800x600 placeholder before the
        // pane has a chance to report the real terminal geometry.

        GhosttySurfaceMouseFocusMonitor.shared.start()

        // Accept files/text/URLs dragged in from Finder, Safari, etc. See
        // GhosttySurfaceDragAndDrop.swift for the NSDraggingDestination
        // conformance this registration enables.
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        MainActor.assumeIsolated {
            pendingSurfaceCreationWorkItem?.cancel()
            pendingSurfaceCreationWorkItem = nil
            visibleStateSamplingTask?.cancel()
            visibleStateSamplingTask = nil
            remoteHandoffTask?.cancel()
            remoteHandoffTask = nil
            accessibilitySelectionChangeWorkItem?.cancel()
            accessibilitySelectionChangeWorkItem = nil
            accessibilityValueChangeWorkItem?.cancel()
            accessibilityValueChangeWorkItem = nil
            progressReportExpiryWorkItem?.cancel()
            progressReportExpiryWorkItem = nil
            progressReportThrottleWorkItem?.cancel()
            progressReportThrottleWorkItem = nil
            resetSearchStateForSurfaceTeardown()
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            disposeNativeSurface(resetHostedLayer: false)
        }
    }

    // MARK: - Visible-state sampling

    /// Start (or restart) the passive sampler poll. Idempotent — cancels any
    /// prior task first. The occlusion handlers stop this while the window is
    /// hidden and restart it on return, so it isn't waking to no-op in the
    /// background; the in-loop `windowIsVisible` guard is a race-window backstop
    /// for the gap between an occlusion notification and the stop landing.
    ///
    /// NOTE: occlusion pauses libghostty's *renderer*, NOT its IO — the screen
    /// buffer keeps changing from PTY output while hidden (`Surface.zig`'s
    /// `occlusionCallback` only messages the renderer thread). We defer sampling
    /// anyway (matching the old draw-driven path, which also didn't fire while
    /// occluded); a transition that lands while hidden is caught on the first
    /// post-return tick via the `lastDetectedVisibleText` dedupe.
    func startVisibleStateSampling() {
        visibleStateSamplingTask?.cancel()
        visibleStateSamplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.visibleStateSampleInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.surface != nil, self.windowIsVisible else { continue }
                // Global refresh self-throttles (100ms floor), so N panes each
                // calling it on their own poll collapse to one sampling cadence.
                self.runtime.sampleShellActivity(in: self.sessionStore)
                self.sampleAgentStateFromVisibleText()
            }
        }
    }

    func stopVisibleStateSampling() {
        visibleStateSamplingTask?.cancel()
        visibleStateSamplingTask = nil
    }

    /// Tell libghostty which display this surface is on so its internal
    /// CVDisplayLink paces to the correct refresh rate. Mirrors Ghostty.app's
    /// `windowDidChangeScreen` handler. Without it, libghostty falls back to the
    /// active-displays default, which can mispace vsync on a non-primary screen.
    func updateSurfaceDisplayID() {
        guard let surface,
            let screenNumber = window?.screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            return
        }
        ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
    }

    @MainActor
    func disposeNativeSurface(resetHostedLayer: Bool = false) {
        // Mounted exit-supervision/heal paths opt in so they don't show the
        // previous renderer contents while deciding whether to respawn.
        if resetHostedLayer, surface != nil, !nativeSurfaceWasDisposed {
            resetLayerAfterNativeSurfaceTeardown()
        }

        // Stop the status watcher whenever the surface goes away. Idempotent and
        // runs ahead of the surface guard so a watcher armed before a
        // failed/absent surface is still torn down (it holds an evtFD; a missed
        // stop leaks it). The enactor keeps the channel/reason/recovery record so
        // exit supervision — which disposes as the front half of a respawn — can
        // still read them.
        commandBridgeEnactor.notifyNativeSurfaceDisposed()
        // INT-632: the bypass latch describes an in-flight gesture on THIS
        // surface incarnation — a respawn mid-gesture must not staple a
        // synthetic Shift onto a release the new surface never saw a press
        // for. Not reset in update(session:pane:...): that runs on every
        // SwiftUI pass, including mid-drag, and would defeat the latch.
        leftClickLinkBypassActive = false
        accessibilitySelectionChangeWorkItem?.cancel()
        accessibilitySelectionChangeWorkItem = nil
        accessibilityValueChangeWorkItem?.cancel()
        accessibilityValueChangeWorkItem = nil
        progressReportExpiryWorkItem?.cancel()
        progressReportExpiryWorkItem = nil
        progressReportThrottleWorkItem?.cancel()
        progressReportThrottleWorkItem = nil
        lastProgressReportStoreWriteAt = nil
        resetSearchStateForSurfaceTeardown()
        stopVisibleStateSampling()
        // A VoiceOver accessor firing mid-heal (surface == nil) would
        // otherwise cache an empty read that outlives the surface it was
        // taken from, into the next surface's life.
        terminalAccessibilityScreenContentsCache.invalidate()
        // Both of sampleAgentStateFromVisibleText()'s dedupe gates must
        // reset together: `lastDetectedVisibleText` is checked FIRST and
        // returns early on a match, so resetting only
        // `lastAccessibilityReportedVisibleText` leaves that outer gate
        // stale — a respawned surface whose first sample happens to match
        // the old surface's last text (e.g. both idle at an empty prompt)
        // would return before the accessibility comparison is ever reached,
        // silently suppressing both the `.valueChanged` post and agent-state
        // re-detection for that first post-respawn tick.
        lastDetectedVisibleText = ""
        lastAccessibilityReportedVisibleText = nil

        guard let surface else {
            mouseSurfaceIncarnationID = nil
            return
        }

        guard !nativeSurfaceWasDisposed else {
            assertionFailure("native Ghostty surface disposed more than once")
            return
        }

        nativeSurfaceWasDisposed = true
        self.surface = nil
        mouseSurfaceIncarnationID = nil
        lastAppliedSurfaceBackingState = nil
        runtime.freeSurface(surface)
    }

    func update(
        sessionStore: SessionStore,
        session: TerminalSession,
        pane: TerminalPane,
        enabledAgentRuntimeFileDropSources: Set<AgentRuntimeSource>,
        grokIconEnabled: Bool
    ) {
        self.sessionStore = sessionStore
        self.session = session
        self.sessionID = session.id
        if self.pane.terminalSessionID != pane.terminalSessionID {
            commandBridgeEnactor.handleSessionRepoint()
            resetSearchStateForSurfaceTeardown()
        }
        self.pane = pane
        self.paneID = pane.id
        self.enabledAgentRuntimeFileDropSources = enabledAgentRuntimeFileDropSources
        self.grokIconEnabled = grokIconEnabled
        applyTerminalBackstopBackgroundColor()
        // While the reconnect overlay covers this pane the native surface is
        // disposed — exclude it from the accessibility tree so VoiceOver doesn't
        // land on a zombie "Terminal content area" stop under the overlay;
        // restore when the overlay clears. Driven from `update` (which re-runs
        // whenever `remoteReconnect` changes, same as the overlay gate) so latch,
        // reconnect, re-latch, and heal are all covered by one seam (INT-697
        // fix #3c). Change-guarded to keep the re-render hot path free of
        // redundant AppKit writes.
        let shouldBeAccessibilityElement = pane.remoteReconnect == nil
        if !shouldBeAccessibilityElement {
            accessibilityFocusRequested = false
        }
        if isAccessibilityElement() != shouldBeAccessibilityElement {
            setAccessibilityElement(shouldBeAccessibilityElement)
        }
        sizeDidChange(contentSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            accessibilityFocusRequested = false
        }

        // Fires on both attach (window != nil) and detach (window == nil).
        // updateWindowObservation handles both directions; everything else
        // here must be safe to call when window is nil.
        let surfaceExistedBeforeMount = surface != nil
        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-window-move \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                attached=\(self.window != nil, privacy: .public) \
                surface_existed=\(surfaceExistedBeforeMount, privacy: .public) \
                window_visible=\(self.windowIsVisible, privacy: .public)
                """
            )
        }
        updateWindowObservation()
        updateSurfaceDisplayID()
        sizeDidChange(contentSize)

        // Only refresh on RE-attach. A freshly-created surface has no stale
        // frame to clear; an already-existing one being reattached to a
        // window is the workspace-return path INT-196 exists to fix.
        if window != nil, surfaceExistedBeforeMount {
            refreshSurfaceDisplay()
        }

        // Track the sampler across window attach/detach. Detaching (window ==
        // nil, e.g. a workspace switch that unmounts this pane's view but keeps
        // the surface cached) must STOP the poll — otherwise it spins at 4Hz
        // bailing on the `windowIsVisible` guard forever. Re-attaching to a
        // visible window must RESTART it: occlusion notifications don't fire when
        // the destination window is already visible (the INT-196 return path), so
        // without this the passive sampler could stay dead until the next
        // didBecomeKey. `startVisibleStateSampling` cancels-then-recreates, so
        // this is safe alongside the occlusion/key/space start paths.
        if window == nil {
            stopVisibleStateSampling()
            scheduleOrphanRescueCheckAfterDetach()
        } else if surface != nil, windowIsVisible {
            startVisibleStateSampling()
        }
    }

    /// A split collapse can detach this view AFTER the surviving single-pane
    /// container already adopted it: SwiftUI may give the outgoing split
    /// subtree one more update pass with the stale layout, which steals the
    /// view into a container that is then dismantled (observed live —
    /// INT-600). The surviving container still claims the view but gets no
    /// further `updateNSView` in an idle app, so nothing re-runs `mount()` and
    /// the pane stays blank. One runloop after a detach — once legitimate
    /// reparents (workspace switch, pane drag, close) have settled — ask the
    /// runtime to nudge SwiftUI if this pane is still supposed to be on
    /// screen. A false positive costs one no-op re-render.
    private func scheduleOrphanRescueCheckAfterDetach() {
        // Unlike scheduleColdStartRecheck's DispatchWorkItem, a closure passed
        // directly to DispatchQueue.main.async IS statically MainActor-isolated
        // (SDK annotation) — no assumeIsolated wrapper needed here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isOrphanedLiveSurfaceView() else { return }
            if Self.terminalDiagnosticsEnabled {
                Self.terminalDiagnosticsLogger.info(
                    """
                    terminal-diagnostics event=surface-orphan-rescue \
                    pane=\(self.paneID.uuidString.prefix(8), privacy: .public)
                    """
                )
                // A rescue that doesn't land would otherwise fail silently and
                // re-latch the INT-600 blank with a log line claiming it was
                // handled — check back after the nudged render pass and record
                // the miss. Diagnostics-only: production schedules nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.isOrphanedLiveSurfaceView() else { return }
                    Self.terminalDiagnosticsLogger.info(
                        """
                        terminal-diagnostics event=surface-orphan-rescue-failed \
                        pane=\(self.paneID.uuidString.prefix(8), privacy: .public)
                        """
                    )
                }
            }
            self.runtime.noteOrphanedSurfaceView(paneID: self.paneID)
        }
    }

    /// True when this view should be on screen but isn't: still detached,
    /// still the runtime's cached view for its pane, and the pane is still
    /// part of the SELECTED session's layout. Workspace switches fail the
    /// selection check; genuine closes fail the cache-identity check
    /// (`discardSurface` evicts before detaching).
    private func isOrphanedLiveSurfaceView() -> Bool {
        window == nil
            && runtime.cachedSurfaceView(for: paneID) === self
            && sessionStore.selectedSessionID == sessionID
            && sessionStore.session(id: sessionID)?.layout.pane(id: paneID) != nil
    }

    // Take focus when nothing meaningful holds it: nil responder, the window
    // itself (sentinel for "no view claimed focus"), or a peer terminal
    // surface (so pane-switch / split / new-pane flows can still hand off
    // keyboard focus). Anything else — sidebar text fields, sheets, the
    // workspace filter — is preserved.
    //
    // The peer-surface arm is safe ONLY because `becomeFirstResponder` calls
    // `sessionStore.setActivePane` whenever a surface view takes focus (with
    // or without a live native surface — see GhosttySurfaceInputBridge), so a
    // peer holding focus while WE are the active pane is always a stale
    // handoff, never a pane the user deliberately focused. Any new code path
    // that makes a surface first responder MUST keep that coupling, or the
    // ungated per-mount reclaim will repeatedly steal focus mid-typing.
    func requestFocusIfWindowHasNoTarget() {
        guard let window else {
            return
        }

        let responder = window.firstResponder
        let isVacant =
            responder == nil
            || responder === window
            || responder is GhosttySurfaceNSView
        let claimed = isVacant && window.makeFirstResponder(self)
        if Self.terminalDiagnosticsEnabled {
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-focus-reclaim \
                pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
                claimed=\(claimed, privacy: .public) \
                responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)
                """
            )
        }
    }

    func accessibilityPaneLabel(isActive: Bool) -> String {
        let activePrefix = isActive ? "Active " : ""
        // `pane.title` is set from OSC 0/2 by the child process — sanitize it the
        // same way the formatter sanitizes the cwd, so a hostile title can't
        // fragment the spoken label with control bytes.
        let title = TerminalAccessibilityPathFormatter.sanitizedForSpeech(pane.title)
        let path = TerminalAccessibilityPathFormatter.format(pane.workingDirectory)
        guard !path.isEmpty else {
            return "\(activePrefix)terminal pane, \(title)"
        }
        return "\(activePrefix)terminal pane, \(title), \(path)"
    }

    // Shown in the OSC 52 clipboard-write confirmation so the user can tell
    // WHICH pane asked to overwrite the clipboard — important when several
    // panes are open and one fires in the background. Prefer human-recognizable
    // identifiers (workspace title, working directory) over the raw UUID, which
    // means nothing to a person; the short id is a last-resort disambiguator.
    // The result is sanitized + truncated downstream before it reaches the alert.
    var clipboardWriteSourceDescription: String {
        let workspace =
            session.isTitleUserEdited && !session.title.isEmpty
            ? session.title
            : "workspace \(String(self.sessionID.uuidString.prefix(8)))"

        let location: String
        if !pane.workingDirectory.isEmpty {
            location = pane.workingDirectory
        } else if !pane.title.isEmpty {
            location = pane.title
        } else {
            location = "pane \(String(self.paneID.uuidString.prefix(8)))"
        }

        return "\(workspace) — \(location)"
    }

    override func accessibilityLabel() -> String? {
        "Terminal output, \(TerminalAccessibilityPathFormatter.sanitizedForSpeech(pane.title))"
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        if accessibilityFocused {
            guard isAccessibilityElement(),
                let window,
                window.isVisible,
                window.isKeyWindow
            else {
                accessibilityFocusRequested = false
                return
            }
        }
        accessibilityFocusRequested = accessibilityFocused
        if accessibilityFocused {
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    override func isAccessibilityFocused() -> Bool {
        accessibilityFocusRequested
    }
}
