import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Carbon.HIToolbox
import Darwin
import DesignSystem
import Foundation
import GhosttyKit
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class GhosttyRuntime {
    enum Readiness: String {
        case uninitialized
        case ready
        case failed
    }

    enum DesktopNotificationEffect: Equatable {
        case ignore
        case markNeedsAttention
    }

    nonisolated static func secureInputMode(
        _ mode: ghostty_action_secure_input_e
    ) -> SecureInputCoordinator.Mode? {
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON:
            return .on
        case GHOSTTY_SECURE_INPUT_OFF:
            return .off
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            return .toggle
        default:
            return nil
        }
    }

    /// Determines the side effect for a desktop notification.
    ///
    /// The title and body are accepted but intentionally not parsed. Keeping the
    /// payload in this decision point makes callback changes confront the rule:
    /// OSC notifications are output-attention signals, not agent runtime events.
    nonisolated static func desktopNotificationEffect(
        title _: String,
        body _: String,
        outputMarksAttention: Bool
    ) -> DesktopNotificationEffect {
        outputMarksAttention ? .markNeedsAttention : .ignore
    }

    private static var didInitializeProcess = false
    private static var didLogConfigEnvironment = false

    /// Last collision set the menu-binding-collision warning actually logged.
    /// `makeGhosttyConfig` (and therefore `logMenuBindingCollisionsIfAny`) runs
    /// on every `initialize()`/`reload()`/`applyTerminalAppearance(_:)` call —
    /// including the 75ms-debounced settings-drag path in
    /// `TerminalAppearanceSync.swift` — so a single slider drag can trigger it
    /// dozens of times. A `Set` (not a fire-once `Bool` like
    /// `didLogConfigEnvironment`) so a collision set that clears and later
    /// reappears logs again instead of going silent forever after the first hit.
    private static var lastLoggedCollisions: Set<String> = []

#if DEBUG
    nonisolated private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "GhosttyRuntimeMemory"
    )
#endif

    nonisolated private static let configEnvironmentLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "GhosttyConfigEnvironment"
    )

    nonisolated private static let terminalDiagnosticsLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "TerminalDiagnostics"
    )

    nonisolated private static let terminalDiagnosticsEnabled =
        TerminalDiagnosticsConfiguration.isEnabled()

    // `nonisolated(unsafe)` is load-bearing: deinit on a `@MainActor` class is
    // itself nonisolated and can't read MainActor-isolated stored properties.
    // SwiftUI releases `@State` values on the main thread, so in practice both
    // pointers are written and freed from MainActor. If GhosttyRuntime ever
    // gets retained from a non-MainActor context, route the frees through a
    // sync MainActor hop instead of relaxing this invariant.
    @ObservationIgnored
    nonisolated(unsafe) private var config: ghostty_config_t?

    @ObservationIgnored
    nonisolated(unsafe) private var app: ghostty_app_t?

    @ObservationIgnored
    private var eventLoopWatchdog: GhosttyEventLoopWatchdog?

    /// Reused across watchdog replacements so a stuck OSLog XPC query cannot
    /// accumulate one blocked worker and queue per terminal reload.
    @ObservationIgnored
    private lazy var eventLoopFaultSource: any GhosttyFaultLogSource =
        OSLogGhosttyFaultSource()

    /// Testing seam only - exposes the watchdog's last-tick timestamp so
    /// wiring can be asserted without reaching into OSLogStore or timers.
    var lastEventLoopTickAtForTesting: Date {
        eventLoopWatchdog?.lastTickAtForTesting ?? .distantPast
    }

    @ObservationIgnored
    private var applicationInputObserverTokens: [NSObjectProtocol] = []

    @ObservationIgnored
    private let secureInputCoordinator = SecureInputCoordinator()

    @ObservationIgnored
    nonisolated(unsafe) private var surfaceViews: [TerminalPane.ID: GhosttySurfaceNSView] = [:]

    private(set) var surfaceCacheRevision: UInt64 = 0
    /// Bumped when a live pane's surface view reports itself orphaned by
    /// container churn (see `noteOrphanedSurfaceView`). Read into
    /// `GhosttySurfaceRepresentable` so the bump forces an `updateNSView`
    /// pass, whose `mount()` re-adopts the orphan (INT-600).
    private(set) var surfaceRemountNudgeRevision: UInt64 = 0
    private(set) var isScrollbackDumpSheetPresented = false

    @ObservationIgnored
    private var scrollbackDumpSheetPaneIDs: Set<TerminalPane.ID> = []

    @ObservationIgnored
    private(set) var commandBridgeRecoveryRecords: [TerminalSessionID: CommandBridgeRecoveryRecord] = [:]

    /// The live bridge generations for remote panes (INT-698). Optional and
    /// nil until D4 constructs it with the shared `BridgeSocketLedger` and
    /// starts registering successful attaches; the discard/quit hooks below
    /// no-op while it is nil, so this task ships the teardown mechanism without
    /// pre-deciding the enactor wiring D4 owns.
    @ObservationIgnored
    var bridgeGenerationRegistry: BridgeGenerationRegistry?

    /// The single per-runtime remote-socket ledger (INT-698): the sole deletion
    /// authority shared by every attach preflight and the generation registry, so
    /// `previousGeneration`/`commit` and every teardown `rm` route through one
    /// record. Constructed in `init`; the registry above is built from it there.
    @ObservationIgnored
    let bridgeSocketLedger = BridgeSocketLedger()

    /// The session-keyed permission-coordinator lookup (INT-698 D4): the banner,
    /// the focus-prompt command, and the make-before-break teardown all resolve a
    /// live bridge generation's coordinator through here.
    @ObservationIgnored
    let bridgeCoordinatorStore = BridgeCoordinatorStore()

    /// One long-lived attach preflight per remote bridge session, keyed by the
    /// pane's `TerminalSessionID`. Persisted (not rebuilt per attach) because its
    /// `current` listener is the make-before-break handle a reattach uses to break
    /// the previous generation only after the new one publishes; a fresh preflight
    /// each attach would lose that handle and leak forwards across reattaches.
    /// Removed on genuine close / session re-point (the teardown-parity paths).
    @ObservationIgnored
    private var bridgeAttachPreflights: [TerminalSessionID: BridgeAttachPreflight] = [:]

    @ObservationIgnored
    private var agentIntegrationsProvider: @MainActor () -> AgentIntegrationsConfig = { .defaultValue }

#if DEBUG
    // Set of in-flight surface pointers, used to assert that we never free
    // the same surface twice. Allocator pointer reuse is not a concern here:
    // `freeSurface` is `@MainActor`-isolated, the insert-then-defer-remove
    // is bracketed in one synchronous scope, and the only writer is the
    // single MainActor. If this assertion fires, it's a genuine double-free.
    @ObservationIgnored
    private var surfacesBeingFreed: Set<UInt> = []
#endif

    @ObservationIgnored
    let wakeupCoalescer = GhosttyWakeupCoalescer()

    @ObservationIgnored
    private let performanceSampler = PerformanceSampler()

    @ObservationIgnored
    private let agentRuntimeEventBridge: AgentRuntimeEventBridge

    @ObservationIgnored
    private let diagnosticEventHandler: (LocalDiagnosticEventInput) -> Void

    @ObservationIgnored
    private var hasCompletedInitialization = false

    @ObservationIgnored
    private var shellActivityDebounceRefreshTask: Task<Void, Never>?

    // Keyed PER PANE so a submit/finish ladder in one pane can't cancel another
    // pane's in-flight ladder. A single shared slot meant a quick finish in one
    // pane cancelled the late (0.50/0.80s) submit samples another pane relies on
    // to catch silent commands — see INT-333.
    @ObservationIgnored
    private var shellActivityLifecycleRefreshTasks: [TerminalPane.ID: Task<Void, Never>] = [:]

    // Throttle floor for the passive shell-activity sampler. Each surface polls
    // on its own ~250ms task, and each refresh samples every surface + walks every
    // session — so without a floor, N panes would amplify into N× global walks.
    // Sampling faster than the debounce can't surface a committable transition, so
    // a monotonic floor collapses concurrent polls into one cadence without losing
    // fidelity. (Until INT-523's render fix this floor tamed the draw() hot path,
    // which fired at up to 120Hz/pane under a chatty PTY — the INT-471 path.)
    @ObservationIgnored
    private var lastShellActivitySampleAt: ContinuousClock.Instant?
    private static let shellActivitySampleThrottle: Duration = .milliseconds(100)

    @ObservationIgnored
    private let terminalAppearanceProvider: @MainActor () -> TerminalAppearancePreferences

    /// Returns whether output-driven needs-attention signaling should
    /// fire. When `false`, the runtime swallows RING_BELL /
    /// DESKTOP_NOTIFICATION actions and does not mark the session as
    /// needing attention. Defaults to `true` for callers that don't
    /// configure the provider (tests, previews).
    @ObservationIgnored
    private var outputMarksAttentionProvider: @MainActor () -> Bool = { true }

    @ObservationIgnored
    private var clipboardWritePolicyProvider: @MainActor () -> TerminalConfig.ClipboardWritePolicy = {
        .ask
    }

    @ObservationIgnored
    private var confirmClipboardReadProvider: @MainActor () -> Bool = { true }

    @ObservationIgnored
    private var copyOnSelectProvider: @MainActor () -> TerminalConfig.CopyOnSelect = {
        .inherit
    }

    @ObservationIgnored
    private var commandBridgeEnabledProvider: @MainActor () -> Bool = { false }

    private(set) var readiness: Readiness = .uninitialized
    private(set) var errorMessage: String?

    /// The resolved terminal background color, read back from the finalized
    /// libghostty config (`background` key) on every config build. This is the
    /// color the surface actually paints — in Ghostty-config mode it comes from
    /// the user's own config, which the app otherwise can't see (INT-285). UI
    /// chrome that sits *over* the terminal (the active-pane focus stripe) keys
    /// its contrast off this rather than the app theme. Defaults to the dark
    /// Mocha base until the first config build populates it.
    private(set) var terminalBackgroundColor: NSColor = NSColor(
        srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1
    )

    var version: String {
        GhosttyRuntimeProbe.linkedVersion
    }

    var isReady: Bool {
        readiness == .ready
    }

    func surfaceView(
        sessionStore: SessionStore,
        session: TerminalSession,
        pane: TerminalPane,
        enabledAgentRuntimeFileDropSources: Set<AgentRuntimeSource>,
        grokIconEnabled: Bool
    ) -> GhosttySurfaceNSView {
        if let surfaceView = surfaceViews[pane.id] {
            surfaceView.update(
                sessionStore: sessionStore,
                session: session,
                pane: pane,
                enabledAgentRuntimeFileDropSources: enabledAgentRuntimeFileDropSources,
                grokIconEnabled: grokIconEnabled
            )
            // Intentionally not logged: this fires on every SwiftUI re-render
            // (resize, focus shift, state churn) and floods the unified-log
            // ring buffer. Cache lifecycle is captured by create/discard.
            return surfaceView
        }

#if DEBUG
        logSurfaceCacheEvent("create-start", sessionID: session.id, paneID: pane.id)
#endif
        let surfaceView = GhosttySurfaceNSView(
            runtime: self,
            sessionStore: sessionStore,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: enabledAgentRuntimeFileDropSources,
            grokIconEnabled: grokIconEnabled
        )
        surfaceViews[pane.id] = surfaceView
        surfaceCacheRevision &+= 1
#if DEBUG
        logSurfaceCacheEvent("create-finish", sessionID: session.id, paneID: pane.id)
#endif
        return surfaceView
    }

    func cachedSurfaceView(for paneID: TerminalPane.ID) -> GhosttySurfaceNSView? {
        surfaceViews[paneID]
    }

    /// Observed foreground process name (`p_comm`) for a pane, or nil when no
    /// usable evidence exists (no live surface, latched error, no bridge pid).
    func foregroundComm(in paneID: TerminalPane.ID) -> String? {
        guard let surfaceView = surfaceViews[paneID] else {
            Self.nudgeGateLogger.info(
                "nudge probe: no surface view for pane \(paneID.uuidString, privacy: .public)")
            return nil
        }
        return surfaceView.commandBridgeEnactor.foregroundComm()
    }

    /// INT-569 field diagnostics for the document-nudge evidence chain.
    nonisolated private static let nudgeGateLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "DocumentNudgeGate"
    )

    func applySecureInput(_ mode: SecureInputCoordinator.Mode, for paneID: TerminalPane.ID) {
        secureInputCoordinator.apply(mode, for: paneID)
    }

    func setSecureInputFocused(_ focused: Bool, for paneID: TerminalPane.ID) {
        secureInputCoordinator.setFocused(focused, for: paneID)
    }

    func isSecureInputFocusedForTesting(_ paneID: TerminalPane.ID) -> Bool {
        secureInputCoordinator.isFocusedForTesting(paneID)
    }

    /// A cached surface view for a pane that should be on screen found itself
    /// detached from the window after the render churn settled — a split
    /// collapse let the outgoing split subtree update after the surviving
    /// container and steal the view into a container that was then dismantled
    /// (INT-600). Nothing re-runs the surviving container's `mount()` in an
    /// idle app, so nudge SwiftUI: the revision is a stored property of
    /// `GhosttySurfaceRepresentable`, and bumping it re-runs `updateNSView`,
    /// whose `mount()` self-heal re-adopts the orphan.
    func noteOrphanedSurfaceView(paneID: TerminalPane.ID) {
        guard surfaceViews[paneID] != nil else {
            return
        }
        surfaceRemountNudgeRevision &+= 1
    }

    @discardableResult
    func presentSearch(in paneID: TerminalPane.ID) -> Bool {
        guard !isScrollbackDumpSheetPresented,
              let surfaceView = surfaceViews[paneID] else {
            return false
        }
        surfaceView.presentSearch()
        return true
    }

    /// Drive a manual remote reconnect on the pane's surface view (INT-697).
    /// The view survives the error latch (`disposeNativeSurface` doesn't evict
    /// it; only `discardSurface` does), so the lookup succeeds for a latched
    /// pane. Returns false when no surface view is registered.
    @discardableResult
    func reconnectRemotePane(in paneID: TerminalPane.ID) -> Bool {
        guard let surfaceView = surfaceViews[paneID] else {
            return false
        }
        surfaceView.reconnectRemotePane()
        return true
    }

    @discardableResult
    func presentScrollbackDump(in paneID: TerminalPane.ID) -> Bool {
        guard !isScrollbackDumpSheetPresented,
              let surfaceView = surfaceViews[paneID] else {
            return false
        }
        surfaceView.presentScrollbackDump()
        return true
    }

    func setScrollbackDumpSheetPresented(_ isPresented: Bool, for paneID: TerminalPane.ID) {
        if isPresented {
            scrollbackDumpSheetPaneIDs.insert(paneID)
        } else {
            scrollbackDumpSheetPaneIDs.remove(paneID)
        }
        isScrollbackDumpSheetPresented = !scrollbackDumpSheetPaneIDs.isEmpty
    }

    func commandBridgeRecoveryRecord(
        for terminalSessionID: TerminalSessionID
    ) -> CommandBridgeRecoveryRecord {
        if let record = commandBridgeRecoveryRecords[terminalSessionID] {
            return record
        }

        let record = CommandBridgeRecoveryRecord(terminalSessionID: terminalSessionID)
        commandBridgeRecoveryRecords[terminalSessionID] = record
        return record
    }

    func discardCommandBridgeRecoveryRecord(for terminalSessionID: TerminalSessionID) {
        commandBridgeRecoveryRecords.removeValue(forKey: terminalSessionID)
    }

    /// Types chrome-originated text (e.g. the Path Bar's ⌥-checkout or the document
    /// nudge) into a pane's surface as if the user had typed it.
    ///
    /// Returns `true` when the pane has a live surface and the text was staged;
    /// `false` when no surface exists for `paneID` (process exited, pane not yet
    /// spawned). The nudge button uses the return value to disable itself rather than
    /// silently no-op when the target terminal's process has died.
    @discardableResult
    func sendText(
        _ text: String,
        toPane paneID: TerminalPane.ID,
        focusingSurface: Bool = true
    ) -> Bool {
        guard let surface = surfaceViews[paneID] else { return false }
        if focusingSurface {
            surface.writeFromChrome(text)
        } else {
            surface.sendText(text)
        }
        return true
    }

    func discardSurface(for paneID: TerminalPane.ID) {
        // Stop a closed pane's submit/finish ladder from waking up to re-sample
        // a surface set it no longer belongs to. Done before the surface-view
        // guard so a redundant discard (surface already gone, ladder still
        // in-flight) still cancels the orphaned task.
        shellActivityLifecycleRefreshTasks.removeValue(forKey: paneID)?.cancel()
        secureInputCoordinator.removePane(paneID)
        guard let surfaceView = surfaceViews.removeValue(forKey: paneID) else {
#if DEBUG
            logSurfaceCacheEvent("discard-miss", paneID: paneID)
#endif
            return
        }
        surfaceCacheRevision &+= 1

        // Resolve the recovery-record key from the linked record, the active bridge
        // session, or — when neither is set yet — the pane's own terminalSessionID.
        // That last fallback covers a healed pane re-foregrounded but not yet
        // re-attached: its fresh view's `commandBridgeSessionID` is still nil, so a
        // genuine close in that pre-attach window would otherwise leave the record
        // (preserved by the earlier heal) orphaned. The pane always carries its
        // terminalSessionID, so the key is always recoverable.
        let recoverySessionID = surfaceView.commandBridgeRecoveryRecord?.terminalSessionID
            ?? surfaceView.commandBridgeSessionID
            ?? surfaceView.pane.terminalSessionID
        let preservesRecoveryRecord = surfaceView.ignoresProcessExitAfterCommandBridgeHeal

        agentRuntimeEventBridge.stopWatching(paneID: paneID)
        surfaceView.disposeNativeSurface()
        surfaceView.removeFromSuperview()
        // The heal sets `ignoresProcessExitAfterCommandBridgeHeal` to keep the record
        // alive across the view swap; every other discard is a genuine teardown, so
        // free the record (no-op when the pane never had one).
        if BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: preservesRecoveryRecord) {
            discardCommandBridgeRecoveryRecord(for: recoverySessionID)
            // Genuine close also drops the session's long-lived attach preflight —
            // a heal keeps it so the successor's re-mint can break the previous
            // generation through its retained listener handle.
            forgetBridgeAttachPreflight(for: recoverySessionID)
            // Genuine close: break this session's live bridge generation now
            // (cancel the reverse forward, rm the remote socket by exact ledger
            // path, shut the listener). The heal branch deliberately does none of
            // this — the generation is transferred, and D2's attach step 5 breaks
            // the old one only after the successor publishes (the recovery-record
            // survival contract). Fire-and-forget: teardown is async best-effort
            // and must not block the discard, which runs during AppKit layout.
            if let registry = bridgeGenerationRegistry {
                // Capture token synchronously so a successor re-mint registered
                // before the fire-and-forget Task runs is never wrongly torn down
                // (same shape as CommandBridgeEnactor; review finding R-3).
                if let token = registry.currentToken(for: recoverySessionID) {
                    Task { await registry.teardown(for: recoverySessionID, ifToken: token) }
                } else {
                    Task { await registry.teardown(for: recoverySessionID) }
                }
            }
        }
#if DEBUG
        logSurfaceCacheEvent("discard", paneID: paneID)
#endif
    }

    func discardSurfaces(for session: TerminalSession) {
#if DEBUG
        logSurfaceCacheEvent(
            "discard-session-start",
            sessionID: session.id,
            paneID: session.activePaneID
        )
#endif
        // Tear down each pane's surface, then free its command-bridge recovery
        // record. A daemon-death heal that bailed before remount (pane unmounted,
        // no container) preserves the record but evicts the surface, so the
        // per-pane `discardSurface` can't reach it (cache-miss → early return). The
        // session is closing here, so drop every pane's record directly by
        // terminalSessionID — otherwise it leaks for the app's lifetime.
        //
        // Also tear down bridge preflight/registry on cache-miss: without this,
        // a healed-but-unmounted workspace close left reverse-forwards and
        // listeners live until app quit (review finding Codex #4).
        for pane in session.panes {
            discardSurface(for: pane.id)
            discardCommandBridgeRecoveryRecord(for: pane.terminalSessionID)
            forgetBridgeAttachPreflight(for: pane.terminalSessionID)
            if let registry = bridgeGenerationRegistry {
                if let token = registry.currentToken(for: pane.terminalSessionID) {
                    Task { await registry.teardown(for: pane.terminalSessionID, ifToken: token) }
                } else {
                    Task { await registry.teardown(for: pane.terminalSessionID) }
                }
            }
        }
#if DEBUG
        logSurfaceCacheEvent(
            "discard-session-finish",
            sessionID: session.id,
            paneID: session.activePaneID
        )
#endif
    }

    func discardAllSurfaces() {
#if DEBUG
        logSurfaceCacheEvent("discard-all-start")
#endif
        agentRuntimeEventBridge.stopWatchingAll()
        for task in shellActivityLifecycleRefreshTasks.values {
            task.cancel()
        }
        shellActivityLifecycleRefreshTasks.removeAll()
        secureInputCoordinator.reset()
        for surfaceView in surfaceViews.values {
            surfaceView.disposeNativeSurface()
            surfaceView.removeFromSuperview()
        }

        surfaceViews.removeAll()
        commandBridgeRecoveryRecords.removeAll()
#if DEBUG
        logSurfaceCacheEvent("discard-all-finish")
#endif
    }

    /// True while no pane has spawned its native surface yet — the cold-launch
    /// window where the terminal-detail pane is still being laid out from a
    /// placeholder width toward its settled size. Every such pane (a restored
    /// split mounts several at once, before any has a surface) defers spawn until
    /// its width settles. Once any surface exists the layout is settled, so
    /// user-created panes spawn immediately at their real width.
    func isColdStartSurfacePhase() -> Bool {
        !surfaceViews.values.contains(where: \.hasNativeSurface)
    }

    func discardSurfacesNotIn(_ retainedPaneIDs: Set<TerminalPane.ID>) {
        let stalePaneIDs = surfaceViews.keys.filter { !retainedPaneIDs.contains($0) }
        guard !stalePaneIDs.isEmpty else {
            return
        }

#if DEBUG
        logSurfaceCacheEvent("discard-stale-start")
#endif
        for paneID in stalePaneIDs {
            discardSurface(for: paneID)
        }
#if DEBUG
        logSurfaceCacheEvent("discard-stale-finish")
#endif
    }

    func refreshTerminalQuitConfirmationRisks(in sessionStore: SessionStore) {
        let snapshots = surfaceViews.values.map { surfaceView in
            let needsConfirmation = surfaceView.promptMarkerIsAwayFromPrompt() ?? false
            return TerminalQuitConfirmationSnapshot(
                sessionID: surfaceView.sessionID,
                paneID: surfaceView.paneID,
                needsConfirmation: needsConfirmation,
                promptObserved: surfaceView.terminalPromptObserved,
                liveness: surfaceView.foregroundProcessLiveness()
            )
        }
        sessionStore.updateTerminalQuitConfirmationRisks(snapshots)
    }

    /// Throttled entry point for the passive per-surface sampler poll
    /// (`GhosttySurfaceNSView.visibleStateSamplingTask`). Event-driven callers
    /// (command submit/finish, surface creation) should call
    /// `refreshShellActivity` directly so their intentional timing is preserved.
    /// The throttle floor collapses N panes each polling on their own task into a
    /// single global sampling cadence.
    func sampleShellActivity(in sessionStore: SessionStore) {
        let now = ContinuousClock.now
        if let last = lastShellActivitySampleAt,
           now - last < Self.shellActivitySampleThrottle {
            return
        }
        lastShellActivitySampleAt = now
        refreshShellActivity(in: sessionStore)
        detectExitedAgents()
    }

    /// One visible pane's sampler tick sweeps EVERY cached surface (mirrors
    /// `refreshShellActivity`): a stale agent glyph is most visible on a
    /// background session's sidebar tile, whose own detached view isn't
    /// sampling. Each view applies the reset through its own session store,
    /// so floating-panel panes are covered too. The per-view `agentKind !=
    /// .shell` guard keeps the sweep cheap — only agent-tagged panes pay for
    /// the libproc probe.
    private func detectExitedAgents() {
        for surfaceView in surfaceViews.values {
            surfaceView.detectAgentExitedToShell()
        }
    }

    func refreshShellActivity(in sessionStore: SessionStore) {
        let snapshots = surfaceViews.values.compactMap { surfaceView in
            surfaceView.shellActivitySnapshot()
        }
        let hasPendingDebounce = sessionStore.updateShellActivity(snapshots)
        scheduleShellActivityDebounceRefreshIfNeeded(
            hasPendingDebounce,
            sessionStore: sessionStore
        )
    }

    /// Silent shell commands can flip the prompt marker after Return has been
    /// accepted without producing another draw, so one post-submit sample can
    /// miss the active window entirely.
    static let shellActivityCommandSubmitRefreshDelays: [TimeInterval] = [
        0.05,
        0.15,
        0.30,
        0.50,
        0.80
    ]

    static let shellActivityCommandFinishedRefreshDelays: [TimeInterval] = [
        0.05,
        0.15,
        0.30
    ]

    func scheduleShellActivityRefreshAfterCommandSubmit(
        for paneID: TerminalPane.ID,
        in sessionStore: SessionStore
    ) {
        scheduleShellActivityLifecycleRefresh(
            for: paneID,
            in: sessionStore,
            delays: Self.shellActivityCommandSubmitRefreshDelays
        )
    }

    func scheduleShellActivityRefreshAfterCommandFinished(
        for paneID: TerminalPane.ID,
        in sessionStore: SessionStore
    ) {
        scheduleShellActivityLifecycleRefresh(
            for: paneID,
            in: sessionStore,
            delays: Self.shellActivityCommandFinishedRefreshDelays
        )
    }

    private func scheduleShellActivityLifecycleRefresh(
        for paneID: TerminalPane.ID,
        in sessionStore: SessionStore,
        delays: [TimeInterval]
    ) {
        // Cancel only THIS pane's prior ladder, not every pane's.
        shellActivityLifecycleRefreshTasks[paneID]?.cancel()
        shellActivityLifecycleRefreshTasks[paneID] = Task {
            @MainActor [weak self, weak sessionStore] in
            var elapsed: TimeInterval = 0
            for delay in delays {
                let sleepDelay = max(0, delay - elapsed)
                if sleepDelay > 0 {
                    try? await Task.sleep(for: .seconds(sleepDelay))
                }
                guard !Task.isCancelled,
                      let self,
                      let sessionStore else {
                    return
                }

                self.refreshShellActivity(in: sessionStore)
                elapsed = delay
            }
            // Safe only because there is no suspension point between the final
            // refresh and this line: a replacement schedule cancels this task,
            // so a cancelled task returns at the guard above and never reaches
            // here — it can only ever clear its own (current) entry. If you add
            // an `await` after the loop, re-check this for a clobber race.
            self?.shellActivityLifecycleRefreshTasks[paneID] = nil
        }
    }

    func scheduleShellActivityRefresh(
        in sessionStore: SessionStore,
        after delay: TimeInterval
    ) {
        shellActivityDebounceRefreshTask?.cancel()
        shellActivityDebounceRefreshTask = Task { @MainActor [weak self, weak sessionStore] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  let sessionStore else {
                return
            }

            self.refreshShellActivity(in: sessionStore)
        }
    }

    private func scheduleShellActivityDebounceRefreshIfNeeded(
        _ hasPendingDebounce: Bool,
        sessionStore: SessionStore
    ) {
        shellActivityDebounceRefreshTask?.cancel()
        guard hasPendingDebounce else {
            shellActivityDebounceRefreshTask = nil
            return
        }

        let delay = max(
            SessionStore.shellActivityBusyDebounceInterval,
            SessionStore.shellActivityIdleDebounceInterval
        )
        scheduleShellActivityRefresh(in: sessionStore, after: delay)
    }

    func applyTerminalAppearance(_ preferences: TerminalAppearancePreferences) {
        guard let app else {
#if DEBUG
            Self.logger.debug("applyTerminalAppearance skipped: app not initialized")
#endif
            return
        }
        guard let config = makeGhosttyConfig(
            terminalAppearance: preferences,
            reportFailures: false
        ) else {
#if DEBUG
            Self.logger.debug("applyTerminalAppearance skipped: config build returned nil")
#endif
            return
        }

        defer { ghostty_config_free(config) }
        logTerminalDiagnosticsAppearance(
            event: "runtime-apply-appearance",
            preferences: preferences
        )
        ghostty_app_update_config(app, config)
        for surfaceView in surfaceViews.values {
            surfaceView.applyTerminalBackstopBackgroundColor()
        }
        applyTerminalColorScheme(preferences.terminalColorScheme)
    }

    func applyTerminalSettings() {
        guard let app else {
#if DEBUG
            Self.logger.debug("applyTerminalSettings skipped: app not initialized")
#endif
            return
        }
        guard let config = makeGhosttyConfig(
            terminalAppearance: terminalAppearanceProvider(),
            reportFailures: false
        ) else {
#if DEBUG
            Self.logger.debug("applyTerminalSettings skipped: config build returned nil")
#endif
            return
        }

        defer { ghostty_config_free(config) }
        ghostty_app_update_config(app, config)
    }

    func resolvedTerminalBackgroundHex() -> String {
        let terminalAppearance = terminalAppearanceProvider()
        return terminalAppearance.ghosttyBackgroundColor
            ?? terminalAppearance.terminalThemeProvider.background(
                for: terminalAppearance.effectiveTheme
            )
    }

    func configureOutputMarksAttentionProvider(
        _ provider: @escaping @MainActor () -> Bool
    ) {
        outputMarksAttentionProvider = provider
    }

    func configureClipboardWritePolicyProvider(
        _ provider: @escaping @MainActor () -> TerminalConfig.ClipboardWritePolicy
    ) {
        clipboardWritePolicyProvider = provider
    }

    func configureConfirmClipboardReadProvider(
        _ provider: @escaping @MainActor () -> Bool
    ) {
        confirmClipboardReadProvider = provider
    }

    func configureCopyOnSelectProvider(
        _ provider: @escaping @MainActor () -> TerminalConfig.CopyOnSelect
    ) {
        copyOnSelectProvider = provider
    }

    func configureCommandBridgeEnabledProvider(
        _ provider: @escaping @MainActor () -> Bool
    ) {
        commandBridgeEnabledProvider = provider
    }

    /// Live agent-integrations settings, read off the SwiftUI store the same way
    /// `commandBridgeEnabledProvider` reads the command-bridge toggle. Feeds both
    /// the bridge enable gate (`isBridgeChromeEnabled`) and the per-event consent
    /// the read-model adapter evaluates at apply time (never a spawn-time snapshot).
    func configureAgentIntegrationsProvider(
        _ provider: @escaping @MainActor () -> AgentIntegrationsConfig
    ) {
        agentIntegrationsProvider = provider
    }

    @MainActor
    var agentIntegrations: AgentIntegrationsConfig {
        agentIntegrationsProvider()
    }

    /// The bridge enable gate's agent-chrome half (contributor ruling): the master
    /// agent-integrations switch is on — any provider enabled.
    @MainActor
    var isBridgeChromeEnabled: Bool {
        agentIntegrations.anyProviderEnabled
    }

    /// The long-lived attach preflight for a remote bridge session, created on
    /// first attach and reused across every reattach (its `current` listener is
    /// the make-before-break handle). Built with the session-bound `makeListener`
    /// that stands up the supervisor/coordinator trio — the seam D2's placeholder
    /// deliberately left unwired.
    @MainActor
    func bridgeAttachPreflight(
        for session: TerminalSessionID,
        paneID: TerminalPane.ID,
        workspaceSessionID: TerminalSession.ID,
        sessionStore: SessionStore
    ) -> BridgeAttachPreflight {
        if let existing = bridgeAttachPreflights[session] {
            return existing
        }
        let preflight = BridgeAttachPreflight(
            ledger: bridgeSocketLedger,
            makeListener: makeBridgeListener(
                paneID: paneID,
                workspaceSessionID: workspaceSessionID,
                sessionStore: sessionStore
            )
        )
        bridgeAttachPreflights[session] = preflight
        return preflight
    }

    /// Drops a session's preflight on genuine close / re-point. The ledger and any
    /// live generation are torn down separately (the registry); this just stops a
    /// dead session's preflight from lingering for the app's lifetime.
    @MainActor
    func forgetBridgeAttachPreflight(for session: TerminalSessionID) {
        bridgeAttachPreflights.removeValue(forKey: session)
    }

    /// Registers the closure that `openURL` calls when it detects a
    /// `file://*.md` link. `AppDelegate.bind` wires this to
    /// `sessionStore.openDocumentPane(fileURL:in:)` so the link opens
    /// in the active session without the runtime holding a direct store reference.
    /// Pass `nil` to clear the handler (e.g. on teardown).
    @MainActor
    func configureOpenDocumentHandler(_ handler: (@MainActor (URL) -> Void)?) {
        Self.setOpenDocumentHandler(handler)
    }

    /// Resolved at the moment the bell action handler decides whether
    /// to mark needs-attention. Exposed as a read-only main-actor
    /// property so the static C-callback can route through the surface
    /// view's runtime ref without bridging a `self` capture into the
    /// nonisolated callback.
    @MainActor
    var shouldOutputMarkAttention: Bool {
        outputMarksAttentionProvider()
    }

    @MainActor
    var clipboardWritePolicy: TerminalConfig.ClipboardWritePolicy {
        clipboardWritePolicyProvider()
    }

    @MainActor
    var shouldConfirmClipboardRead: Bool {
        confirmClipboardReadProvider()
    }

    @MainActor
    var isCommandBridgeEnabled: Bool {
        commandBridgeEnabledProvider()
    }

    func createSurface(
        attachedTo view: NSView,
        workingDirectory: String?,
        environment: [String: String],
        command: String? = nil
    ) -> ghostty_surface_t? {
        guard let app else {
            return nil
        }

        let validatedWorkingDirectory = workingDirectory.flatMap {
            WorkingDirectoryValidator.validatedStartupDirectory($0)
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
        )
        guard let surfaceView = view as? GhosttySurfaceNSView else {
            return nil
        }
        let retainedUserdata = Unmanaged.passRetained(surfaceView).toOpaque()
        surfaceConfig.userdata = retainedUserdata
        surfaceConfig.scale_factor = Double(view.window?.screen?.backingScaleFactor
            ?? view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2)
        let terminalAppearance = terminalAppearanceProvider()
        surfaceConfig.font_size = terminalAppearance.ghosttyFontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Pass awesoMux's own process environment as the inherited base so the
        // UTF-8 ctype fallback can tell whether the child shell would otherwise
        // land in the C locale (libghostty spawns the shell from this process'
        // environment, then merges the dict we return on top).
        let surfaceEnvironment = terminalAppearance.environmentForTerminalSpawn(
            merging: environment,
            inheritedEnvironment: ProcessInfo.processInfo.environment
        )
        logTerminalDiagnosticsSurfaceSpawn(
            terminalAppearance: terminalAppearance,
            environment: surfaceEnvironment
        )
        var environmentKeys: [UnsafeMutablePointer<CChar>] = []
        var environmentValues: [UnsafeMutablePointer<CChar>] = []
        // Sort by key so the env-var array order is deterministic across
        // process launches. Swift dictionaries hash-randomize per process,
        // and a stable order makes diagnostic logs diffable when chasing
        // env-leak regressions (the class of bug this PR addresses).
        let sortedEnvironment = surfaceEnvironment.sorted { $0.key < $1.key }
        for variable in sortedEnvironment {
            guard let key = strdup(variable.key) else {
                continue
            }
            guard let value = strdup(variable.value) else {
                free(key)
                continue
            }
            environmentKeys.append(key)
            environmentValues.append(value)
        }
        defer {
            for key in environmentKeys {
                free(key)
            }
            for value in environmentValues {
                free(value)
            }
        }
        var environmentVariables = environmentKeys.indices.map { index in
            ghostty_env_var_s(
                key: UnsafePointer(environmentKeys[index]),
                value: UnsafePointer(environmentValues[index])
            )
        }

        // libghostty copies `command` synchronously inside `ghostty_surface_new`,
        // matching the working-directory lifetime invariant below.
        var commandCString: UnsafeMutablePointer<CChar>?
        if let command, command.range(of: "\0") == nil {
            commandCString = strdup(command)
            surfaceConfig.command = UnsafePointer(commandCString)
        }
        defer {
            if let commandCString {
                free(commandCString)
            }
        }

        let createConfiguredSurface: () -> ghostty_surface_t? = {
            if let validatedWorkingDirectory,
               validatedWorkingDirectory.range(of: "\0") == nil {
                // `withCString` only keeps the C buffer alive for the duration
                // of the closure. That's sufficient because libghostty copies
                // the path into its own storage synchronously inside
                // `ghostty_surface_new` — see `alloc.dupeZ(u8, cwd)` in
                // `vendor/ghostty/src/termio/Exec.zig` (Subprocess.init,
                // around the "We have to copy the cwd..." comment), reached
                // synchronously via Surface.init → termio.Exec.init →
                // Subprocess.init. INT-26 has the full trace.
                //
                // This invariant depends on that whole chain staying
                // synchronous. If upstream ever defers subprocess setup
                // (lazy spawn, async surface init), revisit: we'd need an
                // owned C buffer tied to the surface lifetime, freed in
                // `discardSurface`.
                return validatedWorkingDirectory.withCString { cWorkingDirectory in
                    surfaceConfig.working_directory = cWorkingDirectory
                    return ghostty_surface_new(app, &surfaceConfig)
                }
            }

            return ghostty_surface_new(app, &surfaceConfig)
        }

        var createdSurface: ghostty_surface_t?
        defer {
            if createdSurface == nil {
                Unmanaged<GhosttySurfaceNSView>
                    .fromOpaque(retainedUserdata)
                    .release()
            }
        }

        guard !environmentVariables.isEmpty else {
            createdSurface = createConfiguredSurface()
            return createdSurface
        }

        return environmentVariables.withUnsafeMutableBufferPointer { buffer in
            surfaceConfig.env_vars = buffer.baseAddress
            surfaceConfig.env_var_count = buffer.count
            createdSurface = createConfiguredSurface()
            return createdSurface
        }
    }

    func agentRuntimeEnvironment(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        enabledFileDropSources: Set<AgentRuntimeSource>,
        applyEvent: @escaping (AgentRuntimeEvent) -> Void
    ) -> AgentRuntimeEnvironment {
        agentRuntimeEventBridge.environment(
            sessionID: sessionID,
            paneID: paneID,
            enabledFileDropSources: enabledFileDropSources,
            applyEvent: applyEvent
        )
    }

    func freeSurface(_ surface: ghostty_surface_t) {
#if DEBUG
        let surfaceAddress = UInt(bitPattern: UnsafeRawPointer(surface))
        assert(
            surfacesBeingFreed.insert(surfaceAddress).inserted,
            "native Ghostty surface freed more than once"
        )
        defer { surfacesBeingFreed.remove(surfaceAddress) }
#endif
        let userdata = ghostty_surface_userdata(surface)
        ghostty_surface_free(surface)
        if let userdata {
            Unmanaged<GhosttySurfaceNSView>
                .fromOpaque(userdata)
                .release()
        }
    }

    init(
        terminalAppearanceProvider: @escaping @MainActor () -> TerminalAppearancePreferences = {
            .defaultValue
        },
        initialClipboardWritePolicy: TerminalConfig.ClipboardWritePolicy = .ask,
        initialConfirmClipboardRead: Bool = true,
        initialCopyOnSelect: TerminalConfig.CopyOnSelect = .inherit,
        initialCommandBridgeEnabled: Bool = false,
        diagnosticEventHandler: @escaping (LocalDiagnosticEventInput) -> Void = { _ in }
    ) {
        self.terminalAppearanceProvider = terminalAppearanceProvider
        self.diagnosticEventHandler = diagnosticEventHandler
        self.agentRuntimeEventBridge = AgentRuntimeEventBridge(
            diagnosticEventHandler: diagnosticEventHandler
        )
        clipboardWritePolicyProvider = { initialClipboardWritePolicy }
        confirmClipboardReadProvider = { initialConfirmClipboardRead }
        copyOnSelectProvider = { initialCopyOnSelect }
        commandBridgeEnabledProvider = { initialCommandBridgeEnabled }
        // The generation registry shares the one per-runtime ledger. Built here
        // (not left nil for D4 to assign) so the discard/quit teardown hooks are
        // live from construction; both no-op while no generation is registered.
        bridgeGenerationRegistry = BridgeGenerationRegistry(ledger: bridgeSocketLedger)
        initialize()
    }

    deinit {
        // GhosttyRuntime is owned by AwesoMuxApp's @State and consumed
        // through @Environment, both of which release on the main
        // thread. If a future libghostty callback retains the runtime
        // opaque and releases it off-main, the previous
        // `DispatchQueue.main.sync` hop could deadlock — if the
        // background thread is itself blocking the main queue (mid-
        // async execution, holding a lock the main queue is waiting
        // on) the sync would hang the process.
        //
        // Trap loudly instead: dispatchPrecondition crashes with a
        // clear stack so we get a useful crash report rather than a
        // silent hang. If this ever fires, the fix is to make the
        // off-main retain path use an explicit shutdown() method
        // before releasing the last reference, not to layer more
        // deadlock-prone hops here.
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            unregisterApplicationInputObservers()
            eventLoopWatchdog?.stop()
            shellActivityDebounceRefreshTask?.cancel()
            for task in shellActivityLifecycleRefreshTasks.values {
                task.cancel()
            }
            shellActivityLifecycleRefreshTasks.removeAll()
            performanceSampler.stop()
            discardAllSurfaces()
        }

        if let app {
            ghostty_app_free(app)
        }

        if let config {
            ghostty_config_free(config)
        }
    }

    func tick() {
        guard let app else {
            return
        }

        ghostty_app_tick(app)
        eventLoopWatchdog?.recordTick()
    }

    func reload() {
#if DEBUG
        logSurfaceCacheEvent("reload-start")
#endif
        performanceSampler.stop()
        eventLoopWatchdog?.stop()
        eventLoopWatchdog = nil
        discardAllSurfaces()
        unregisterApplicationInputObservers()
        // Clear the document handler on reload so a stale closure can't route
        // file:// links to a store that no longer matches the new runtime state.
        Self.setOpenDocumentHandler(nil)

        if let app {
            ghostty_app_free(app)
            self.app = nil
        }

        if let config {
            ghostty_config_free(config)
            self.config = nil
        }

        readiness = .uninitialized
        errorMessage = nil
        initialize()
#if DEBUG
        logSurfaceCacheEvent("reload-finish")
#endif
    }

    private func initialize() {
        guard Self.initializeProcess() else {
            fail("ghostty_init failed")
            return
        }

        let terminalAppearance = terminalAppearanceProvider()
        logTerminalDiagnosticsAppearance(
            event: "runtime-initialize",
            preferences: terminalAppearance
        )
        guard let config = makeGhosttyConfig(
            terminalAppearance: terminalAppearance,
            reportFailures: true
        ) else {
            return
        }

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: awesoMuxGhosttyWakeup,
            action_cb: awesoMuxGhosttyAction,
            read_clipboard_cb: awesoMuxGhosttyReadClipboard,
            confirm_read_clipboard_cb: awesoMuxGhosttyConfirmReadClipboard,
            write_clipboard_cb: awesoMuxGhosttyWriteClipboard,
            close_surface_cb: awesoMuxGhosttyCloseSurface
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            fail("ghostty_app_new failed")
            return
        }

        self.config = config
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        registerApplicationInputObservers()
        // Applies the color scheme to the `app` handle now. The
        // `surfaceViews` loop inside `applyTerminalColorScheme` is a no-op
        // on first init because no surface can exist until `readiness`
        // flips to `.ready` below — keep this call ahead of the readiness
        // change so the app handle always has a scheme set before the
        // first surface spawns.
        applyTerminalColorScheme(terminalAppearance.terminalColorScheme)
        readiness = .ready
        eventLoopWatchdog = GhosttyEventLoopWatchdog(
            faultSource: eventLoopFaultSource
        ) { [weak self] in
            self?.presentEventLoopWedgeAlert()
        }
        eventLoopWatchdog?.start()
        diagnosticEventHandler(hasCompletedInitialization ? .terminalReloaded : .terminalReady)
        hasCompletedInitialization = true
        logConfigEnvironmentOnce()
        performanceSampler.startIfRequested { [weak self] in
            self?.surfaceViews.count ?? -1
        }
    }

    private func registerApplicationInputObservers() {
        unregisterApplicationInputObservers()

        let center = NotificationCenter.default
        applicationInputObserverTokens = [
            center.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyboardSelectionDidChange()
                }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidBecomeActive()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidResignActive()
                }
            },
        ]
    }

    private func unregisterApplicationInputObservers() {
        guard !applicationInputObserverTokens.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        for token in applicationInputObserverTokens {
            center.removeObserver(token)
        }
        applicationInputObserverTokens.removeAll()
    }

    private func applicationDidBecomeActive() {
        guard let app else {
            return
        }

        ghostty_app_set_focus(app, true)
    }

    private func applicationDidResignActive() {
        guard let app else {
            return
        }

        ghostty_app_set_focus(app, false)
    }

    private func keyboardSelectionDidChange() {
        guard let app else {
            return
        }

        ghostty_app_keyboard_changed(app)
    }

    // Emitted once per process lifetime so per-capture interpretation
    // (INT-397) can record which side of the user-config override the
    // run was on without DEBUG-only diagnostics. `reload()` calls
    // `initialize()` again; we deliberately do NOT re-snapshot on
    // reload — capture protocols treat this line as a startup-only
    // marker. If user-config existence changes mid-session (rare), the
    // operator should relaunch awesoMux before the next capture rather
    // than rely on a stale log line. Trading per-reload log spam for a
    // possibly-stale field is the conscious choice; keep the guard.
    private func logConfigEnvironmentOnce() {
        guard !Self.didLogConfigEnvironment else { return }
        Self.didLogConfigEnvironment = true
        let env = GhosttyConfigEnvironment.snapshot()
        Self.configEnvironmentLogger.info(
            "ghostty-config-env \(env.logFields, privacy: .public)"
        )
    }

    /// Builds a finalized libghostty config via `GhosttyConfigManager`, applying
    /// the side effects the manager deliberately leaves to the coordinator:
    /// adopting the resolved background color (kept untouched when the config
    /// omits the key) and, on init, failing the runtime with the manager's
    /// verbatim message. Ownership of the returned config transfers to the caller.
    private func makeGhosttyConfig(
        terminalAppearance: TerminalAppearancePreferences,
        reportFailures: Bool
    ) -> ghostty_config_t? {
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: clipboardWritePolicyProvider(),
            confirmClipboardRead: confirmClipboardReadProvider(),
            copyOnSelect: copyOnSelectProvider(),
            terminalAppearance: terminalAppearance
        )
        switch manager.build(reportFailures: reportFailures) {
        case let .built(config, backgroundColor):
            if let backgroundColor {
                terminalBackgroundColor = backgroundColor
            }
            logMenuBindingCollisionsIfAny(config: config)
            return config
        case let .failed(message):
            fail(message)
            return nil
        case .abandonedSilently:
            return nil
        }
    }

    private func fail(_ message: String) {
        readiness = .failed
        errorMessage = message
        diagnosticEventHandler(.terminalFailed)
    }

    /// Compares awesoMux's ~25 CommandGroup menu shortcuts against
    /// currently-configured libghostty bindings. They're deliberately
    /// disjoint today (INT-589) — this only warns on future collisions,
    /// it does not change dispatch order (reordering would break every
    /// existing menu shortcut, since they're outside libghostty's binding
    /// config by design).
    ///
    /// `isConfiguredBinding` is injected so tests can stub it without a real
    /// `ghostty_config_t`; the production call site wires
    /// `ghostty_config_key_is_binding`.
    nonisolated static func detectMenuBindingCollisions(
        catalogBindings: [KeyBinding],
        isConfiguredBinding: (KeyBinding) -> Bool
    ) -> [String] {
        catalogBindings.filter(isConfiguredBinding).map { binding in
            "\(binding.action) (\(binding.displaySymbol))"
        }
    }

    // Ponytail note: this covers only KeyboardShortcutCatalog's current
    // punctuation/arrow characters, not a full US or non-US keyboard layout.
    // Extend it when the catalog grows.
    // `internal` (not private) so the table's entries are unit-testable.
    nonisolated static let catalogPhysicalKeyCodes: [Character: UInt32] = [
        "[": UInt32(kVK_ANSI_LeftBracket),
        "]": UInt32(kVK_ANSI_RightBracket),
        "=": UInt32(kVK_ANSI_Equal),
        "-": UInt32(kVK_ANSI_Minus),
        "'": UInt32(kVK_ANSI_Quote),
        "\\": UInt32(kVK_ANSI_Backslash),
        KeyEquivalent.upArrow.character: UInt32(kVK_UpArrow),
        KeyEquivalent.downArrow.character: UInt32(kVK_DownArrow),
        KeyEquivalent.leftArrow.character: UInt32(kVK_LeftArrow),
        KeyEquivalent.rightArrow.character: UInt32(kVK_RightArrow),
    ]

    /// Builds a `ghostty_input_key_s` from each catalog `KeyBinding` and asks
    /// libghostty whether it already owns that chord as a binding, logging
    /// any hits (de-duped against `lastLoggedCollisions` — see
    /// `shouldLogCollisions`). The diagnostic populates the macOS hardware
    /// keycode for KeyboardShortcutCatalog's current punctuation/arrow entries
    /// so libghostty can match both literal-character and physical-key config
    /// triggers. `.text` and `.unshifted_codepoint` still come from the
    /// catalog's base/unshifted `KeyBinding.character` (shift is carried
    /// separately in `.modifiers`), not a real keyboard layout's shifted
    /// output — an unusual layout could theoretically still diverge, but
    /// that's an accepted limit of this diagnostic.
    private func logMenuBindingCollisionsIfAny(config: ghostty_config_t) {
        let collisions = Self.detectMenuBindingCollisions(
            catalogBindings: KeyboardShortcutCatalog.allBindings()
        ) { binding in
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.mods = GhosttyInputMapper.modifiers(binding.modifiers.toNSEventModifierFlags())
            keyEvent.unshifted_codepoint = UInt32(binding.key.character.unicodeScalars.first?.value ?? 0)
            if let keycode = Self.catalogPhysicalKeyCodes[binding.key.character] {
                keyEvent.keycode = keycode
            }
            return String(binding.key.character).withCString { ptr in
                keyEvent.text = ptr
                return ghostty_config_key_is_binding(config, keyEvent)
            }
        }
        let collisionSet = Set(collisions)
        defer { Self.lastLoggedCollisions = collisionSet }
        guard Self.shouldLogCollisions(collisionSet, lastLogged: Self.lastLoggedCollisions) else { return }
        Self.configEnvironmentLogger.warning(
            "possible menu-binding collision (assumes US ANSI layout) for: \(collisions.joined(separator: ", "), privacy: .public)"
        )
    }

    /// Pure de-dupe decision, split out from `logMenuBindingCollisionsIfAny`
    /// so it's testable without a real `ghostty_config_t`: should
    /// `newCollisions` produce a new warning log, given what was logged last
    /// time? A no-collision result never logs (nothing to warn about); a
    /// repeat of the same non-empty set is treated as already-reported.
    nonisolated static func shouldLogCollisions(
        _ newCollisions: Set<String>,
        lastLogged: Set<String>
    ) -> Bool {
        !newCollisions.isEmpty && newCollisions != lastLogged
    }

    /// Ghostty may emit app/window/workspace actions from user keybindings.
    /// awesoMux owns those commands through SwiftUI menus, the command palette,
    /// and `KeyboardShortcutCatalog`; known Ghostty application actions are
    /// claimed here so libghostty treats them as handled, but they do not become
    /// a parallel command surface. Terminal-surface callbacks that need bridge
    /// integration stay in `action(_:,target:action:)`.
    nonisolated static func shouldClaimIgnoredGhosttyApplicationAction(
        _ tag: ghostty_action_tag_e
    ) -> Bool {
        switch tag {
        case GHOSTTY_ACTION_QUIT,
             GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
             GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
             GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
             GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
             GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
             GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
             GHOSTTY_ACTION_TOGGLE_VISIBILITY,
             GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
             GHOSTTY_ACTION_MOVE_TAB,
             GHOSTTY_ACTION_GOTO_TAB,
             GHOSTTY_ACTION_GOTO_SPLIT,
             GHOSTTY_ACTION_GOTO_WINDOW,
             GHOSTTY_ACTION_RESIZE_SPLIT,
             GHOSTTY_ACTION_EQUALIZE_SPLITS,
             GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
             GHOSTTY_ACTION_PRESENT_TERMINAL,
             GHOSTTY_ACTION_RESET_WINDOW_SIZE,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_INSPECTOR,
             GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
             GHOSTTY_ACTION_RENDER_INSPECTOR,
             GHOSTTY_ACTION_OPEN_CONFIG,
             GHOSTTY_ACTION_RELOAD_CONFIG,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_CLOSE_WINDOW,
             GHOSTTY_ACTION_FLOAT_WINDOW,
             GHOSTTY_ACTION_UNDO,
             GHOSTTY_ACTION_REDO,
             GHOSTTY_ACTION_CHECK_FOR_UPDATES,
             GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
             GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            return true
        default:
            return false
        }
    }

    private func applyTerminalColorScheme(
        _ colorScheme: TerminalAppearancePreferences.TerminalColorScheme
    ) {
        guard let app else {
            return
        }

        let ghosttyColorScheme = Self.ghosttyColorScheme(for: colorScheme)
        logTerminalDiagnosticsColorScheme(
            target: "app-and-surfaces",
            colorScheme: colorScheme,
            surfaceCount: surfaceViews.count
        )
        ghostty_app_set_color_scheme(app, ghosttyColorScheme)
        for surfaceView in surfaceViews.values {
            surfaceView.applyTerminalColorScheme(ghosttyColorScheme)
        }
    }

    private func logTerminalDiagnosticsAppearance(
        event: String,
        preferences: TerminalAppearancePreferences
    ) {
        guard Self.terminalDiagnosticsEnabled else { return }

        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=\(event, privacy: .public) \
            \(preferences.diagnosticSummary.logFields, privacy: .public)
            """
        )
    }

    private func logTerminalDiagnosticsSurfaceSpawn(
        terminalAppearance: TerminalAppearancePreferences,
        environment: [String: String]
    ) {
        guard Self.terminalDiagnosticsEnabled else { return }

        let environmentSnapshot = TerminalDiagnosticEnvironmentSnapshot(environment: environment)
        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=surface-spawn \
            \(terminalAppearance.diagnosticSummary.logFields, privacy: .public) \
            \(environmentSnapshot.logFields, privacy: .public)
            """
        )
    }

    private func logTerminalDiagnosticsColorScheme(
        target: String,
        colorScheme: TerminalAppearancePreferences.TerminalColorScheme,
        surfaceCount: Int
    ) {
        guard Self.terminalDiagnosticsEnabled else { return }

        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=color-scheme-apply \
            target=\(target, privacy: .public) \
            scheme=\(Self.logValue(for: colorScheme), privacy: .public) \
            surface_count=\(surfaceCount, privacy: .public)
            """
        )
    }

    private static func logValue(
        for colorScheme: TerminalAppearancePreferences.TerminalColorScheme
    ) -> String {
        switch colorScheme {
        case .light: "light"
        case .dark: "dark"
        }
    }

    private static func ghosttyColorScheme(
        for colorScheme: TerminalAppearancePreferences.TerminalColorScheme
    ) -> ghostty_color_scheme_e {
        switch colorScheme {
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        }
    }

#if DEBUG
    private struct MemorySnapshot {
        let residentBytes: UInt64
        let physFootprintBytes: UInt64
    }

    private func logSurfaceCacheEvent(
        _ event: String,
        sessionID: TerminalSession.ID? = nil,
        paneID: TerminalPane.ID? = nil
    ) {
        let session = sessionID?.uuidString ?? "-"
        let pane = paneID?.uuidString ?? "-"
        let memory = Self.currentMemorySnapshot()
        let snapshotOK = memory != nil

        Self.logger.debug(
            """
            surface-cache event=\(event, privacy: .public) \
            session=\(session, privacy: .public) \
            pane=\(pane, privacy: .public) \
            surfaces=\(self.surfaceViews.count, privacy: .public) \
            snapshot_ok=\(snapshotOK, privacy: .public) \
            resident_bytes=\(memory?.residentBytes ?? 0, privacy: .public) \
            phys_footprint_bytes=\(memory?.physFootprintBytes ?? 0, privacy: .public)
            """
        )
    }

    private static func currentMemorySnapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return MemorySnapshot(
            residentBytes: UInt64(info.resident_size),
            physFootprintBytes: UInt64(info.phys_footprint)
        )
    }
#endif

    // `internal` (not `private`) so `@testable` tests that need libghostty
    // initialized — `ghostty_config_new` segfaults otherwise — can run the
    // process-wide latch directly instead of constructing and discarding a
    // whole runtime just for the side effect. Idempotent.
    @discardableResult
    @MainActor
    static func initializeProcess() -> Bool {
        guard !didInitializeProcess else {
            return true
        }

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        didInitializeProcess = result == GHOSTTY_SUCCESS
        return didInitializeProcess
    }

}
extension GhosttyRuntime {
    // ponytail: minimal recovery action is reload() (full "start over"),
    // not a session-preserving relaunch — see plan Task 8 context note.
    // ponytail: this watchdog only detects wedges where wakeups stop but
    // the main thread stays responsive enough to run its own timer — a
    // wedge that blocks the main thread itself (the original #562
    // system-freeze) is undetectable here. reload()'s efficacy against a
    // genuine libxev wedge is also unverified (no safe way to test without
    // deliberately reproducing a system freeze).
    static let eventLoopWedgeAlertBody = String(
        localized: "awesoMux's terminal engine has stopped responding. Restarting it will reload all open panes.",
        comment: "Body text for the alert offering to recover from a wedged terminal event loop"
    )

    func presentEventLoopWedgeAlert() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Terminal Engine Unresponsive",
            comment: "Title for the alert offering to recover from a wedged terminal event loop"
        )
        alert.informativeText = Self.eventLoopWedgeAlertBody
        alert.addButton(withTitle: String(
            localized: "Restart Terminal Engine",
            comment: "Button: recover from a wedged terminal event loop by reloading it"
        ))
        alert.addButton(withTitle: String(
            localized: "Not Now",
            comment: "Button: dismiss the wedged terminal event loop alert without acting"
        ))
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            reload()
        }
    }
}
