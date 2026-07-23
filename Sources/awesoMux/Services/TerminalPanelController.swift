import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import Observation
import SwiftUI
#if DEBUG
import os
#endif

@MainActor
@Observable
final class TerminalPanelController {
    private(set) var presentation: PopUpTerminalPresentation = .closed

    @ObservationIgnored private var store: SessionStore?
    @ObservationIgnored private var panel: TerminalPanelWindow?
    @ObservationIgnored private var cornerTab: NSPanel?
    @ObservationIgnored private weak var parentWindow: NSWindow?
    @ObservationIgnored private weak var runtime: GhosttyRuntime?
    @ObservationIgnored private weak var mainSessionStore: SessionStore?
    @ObservationIgnored private weak var settingsStore: AppSettingsStore?
    @ObservationIgnored private var parentObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var panelObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingFocusWork: DispatchWorkItem?
    @ObservationIgnored private let sizeStore: TerminalPanelSizeStore
    @ObservationIgnored private var preferredExpandedSize: CGSize
    @ObservationIgnored private var liveResizeCapture = PopUpTerminalLiveResizeCapture()
    @ObservationIgnored private var bottomInset = AwSpacing.footerChrome
    @ObservationIgnored private let focusState = FloatingPanelFocusState()
    @ObservationIgnored private var transitionRevision: UInt64 = 0
    @ObservationIgnored private var cornerTabUserPositioned = false
    @ObservationIgnored private var panelUserPositioned = false
    @ObservationIgnored private var isConfirmingClose = false
    @ObservationIgnored private let mode: TerminalPanelMode

    #if DEBUG
    // Dedicated smoke-test subsystem, separate from the app's normal
    // logging, so `script/smoke-floating-rebind.sh` can assert the
    // per-workspace rebind fired without filtering on process id or the
    // dev/prod bundle id (INT-799).
    private static let smokeRebindLogger = Logger(subsystem: "com.awesomux.smoke", category: "terminal-panel")
    #endif

    // MARK: - Floating-mode state
    //
    // Populated only in floating mode (`slots != nil`); companion leaves these
    // dormant. Absorbed from the former floating panel controller so one
    // controller serves both invocation modes.

    /// Per-workspace slot bookkeeping. `nil` in companion mode (single app-wide
    /// store); non-nil in floating mode. Every floating helper guards on it.
    @ObservationIgnored private let slots: FloatingSlotBook?
    @ObservationIgnored private var dismissConfirmation = FloatingPanelDismissConfirmationState()
    @ObservationIgnored private var pendingDismissConfirmationResetWork: DispatchWorkItem?
    @ObservationIgnored private var pendingPromotionTask: Task<Void, Never>?
    @ObservationIgnored private var promotionInFlight: InFlightPromotion?
    /// Weak runtime cache for floating dismiss/teardown paths that receive no
    /// runtime parameter.
    @ObservationIgnored private weak var lastSeenRuntime: GhosttyRuntime?
    @ObservationIgnored private var lastParentWorkspaceTitle: String?
    /// Suppresses re-key announcements while the floating `show` posts its own.
    @ObservationIgnored private var isPresentingShow = false

    private(set) var promotedSessionID: TerminalSession.ID?
    private(set) var promotionPulseSessionID: TerminalSession.ID?
    /// Observable mirror of the slot book's backgrounded-work set, so the
    /// sidebar dot observes one controller. Fed from
    /// `slots.recomputeBackgroundedRunningWork` on every floating mutation path.
    private(set) var workspacesWithBackgroundedRunningWork: Set<TerminalSession.ID> = []

    init(mode: TerminalPanelMode = .companion, sizeStore: TerminalPanelSizeStore? = nil) {
        self.mode = mode
        // Companion owns one app-wide store; floating keeps one slot per
        // workspace via the book.
        self.slots = mode.persistsAcrossWorkspaces ? nil : FloatingSlotBook()
        self.sizeStore = sizeStore ?? TerminalPanelSizeStore(
            key: mode.sizeStoreKey,
            minimumSize: mode.minimumSize
        )
        // Per-display size is resolved when the panel is first built (screen
        // known); seed with the mode default until then.
        preferredExpandedSize = mode.defaultSize
    }

    nonisolated static func expandedOrigin(
        mode: TerminalPanelMode.Anchor,
        size: CGSize,
        reference: CGRect,
        screen: CGRect,
        bottomInset: CGFloat
    ) -> CGPoint {
        switch mode {
        case .bottomTrailing:
            return PopUpTerminalLayout.origin(
                for: size, referenceFrame: reference, screenFrame: screen, bottomInset: bottomInset
            )
        case .center:
            // Floating centers over the parent; fall back to the companion
            // edge origin only if centering can't resolve a frame (never here,
            // reference/screen are non-nil by construction).
            return FloatingPanelLayout.origin(
                panelSize: size, referenceFrame: reference, screenFrame: screen
            ) ?? PopUpTerminalLayout.origin(
                for: size, referenceFrame: reference, screenFrame: screen, bottomInset: bottomInset
            )
        }
    }

    /// Clamp a window origin so a window of `size` stays fully on `screen`.
    /// Shared by the user-dragged panel and the user-dragged corner tab so a
    /// display change can't strand either off-screen with no way to recover it.
    nonisolated static func clampedToScreen(origin: CGPoint, size: CGSize, screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
            y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        )
    }

    /// Pure display-change resize decision (INT-799 comment 2). A drag to
    /// another monitor sets `panelUserPositioned` *before* `didChangeScreen`
    /// fires, so the reload must NOT gate on it or the destination display's
    /// remembered size never loads. A live resize owns the size and short-
    /// circuits. A user-positioned panel keeps its dragged origin (clamped to
    /// the new screen) at the destination's remembered size; an anchored panel
    /// re-anchors as usual.
    enum DisplayChangeResize: Equatable {
        case skip                    // live resize in flight; leave size/frame
        case reanchor(size: CGSize)  // anchored; reanchorWindows applies the size
        case applyFrame(CGRect)      // user-positioned; new size at kept origin
    }

    nonisolated static func displayChangeResize(
        isResizing: Bool,
        userPositioned: Bool,
        storedSize: CGSize?,
        defaultSize: CGSize,
        currentOrigin: CGPoint,
        newScreenVisibleFrame: CGRect
    ) -> DisplayChangeResize {
        guard !isResizing else { return .skip }
        let size = storedSize ?? defaultSize
        guard userPositioned else { return .reanchor(size: size) }
        return .applyFrame(CGRect(
            origin: clampedToScreen(origin: currentOrigin, size: size, screen: newScreenVisibleFrame),
            size: size
        ))
    }

    private func currentSizeBucket(preferredScreen: NSScreen? = nil) -> String {
        // Floating never sets `parentWindow`, so the panel's own screen is the
        // only live display reference once it exists; `preferredScreen` covers
        // the floating pre-panel load where the parent window is the reference.
        let screenSize = preferredScreen?.frame.size
            ?? panel?.screen?.frame.size
            ?? parentWindow?.screen?.frame.size
            ?? NSScreen.main?.frame.size
            ?? CGSize(width: 1920, height: 1080)
        return TerminalPanelSizeStore.bucket(for: screenSize)
    }

    // Floating mode's smart-dismiss; companion never arms it
    // (`mode.interceptsBareEscape == false`).
    private func performEscapeDismiss() { dismiss(source: .escape) }

    isolated deinit {
        removeParentObservers()
        removePanelObservers()
    }

    var isVisible: Bool { presentation != .closed }
    var isExpanded: Bool { presentation == .expanded }
    var isMinimized: Bool { presentation == .minimized }
    var ownedWindow: NSWindow? { panel }
    /// Observable mirror of the expanded panel's key state, so menu titles can
    /// promise "Minimize" only when the toggle would actually minimize.
    var isPanelFocused: Bool { focusState.isKeyWindow }

    // MARK: - Slot-aggregating members
    //
    // In floating mode these aggregate every slot in the book; in companion mode
    // they read the single `store`. The three whose names collide with the
    // companion base MUST fork — inheriting the companion single-store body on a
    // floating instance would hide live floating surfaces from launch GC.

    var sessionsAtRiskOnQuit: [TerminalSession] {
        if let slots { return slots.allStores.flatMap(\.sessionsAtRiskOnQuit) }
        return store?.sessionsAtRiskOnQuit ?? []
    }

    var retainedPaneIDs: Set<TerminalPane.ID> {
        let stores = slots?.allStores ?? [store].compactMap { $0 }
        return Set(stores.flatMap { store in
            store.groups.flatMap { group in
                group.sessions.flatMap(\.layout.paneIDs)
            }
        })
    }

    func refreshTerminalQuitConfirmationRisks(using runtime: GhosttyRuntime) {
        if let slots {
            // INT-185: one shared `GhosttyRuntime` backs every floating slot, so
            // sampling per-store here used to resample the whole surface
            // dictionary once per slot (unbounded in floating-slot count).
            // Sample once, apply the same snapshot to every slot's store.
            let snapshots = runtime.currentTerminalQuitConfirmationSnapshots()
            for store in slots.allStores {
                store.updateTerminalQuitConfirmationRisks(snapshots)
            }
            // Preserve the dismiss-confirmation auto-reset + recompute the
            // former floating panel controller ran here.
            if dismissConfirmation.isPending,
               let id = slots.activeWorkspaceID,
               let store = slots.store(for: id),
               store.sessionsAtRiskOnClose().isEmpty {
                // Close-scoped to match the dismiss gate: a bridged pane away
                // from its prompt is quit-safe but close-risky, so the pending
                // confirmation must survive until the close risk clears too.
                resetDismissConfirmation()
            }
            slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
            workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
            return
        }
        guard let store else { return }
        runtime.refreshTerminalQuitConfirmationRisks(in: store)
    }

    /// Whether the slot targeted by `toggle()` / `show()` has running work
    /// backgrounded, including the no-workspace sentinel slot. A pure read of
    /// the cached mirror — same passive-TTL freshness the sidebar dot has.
    func hasBackgroundedRunningWork(for workspaceID: TerminalSession.ID?) -> Bool {
        workspacesWithBackgroundedRunningWork.contains(workspaceID ?? FloatingSlotBook.unattachedWorkspaceID)
    }

    func activeFloatingPaneID(for workspaceID: TerminalSession.ID?) -> TerminalPane.ID? {
        slots?.store(for: workspaceID ?? FloatingSlotBook.unattachedWorkspaceID)?.selectedSession?.activePaneID
    }

    /// Close-scoped variant (Task 8 consumer): does the floating slot for
    /// `workspaceID` hold sessions whose close-risk gate would fire?
    func hasRiskyFloatingSessionsOnClose(for workspaceID: TerminalSession.ID) -> Bool {
        guard let store = slots?.store(for: workspaceID) else { return false }
        lastSeenRuntime?.refreshTerminalQuitConfirmationRisks(in: store)
        return !store.sessionsAtRiskOnClose().isEmpty
    }

    /// The daemon identities living in `workspaceID`'s floating slot, if any.
    /// Call BEFORE `evictFloatingSlot` drops the store — a busy floating daemon
    /// is exempt from launch GC while busy, so missing it here orphans it.
    func floatingDaemonIDs(for workspaceID: TerminalSession.ID) -> [TerminalSessionID] {
        guard let store = slots?.store(for: workspaceID) else { return [] }
        var ids: [TerminalSessionID] = []
        for session in store.groups.flatMap(\.sessions) {
            session.layout.forEachPane { ids.append($0.terminalSessionID) }
        }
        return ids
    }

    func updateBottomInset(_ height: CGFloat) {
        guard height.isFinite, height >= 0, abs(bottomInset - height) > 0.25 else {
            return
        }
        bottomInset = height
        reanchorWindows()
    }

    func toggle(
        relativeTo parentWindow: NSWindow?,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore
    ) {
        if slots != nil {
            floatingToggle(
                relativeTo: parentWindow,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore
            )
            return
        }
        bind(
            parentWindow: parentWindow,
            sessionStore: sessionStore,
            runtime: ghosttyRuntime,
            settingsStore: appSettingsStore
        )
        let next: PopUpTerminalPresentation =
            presentation == .expanded && panel?.isKeyWindow == true ? .minimized : .expanded
        present(next, initialWorkspace: sessionStore.selectedSession)
    }

    func show(
        relativeTo parentWindow: NSWindow?,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore,
        announcement: SummonAnnouncement = .full
    ) {
        if slots != nil {
            floatingShow(
                relativeTo: parentWindow,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore,
                announcement: announcement
            )
            return
        }
        bind(
            parentWindow: parentWindow,
            sessionStore: sessionStore,
            runtime: ghosttyRuntime,
            settingsStore: appSettingsStore
        )
        present(.expanded, initialWorkspace: sessionStore.selectedSession)
    }

    @discardableResult
    func performCloseShortcut() -> Bool {
        guard presentation == .expanded else { return false }
        minimize()
        return true
    }

    func minimize() {
        guard presentation != .closed else { return }
        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        presentation = .minimized
        transition(from: panel, to: cornerTab)
        postAnnouncement(String(
            localized: "Terminal Companion minimized. Running work remains active.",
            comment: "VoiceOver announcement after minimizing the app-wide Terminal Companion."
        ))
    }

    func restore() {
        // The corner tab and dock entry points bypass the menu's sheet check,
        // so gate presentation here: summoning over a sheet or alert would
        // steal key from a modal flow.
        guard store != nil, !hasBlockingModalSession else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        presentation = .expanded
        transition(from: cornerTab, to: panel)
        panel?.makeKeyAndOrderFront(nil)
        if let panel { focusTerminalSurface(in: panel) }
        postAnnouncement(String(
            localized: "Terminal Companion restored and focused.",
            comment: "VoiceOver announcement after restoring the app-wide Terminal Companion."
        ))
    }

    func close() {
        guard let store else { return }
        runtime?.refreshTerminalQuitConfirmationRisks(in: store)
        // Close-scoped risk, not quit-scoped: companion panes are bridged, and
        // the quit policy calls bridged authoritatively safe (daemon survives a
        // quit) — but this close kills the daemon session too, so a bridged
        // pane away from its prompt must still confirm (INT-772 smoke).
        if !store.sessionsAtRiskOnClose().isEmpty {
            // runModal spins a nested runloop; parent geometry notifications
            // can fire mid-confirmation, so pause reanchoring until it ends.
            isConfirmingClose = true
            let confirmed = confirmClose()
            isConfirmingClose = false
            guard confirmed else { return }
        }
        close(discardSurfaces: true)
    }

    func tearDown() {
        transitionRevision &+= 1
        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        removeParentObservers()
        removePanelObservers()
        panel?.orderOut(nil)
        cornerTab?.orderOut(nil)
        detachWindowsFromParent()
        panel?.contentViewController = nil
        cornerTab?.contentViewController = nil
        panel = nil
        cornerTab = nil
        parentWindow = nil
        cornerTabUserPositioned = false
        panelUserPositioned = false
        presentation = .closed
        // Closing the primary window reads as "done" for an idle companion.
        // Only a shell with running work survives to be re-summoned; it stays
        // counted by the quit gate either way.
        if let store, let runtime {
            runtime.refreshTerminalQuitConfirmationRisks(in: store)
            if store.sessionsAtRiskOnClose().isEmpty {
                var daemonIDs: [TerminalSessionID] = []
                for session in store.groups.flatMap(\.sessions) {
                    session.layout.forEachPane { daemonIDs.append($0.terminalSessionID) }
                    runtime.discardSurfaces(for: session)
                }
                AmxBackend.killSessionsDetached(daemonIDs, context: "companion-teardown")
                self.store = nil
            }
        }
    }

    private func bind(
        parentWindow: NSWindow?,
        sessionStore: SessionStore,
        runtime: GhosttyRuntime,
        settingsStore: AppSettingsStore
    ) {
        self.runtime = runtime
        mainSessionStore = sessionStore
        self.settingsStore = settingsStore
        if self.parentWindow !== parentWindow {
            removeParentObservers()
            detachWindowsFromParent()
            self.parentWindow = parentWindow
            observeParentWindow(parentWindow)
        }
    }

    private func present(
        _ next: PopUpTerminalPresentation,
        initialWorkspace: TerminalSession?
    ) {
        if store == nil {
            store = PopUpTerminalStoreFactory.makeStore(
                selectedWorkspace: initialWorkspace,
                fallbackHome: WorkingDirectoryValidator.canonicalHomeDirectory
            )
        }
        ensureWindows()
        if next == .minimized {
            minimize()
        } else {
            restore()
        }
    }

    private func ensureWindows() {
        guard let store, let runtime, let settingsStore else { return }
        if panel == nil {
            preferredExpandedSize = sizeStore.load(bucket: currentSizeBucket())
                ?? PopUpTerminalLayout.defaultExpandedSize
            panel = makeExpandedPanel(store: store, runtime: runtime, settingsStore: settingsStore)
        }
        if mode.hasCornerTab, cornerTab == nil {
            cornerTab = makeCornerTab(store: store, settingsStore: settingsStore)
        }
        attachWindowsToParent()
        reanchorWindows()
    }

    private func makeExpandedPanel(
        store: SessionStore,
        runtime: GhosttyRuntime,
        settingsStore: AppSettingsStore
    ) -> TerminalPanelWindow {
        // Floating rebinds this root on every show with the active slot's store
        // and title; the initial closures are mode-appropriate and each self
        // method guards on its mode, so they are safe no-ops in the other mode.
        let root = TerminalPanelChromeView(
            mode: mode,
            sessionStore: store,
            ghosttyRuntime: runtime,
            appSettingsStore: settingsStore,
            focusState: focusState,
            parentWorkspaceTitle: nil,
            onMinimize: { [weak self] in self?.minimize() },
            onClose: { [weak self] in self?.close() },
            onDismiss: { [weak self] in self?.dismiss(source: .programmatic) },
            onMakeWorkspace: { [weak self] in self?.makeWorkspace() }
        )
        let panel = TerminalPanelWindow(
            contentRect: NSRect(origin: .zero, size: preferredExpandedSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = FloatingPanelHostingController(
            rootView: AnyView(root.ignoresSafeArea())
        )
        configure(panel, cornerRadius: PopUpTerminalLayout.cornerRadius)
        configureExpandedChrome(panel)
        panel.contentMinSize = mode.minimumSize
        panel.onPromote = { [weak self] in self?.makeWorkspace() }
        panel.onKeyStateChanged = { [weak self] isKey in
            guard let self else { return }
            let wasKey = self.focusState.isKeyWindow
            self.focusState.isKeyWindow = isKey
            // Companion keeps this flag-only; floating posts an external re-key
            // announcement on a later runloop turn (never mid-sendEvent).
            guard self.slots != nil else { return }
            guard Self.shouldAnnounceExternalReKey(
                wasKey: wasKey,
                isKey: isKey,
                isVisible: self.isVisible,
                isPresentingShow: self.isPresentingShow
            ) else { return }
            let parentWorkspaceTitle = self.lastParentWorkspaceTitle
            DispatchQueue.main.async { [weak self] in
                self?.handleExternalReKeyReaction(parentWorkspaceTitle: parentWorkspaceTitle)
            }
        }
        panel.onResignKey = { [weak self] in
            self?.pendingFocusWork?.cancel()
            self?.pendingFocusWork = nil
            // Harmless no-op in companion (no pending confirmation there).
            self?.resetDismissConfirmation()
        }
        // ADR-0030: only floating mode arms Escape smart-dismiss. Companion
        // leaves this nil so TerminalPanelWindow delivers Escape to the TUI.
        panel.onEscapeDismiss = mode.interceptsBareEscape
            ? { [weak self] in self?.performEscapeDismiss() }
            : nil
        panel.title = mode.windowTitle
        panel.setAccessibilityLabel(mode.windowTitle)
        let center = NotificationCenter.default
        panelObservers.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveResizeCapture.start() }
        })
        panelObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let panel,
                      let size = self.liveResizeCapture.finish(with: panel.frame.size) else { return }
                self.preferredExpandedSize = size
                self.sizeStore.save(size, bucket: self.currentSizeBucket())
                self.reanchorWindows()
            }
        })
        // willMove fires for interactive drags only (not setFrame/setFrameOrigin,
        // not parent-driven child moves), so it cleanly marks "the user put the
        // panel somewhere" without a reanchor-suppression flag.
        panelObservers.append(center.addObserver(
            forName: NSWindow.willMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelUserPositioned = true }
        })
        panelObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // Reclamp when the panel's OWN screen changes, not only the parent's —
            // a mid-run display unplug can strand the panel off-screen even if the
            // parent stays put. Also recall the new display's remembered size
            // unless a live resize is mid-flight (that would clobber the drag).
            // INT-799: a drag to another monitor sets panelUserPositioned before
            // this fires, so the reload can NOT gate on it — a dragged panel gets
            // the destination display's remembered SIZE at its dragged ORIGIN
            // (clamped to the new screen); an anchored panel re-anchors.
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // currentSizeBucket resolves panel.screen first, which AppKit has
                // already updated to the destination display by the time this fires.
                let decision = Self.displayChangeResize(
                    isResizing: self.liveResizeCapture.isResizing,
                    userPositioned: self.panelUserPositioned,
                    storedSize: self.sizeStore.load(bucket: self.currentSizeBucket()),
                    defaultSize: self.mode.defaultSize,
                    currentOrigin: panel.frame.origin,
                    newScreenVisibleFrame: panel.screen?.visibleFrame
                        ?? NSScreen.main?.visibleFrame ?? panel.frame
                )
                switch decision {
                case .skip:
                    // INT-799: a live resize is in flight — the user is actively
                    // dragging this panel's edge. reanchorWindows() would call
                    // beginProgrammaticMutation(), clearing the live-resize
                    // capture's isActive so didEndLiveResize returns nil and the
                    // drag is never saved. Reanchoring mid-resize was never
                    // meaningful, so bail out entirely and leave the drag alone.
                    return
                case .reanchor(let size):
                    self.preferredExpandedSize = size
                case .applyFrame(let frame):
                    self.preferredExpandedSize = frame.size
                    self.liveResizeCapture.beginProgrammaticMutation()
                    panel.setFrame(frame, display: panel.isVisible)
                    self.liveResizeCapture.endProgrammaticMutation()
                }
                self.reanchorWindows()
            }
        })
        return panel
    }

    private func makeCornerTab(
        store: SessionStore,
        settingsStore: AppSettingsStore
    ) -> NSPanel {
        let root = PopUpTerminalCornerTabView(
            sessionStore: store,
            appSettingsStore: settingsStore,
            onRestore: { [weak self] in self?.restore() }
        )
        let tab = NSPanel(
            contentRect: NSRect(origin: .zero, size: PopUpTerminalLayout.cornerTabSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tab.contentViewController = FloatingPanelHostingController(
            rootView: AnyView(root.ignoresSafeArea())
        )
        configure(tab, cornerRadius: 12)
        tab.title = String(
            localized: "Minimized Terminal Companion",
            comment: "AppKit window title for the minimized Terminal Companion corner tab."
        )
        tab.setAccessibilityLabel(String(
            localized: "Minimized Terminal Companion",
            comment: "Accessibility label for the minimized Terminal Companion corner tab window."
        ))
        // willMove fires for interactive drags only (not setFrameOrigin, not
        // parent-driven child moves), so it cleanly marks "the user put the
        // tab somewhere" without a reanchor-suppression flag.
        panelObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification,
            object: tab,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cornerTabUserPositioned = true }
        })
        panelObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: tab,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorWindows() }
        })
        return tab
    }

    private func configure(_ panel: NSPanel, cornerRadius: CGFloat) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.masksToBounds = true
        }
    }

    private func configureExpandedChrome(_ panel: NSPanel) {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Both modes are user-movable. Drags land on the header/footer chrome;
        // the terminal GhosttySurfaceNSView is first responder and consumes its
        // own drags for text selection, so window-background drags never fire
        // over the terminal — same behavior the old borderless floating panel had.
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
    }

    private func transition(from source: NSWindow?, to destination: NSWindow?) {
        transitionRevision &+= 1
        let revision = transitionRevision
        PopUpTerminalWindowAttachment.attach(destination, to: parentWindow)
        reanchorWindows()
        guard let destination else { return }
        source?.alphaValue = 1
        // Reduce Motion crossfades in place; the default fold also animates the
        // source's frame onto the destination's.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let destinationFrame = destination.frame
        // The fold is purely visual: put the source's frame back once it's
        // hidden, or the corner tab keeps the expanded panel's frame and
        // its 260x48 content floats centered in an invisible giant window
        // on the next minimize (reanchor only resets the origin).
        let sourceFrame = source?.frame
        liveResizeCapture.beginProgrammaticMutation()
        destination.alphaValue = 0
        destination.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !reduceMotion {
                source?.animator().setFrame(destinationFrame, display: true)
            }
            source?.animator().alphaValue = 0
            destination.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.liveResizeCapture.endProgrammaticMutation()
                guard self?.transitionRevision == revision else { return }
                source?.orderOut(nil)
                source?.alphaValue = 1
                if let source, let sourceFrame {
                    source.setFrame(sourceFrame, display: false)
                }
                destination.orderFrontRegardless()
                self?.reanchorWindows()
            }
        }
    }

    /// Sheets and modal alerts own input while presented; see `restore()`.
    private var hasBlockingModalSession: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func reanchorWindows() {
        guard !isConfirmingClose else { return }
        guard let reference = parentWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame,
              let screen = parentWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame else { return }
        if let panel {
            liveResizeCapture.beginProgrammaticMutation()
            defer { liveResizeCapture.endProgrammaticMutation() }
            if panelUserPositioned {
                // The user dragged the panel; honor their spot. Only clamp it
                // back onto the current screen so a display change can't strand
                // it. Do NOT reset the origin to the anchor. The child-window
                // link (companion) already carries it when the parent moves.
                // INT-799: clamp against the panel's OWN screen, not the
                // parent-derived one — a deliberate drag to another monitor must
                // not be snapped back to the parent's display.
                let clamped = Self.clampedToScreen(
                    origin: panel.frame.origin,
                    size: panel.frame.size,
                    screen: panel.screen?.visibleFrame ?? screen
                )
                if clamped != panel.frame.origin {
                    panel.setFrameOrigin(clamped)
                }
            } else {
                let effectiveBottomInset = mode.anchor == .center ? 0 : bottomInset
                let size = PopUpTerminalLayout.expandedSize(
                    preferred: preferredExpandedSize,
                    availableFrame: reference,
                    minimumSize: mode.minimumSize,
                    bottomInset: effectiveBottomInset
                )
                panel.setFrame(
                    NSRect(
                        origin: Self.expandedOrigin(
                            mode: mode.anchor,
                            size: size,
                            reference: reference,
                            screen: screen,
                            bottomInset: effectiveBottomInset
                        ),
                        size: size
                    ),
                    display: panel.isVisible
                )
                // AppKit can veto the requested size (titlebar-inclusive minimum
                // beats contentMinSize) and grows the frame downward, burying the
                // footer. Re-derive the origin from the size that actually stuck.
                if panel.frame.size != size {
                    panel.setFrameOrigin(
                        Self.expandedOrigin(
                            mode: mode.anchor,
                            size: panel.frame.size,
                            reference: reference,
                            screen: screen,
                            bottomInset: effectiveBottomInset
                        )
                    )
                }
            }
        }
        // Once the user drags the tab, keep their spot: the child-window link
        // already keeps it glued to the parent when the parent moves. Still
        // clamp it to the current screen, or a parent move to a smaller
        // display can strand the tab off-screen with no way to recover it.
        // Full setFrame, not setFrameOrigin: the tab's size is constant, and
        // re-asserting it heals any frame left behind by an interrupted fold.
        if let cornerTab {
            if cornerTabUserPositioned {
                let size = PopUpTerminalLayout.cornerTabSize
                let frame = cornerTab.frame
                // INT-799: clamp against the tab's OWN screen so a drag to
                // another monitor isn't snapped back to the parent's display.
                let clamped = Self.clampedToScreen(
                    origin: frame.origin,
                    size: size,
                    screen: cornerTab.screen?.visibleFrame ?? screen
                )
                if clamped != frame.origin || frame.size != size {
                    cornerTab.setFrame(
                        NSRect(origin: clamped, size: size),
                        display: cornerTab.isVisible
                    )
                }
            } else {
                cornerTab.setFrame(
                    NSRect(
                        origin: PopUpTerminalLayout.origin(
                            for: PopUpTerminalLayout.cornerTabSize,
                            referenceFrame: reference,
                            screenFrame: screen,
                            bottomInset: bottomInset
                        ),
                        size: PopUpTerminalLayout.cornerTabSize
                    ),
                    display: cornerTab.isVisible
                )
            }
        }
    }

    private func observeParentWindow(_ window: NSWindow?) {
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didDeminiaturizeNotification
        ] {
            parentObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reanchorWindows() }
            })
        }
        parentObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        })
    }

    private func removeParentObservers() {
        for observer in parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        parentObservers.removeAll()
    }

    private func removePanelObservers() {
        for observer in panelObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        panelObservers.removeAll()
        liveResizeCapture.reset()
    }

    private func attachWindowsToParent() {
        PopUpTerminalWindowAttachment.attach(panel, to: parentWindow)
        PopUpTerminalWindowAttachment.attach(cornerTab, to: parentWindow)
    }

    private func detachWindowsFromParent() {
        if let panel { panel.parent?.removeChildWindow(panel) }
        if let cornerTab { cornerTab.parent?.removeChildWindow(cornerTab) }
    }

    private func makeWorkspace() {
        guard let store,
              let session = store.selectedSession,
              let mainSessionStore,
              let settingsStore else { return }
        mainSessionStore.insertSession(
            session,
            groupName: settingsStore.workspaces.value.defaultGroup,
            select: true
        )
        // Capture before close() nils the windows, or the announcement has no
        // live target and is silently dropped.
        let announcementTarget = parentWindow ?? NSApp.awesoMuxPrimaryContentWindow
        close(discardSurfaces: false)
        postAnnouncement(String(
            localized: "Moved Terminal Companion to workspace.",
            comment: "VoiceOver announcement after promoting the Terminal Companion into the workspace list."
        ), on: announcementTarget)
    }

    private func close(discardSurfaces: Bool) {
        let announcementTarget = parentWindow ?? NSApp.awesoMuxPrimaryContentWindow
        transitionRevision &+= 1
        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        if discardSurfaces, let store, let runtime {
            var daemonIDs: [TerminalSessionID] = []
            for session in store.groups.flatMap(\.sessions) {
                session.layout.forEachPane { daemonIDs.append($0.terminalSessionID) }
                runtime.discardSurfaces(for: session)
            }
            // The companion never reattaches these ids (no reopen entry), so an
            // unkilled daemon session would idle until launch-time GC.
            AmxBackend.killSessionsDetached(daemonIDs, context: "companion-close")
        }
        presentation = .closed
        panel?.orderOut(nil)
        cornerTab?.orderOut(nil)
        detachWindowsFromParent()
        removePanelObservers()
        removeParentObservers()
        parentWindow = nil
        panel?.contentViewController = nil
        cornerTab?.contentViewController = nil
        panel = nil
        cornerTab = nil
        store = nil
        cornerTabUserPositioned = false
        panelUserPositioned = false
        if discardSurfaces {
            postAnnouncement(String(
                localized: "Terminal Companion closed.",
                comment: "VoiceOver announcement after explicitly closing the Terminal Companion."
            ), on: announcementTarget)
        }
    }

    private func confirmClose() -> Bool {
        NSAlert.confirmDestructive(
            title: String(
                localized: "Close Terminal Companion?",
                comment: "Title of the confirmation shown before closing a Terminal Companion with running work."
            ),
            body: String(
                localized: "A command or agent is still running. Closing ends this Terminal Companion session.",
                comment: "Explanation in the confirmation shown before closing a Terminal Companion with running work."
            ),
            keyboardHint: String(
                localized: "Press ⌘Return to close terminal. Esc cancels.",
                comment: "Keyboard hint line on the Terminal Companion close confirmation dialog."
            ),
            destructiveTitle: String(
                localized: "Close Terminal",
                comment: "Destructive confirmation button that closes the Terminal Companion."
            )
        )
    }

    private static let focusRetryAttemptCap = 20

    private func focusTerminalSurface(in panel: NSPanel, attempt: Int = 0) {
        if let surface = panel.contentView?.awFirstSubview(of: GhosttySurfaceNSView.self),
           panel.makeFirstResponder(surface) {
            return
        }
        guard attempt < Self.focusRetryAttemptCap else { return }
        pendingFocusWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.focusTerminalSurface(in: panel, attempt: attempt + 1)
        }
        pendingFocusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func postAnnouncement(_ message: String, on explicitTarget: NSWindow? = nil) {
        guard let element = explicitTarget
            ?? (presentation == .minimized ? cornerTab : panel)
            ?? parentWindow else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    // MARK: - Floating mode
    //
    // Absorbed verbatim (adjusting `floatingStores` -> `slots`, and the stored
    // `isVisible` writes -> `presentation`) from the former
    // floating panel controller. Floating is standalone: no `bind`, no parent
    // observers, no child-window attach; the panel is the same titled+resizable
    // window the companion builds, positioned one-shot and re-bound per show.

    enum DismissSource {
        case escape
        case toggle
        case programmatic

        var confirmationRequestSource: FloatingPanelDismissConfirmationState.RequestSource {
            switch self {
            case .escape:
                return .escape
            case .toggle, .programmatic:
                return .nonEscape
            }
        }
    }

    /// Tracks promote progress so interrupts can finish the float -> tab
    /// migration atomically.
    private final class InFlightPromotion {
        let workspaceID: TerminalSession.ID
        let session: TerminalSession
        let sessionStore: SessionStore
        var didInsert: Bool
        var didDetach: Bool

        init(
            workspaceID: TerminalSession.ID,
            session: TerminalSession,
            sessionStore: SessionStore,
            didInsert: Bool,
            didDetach: Bool
        ) {
            self.workspaceID = workspaceID
            self.session = session
            self.sessionStore = sessionStore
            self.didInsert = didInsert
            self.didDetach = didDetach
        }
    }

    static func promotionDestinationGroupName(
        for workspaceID: TerminalSession.ID,
        in groups: [SessionGroup],
        fallback: String
    ) -> String {
        groups.first { group in
            group.sessions.contains { $0.id == workspaceID }
        }?.name ?? fallback
    }

    private static func shouldAnnounceExternalReKey(
        wasKey: Bool,
        isKey: Bool,
        isVisible: Bool,
        isPresentingShow: Bool
    ) -> Bool {
        isKey && !wasKey && isVisible && !isPresentingShow
    }

    private func floatingToggle(
        relativeTo parentWindow: NSWindow?,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore
    ) {
        guard let slots else { return }
        let workspaceID = sessionStore.selectedSession?.id ?? FloatingSlotBook.unattachedWorkspaceID
        // Toggle the active workspace's floating panel, not a global flag: the
        // panel can be visible for the active workspace, or hidden while another
        // workspace's slot stays open — `isVisible` alone can't tell those apart.
        let isTargetWorkspaceActive = slots.activeWorkspaceID == workspaceID
        let isTargetVisible = isTargetWorkspaceActive && (panel?.isVisible ?? isVisible)
        let isTargetKeyWindow = isTargetVisible && (panel?.isKeyWindow ?? focusState.isKeyWindow)
        switch FloatingSlotBook.toggleAction(
            isOpen: slots.openWorkspaceIDs.contains(workspaceID),
            isVisible: isTargetVisible,
            isKeyWindow: isTargetKeyWindow
        ) {
        case .show:
            show(
                relativeTo: parentWindow,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore
            )
        case .restoreFocus:
            show(
                relativeTo: parentWindow,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore,
                announcement: .restoreFocus
            )
        case .dismiss:
            dismiss(source: .toggle)
        }
    }

    /// Shows the new workspace's open floating panel, or hides the current
    /// panel without tearing down the previous workspace's slot.
    func activeWorkspaceDidChange(
        relativeTo parentWindow: NSWindow?,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore
    ) {
        guard let slots else { return }
        let workspaceID = sessionStore.selectedSession?.id ?? FloatingSlotBook.unattachedWorkspaceID

        // Move the no-workspace sentinel slot onto the first real workspace so a
        // preserved shell remains reachable from the sidebar and shortcut. The
        // book has no runtime dependency, so the caller does the refresh +
        // recompute + mirror after the sentinel move.
        if let migrated = slots.migrateUnattached(to: workspaceID) {
            ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: migrated)
            slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
            workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
        }

        if slots.openWorkspaceIDs.contains(workspaceID) {
            // Switch-restore takes focus, but uses the concise announcement so
            // VoiceOver does not hear the full shortcut reminder each time.
            show(
                relativeTo: parentWindow,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore,
                announcement: .concise
            )
        } else if isVisible {
            hideWithoutTeardown()
        }
    }

    private func floatingShow(
        relativeTo parentWindow: NSWindow?,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore,
        announcement: SummonAnnouncement
    ) {
        guard let slots else { return }
        #if DEBUG
        assert(panel?.isInsidePointerRekey != true, "show during pointer re-key")
        #endif
        isPresentingShow = true
        defer { isPresentingShow = false }

        lastSeenRuntime = ghosttyRuntime
        resetDismissConfirmation()
        let parentWorkspace = sessionStore.selectedSession
        let workspaceID = parentWorkspace?.id ?? FloatingSlotBook.unattachedWorkspaceID
        slots.setActive(workspaceID)
        lastParentWorkspaceTitle = parentWorkspace?.title
        slots.markOpen(workspaceID)

        let floatingStore = slots.ensureStore(for: workspaceID) {
            FloatingPanelStoreFactory.makeStore(
                parentWorkspace: parentWorkspace,
                // Canonical home, matching ingest-canonicalized working directories
                // so the display layer's home-prefix strip holds (INT-498).
                fallbackHome: WorkingDirectoryValidator.canonicalHomeDirectory
            )
        }

        if panel == nil {
            preferredExpandedSize = sizeStore.load(
                bucket: currentSizeBucket(preferredScreen: parentWindow?.screen)
            ) ?? mode.defaultSize
            panel = makeExpandedPanel(
                store: floatingStore,
                runtime: ghosttyRuntime,
                settingsStore: appSettingsStore
            )
        }
        guard let panel else { return }

        // Rebind the concrete hosting root every show so the terminal follows
        // the active slot on workspace switch instead of going stale.
        (panel.contentViewController as? FloatingPanelHostingController)?.rootView = AnyView(
            TerminalPanelChromeView(
                mode: mode,
                sessionStore: floatingStore,
                ghosttyRuntime: ghosttyRuntime,
                appSettingsStore: appSettingsStore,
                focusState: focusState,
                parentWorkspaceTitle: parentWorkspace?.title,
                onMinimize: {},
                onClose: {},
                onDismiss: { [weak self] in self?.dismiss(source: .programmatic) },
                onMakeWorkspace: { [weak self, weak sessionStore, weak appSettingsStore] in
                    guard let self, let sessionStore, let appSettingsStore else { return }
                    self.promoteActiveSlot(
                        into: sessionStore,
                        groupName: Self.promotionDestinationGroupName(
                            for: workspaceID,
                            in: sessionStore.groups,
                            fallback: appSettingsStore.workspaces.value.defaultGroup
                        )
                    )
                }
            ).ignoresSafeArea()
        )
        #if DEBUG
        Self.smokeRebindLogger.debug(
            "floating-rebind workspace=\(String(describing: workspaceID), privacy: .public) session=\(String(describing: floatingStore.selectedSession?.id), privacy: .public)"
        )
        #endif

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.onPromote = { [weak self, weak sessionStore, weak appSettingsStore] in
            guard let self, let sessionStore, let appSettingsStore else { return }
            self.promoteActiveSlot(
                into: sessionStore,
                groupName: Self.promotionDestinationGroupName(
                    for: workspaceID,
                    in: sessionStore.groups,
                    fallback: appSettingsStore.workspaces.value.defaultGroup
                )
            )
        }
        positionFloatingPanel(panel, relativeTo: parentWindow)
        panel.isPointerRekeyEnabled = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Recompute the drop shadow against the now-mounted rounded chrome.
        panel.invalidateShadow()
        // `makeKeyAndOrderFront` synchronously drives `focusState.isKeyWindow`
        // via `onKeyStateChanged`; single-writer keeps the chrome and
        // `hideIfVisible()` reading the same source of truth.
        presentation = .expanded
        focusTerminalSurface(in: panel)
        switch announcement {
        case .full:
            postSummonAnnouncement(parentWorkspaceTitle: parentWorkspace?.title, concise: false)
        case .concise:
            postSummonAnnouncement(parentWorkspaceTitle: parentWorkspace?.title, concise: true)
        case .restoreFocus:
            postRestoreFocusAnnouncement(parentWorkspaceTitle: parentWorkspace?.title)
        case .none:
            break
        }

        slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
        workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
    }

    /// One-shot floating positioning: honor a dragged panel (clamp only), else
    /// center over the parent frame and clamp the size to its available space
    /// (ADR-0024 records this deliberate shift from the old fixed screen-relative
    /// size).
    private func positionFloatingPanel(_ panel: NSPanel, relativeTo parentWindow: NSWindow?) {
        let screenFrame = parentWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero
        let referenceFrame = parentWindow?.frame ?? screenFrame
        if panelUserPositioned {
            // INT-799: a panel dragged to monitor B keeps its own screen; clamp
            // against it, not the parent-window-derived screenFrame (monitor A),
            // or re-showing snaps it back. Matches reanchorWindows' pattern.
            panel.setFrameOrigin(Self.clampedToScreen(
                origin: panel.frame.origin, size: panel.frame.size,
                screen: panel.screen?.visibleFrame ?? screenFrame
            ))
        } else {
            let size = PopUpTerminalLayout.expandedSize(
                preferred: preferredExpandedSize,
                availableFrame: referenceFrame,
                minimumSize: mode.minimumSize,
                bottomInset: 0
            )
            panel.setFrame(
                NSRect(origin: Self.expandedOrigin(
                    mode: .center, size: size, reference: referenceFrame,
                    screen: screenFrame, bottomInset: 0
                ), size: size),
                display: panel.isVisible
            )
        }
    }

    private func deactivateFloatingPanel() {
        panel?.isPointerRekeyEnabled = false
        panel?.orderOut(nil)
    }

    /// Hide-only Cmd-W path (floating). Gates on visibility, not key focus, so a
    /// visible panel is hidden instead of letting Cmd-W destroy a pane behind it.
    /// A no-op in companion mode (its Cmd-W is `performCloseShortcut`).
    func hideIfVisible() -> Bool {
        guard let slots else { return false }
        guard isVisible else { return false }
        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        cancelPromotion()
        resetDismissConfirmation()
        deactivateFloatingPanel()
        presentation = .closed
        panelUserPositioned = false
        // Cmd-W closes this workspace's floating panel non-destructively (the
        // slot survives), so it should not auto-restore on switch-back.
        if let activeWorkspaceID = slots.activeWorkspaceID {
            slots.markClosed(activeWorkspaceID)
            if let store = slots.store(for: activeWorkspaceID) {
                lastSeenRuntime?.refreshTerminalQuitConfirmationRisks(in: store)
            }
        }
        slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
        workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
        return true
    }

    /// Hide the panel without tearing down the active slot or mutating the open
    /// set — used when switching to a workspace with no open floating panel. The
    /// previous workspace's slot stays alive and "open" so returning restores it.
    private func hideWithoutTeardown() {
        guard let slots else { return }
        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        cancelPromotion()
        resetDismissConfirmation()
        deactivateFloatingPanel()
        presentation = .closed
        // Refresh before recomputing so switch-away notices newly running work.
        if let activeWorkspaceID = slots.activeWorkspaceID, let store = slots.store(for: activeWorkspaceID) {
            lastSeenRuntime?.refreshTerminalQuitConfirmationRisks(in: store)
        }
        slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
        workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
    }

    /// Smart dismiss: tear down an idle slot so the next summon spawns a fresh
    /// shell; a risky slot requires a second dismiss request first. Cmd-W remains
    /// the non-destructive hide-only path for keeping a risky slot alive.
    func dismiss(source: DismissSource = .programmatic) {
        guard let slots else { return }
        #if DEBUG
        assert(panel?.isInsidePointerRekey != true, "dismiss during pointer re-key")
        #endif
        let decision = dismissalDecision(source: source)
        if decision == .needsConfirmation {
            scheduleDismissConfirmationExpiration()
            postDismissConfirmationAnnouncement()
            return
        }

        pendingFocusWork?.cancel()
        pendingFocusWork = nil
        cancelPromotion()
        resetDismissConfirmation()
        deactivateFloatingPanel()
        presentation = .closed
        panelUserPositioned = false
        // Explicit close: a later switch back to this workspace won't auto-restore.
        if let activeWorkspaceID = slots.activeWorkspaceID {
            slots.markClosed(activeWorkspaceID)
        }

        defer {
            slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
            workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
        }

        guard let workspaceID = slots.activeWorkspaceID,
              slots.store(for: workspaceID) != nil else {
            return
        }

        let runtime = lastSeenRuntime
        if decision != .hide {
            // Collect daemon ids before teardown drops the store. A destructive
            // dismiss discards the surfaces and there is no reopen path, so a
            // bridged pane's daemon would idle until launch-time GC — kill it
            // detached, mirroring companion close(discardSurfaces:).
            let daemonIDs = floatingDaemonIDs(for: workspaceID)
            tearDownFloatingSlot(workspaceID: workspaceID, runtime: runtime)
            AmxBackend.killSessionsDetached(daemonIDs, context: "floating-dismiss")
        }
    }

    /// Free the floating slot belonging to a specific parent workspace. Called
    /// when that workspace is closed — without this the slot's libghostty
    /// surface, child shell, and SessionStore leak until app quit (no UI handle
    /// reaches a slot whose parent row is gone from the sidebar).
    func evictFloatingSlot(for workspaceID: TerminalSession.ID) {
        guard let slots else { return }
        #if DEBUG
        assert(panel?.isInsidePointerRekey != true, "evict during pointer re-key")
        #endif
        let evictsActiveSlot = slots.activeWorkspaceID == workspaceID
        if evictsActiveSlot {
            deactivateFloatingPanel()
        }
        cancelPromotion()
        resetDismissConfirmation()
        tearDownFloatingSlot(workspaceID: workspaceID, runtime: lastSeenRuntime)
        // The workspace is gone; its floating panel can never be "open" again.
        slots.markClosed(workspaceID)
        if evictsActiveSlot {
            // The visible panel is backed by the dropped store.
            presentation = .closed
            panelUserPositioned = false
            slots.setActive(nil)
        }
        slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
        workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
    }

    func evictFloatingSlotsForClosedWorkspaces(in sessionStore: SessionStore) {
        guard let slots else { return }
        let liveWorkspaceIDs = Set(sessionStore.groups.flatMap(\.sessions).map(\.id))
        for workspaceID in slots.workspaceIDs
        where workspaceID != FloatingSlotBook.unattachedWorkspaceID
            && !liveWorkspaceIDs.contains(workspaceID)
        {
            evictFloatingSlot(for: workspaceID)
        }
    }

    /// Free a floating slot's libghostty surfaces and drop the store. The next
    /// summon for this workspace allocates a fresh shell.
    private func tearDownFloatingSlot(
        workspaceID: TerminalSession.ID,
        runtime: GhosttyRuntime?
    ) {
        guard let store = slots?.removeStore(for: workspaceID) else {
            return
        }
        if let runtime {
            for session in store.groups.flatMap(\.sessions) {
                runtime.discardSurfaces(for: session)
            }
        }
    }

    private func dismissalDecision(
        source: DismissSource
    ) -> FloatingPanelDismissConfirmationState.Decision {
        let hasDiscardRisk: Bool
        if let workspaceID = slots?.activeWorkspaceID,
           let store = slots?.store(for: workspaceID) {
            lastSeenRuntime?.refreshTerminalQuitConfirmationRisks(in: store)
            // Close-scoped, not quit-scoped: dismiss discards the slot's
            // surfaces and kills the daemon, so a bridged pane away from its
            // prompt (quit-safe but close-risky) must still confirm (INT-772).
            hasDiscardRisk = !store.sessionsAtRiskOnClose().isEmpty
        } else {
            hasDiscardRisk = false
        }

        let decision = dismissConfirmation.decision(
            hasDiscardRisk: hasDiscardRisk,
            source: source.confirmationRequestSource
        )
        focusState.discardConfirmationPending = dismissConfirmation.isPending
        return decision
    }

    private func resetDismissConfirmation() {
        pendingDismissConfirmationResetWork?.cancel()
        pendingDismissConfirmationResetWork = nil
        dismissConfirmation.reset()
        focusState.discardConfirmationPending = false
    }

    private func scheduleDismissConfirmationExpiration() {
        pendingDismissConfirmationResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.resetDismissConfirmation()
            }
        }
        pendingDismissConfirmationResetWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + FloatingPanelDismissConfirmationState.pendingConfirmationTimeout,
            execute: work
        )
    }

    private func promoteActiveSlot(
        into sessionStore: SessionStore,
        groupName: String
    ) {
        guard let slots else { return }
        guard pendingPromotionTask == nil else {
            return
        }
        guard let workspaceID = slots.activeWorkspaceID,
              let floatingStore = slots.store(for: workspaceID),
              let promotedSession = floatingStore.selectedSession else {
            return
        }

        let motion = FloatingPanelPromotionMotion.resolved(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let promotedSessionID = promotedSession.id
        let promotedPaneID = promotedSession.activePaneID
        self.promotedSessionID = promotedSessionID
        // Let cancellation finish any already-committed migration step.
        promotionInFlight = InFlightPromotion(
            workspaceID: workspaceID,
            session: promotedSession,
            sessionStore: sessionStore,
            didInsert: false,
            didDetach: false
        )

        pendingPromotionTask = Task { @MainActor [weak self, weak sessionStore] in
            guard let self, let sessionStore else { return }
            // Always clear the re-entry guard, even on cancellation.
            defer { self.pendingPromotionTask = nil }

            await self.sleep(motion.compressDelay)
            guard !Task.isCancelled else { return }
            if motion.compressDelay > .zero {
                withAnimation(.easeOut(duration: 0.08)) {
                    self.focusState.promotionPhase = .compressing
                }
            }

            await self.sleep(motion.tabInsertionDelay - motion.compressDelay)
            guard !Task.isCancelled else { return }
            let tabAnimation: Animation? = motion.tabInsertionDuration == 0
                ? nil
                : .easeOut(duration: motion.tabInsertionDuration)
            withAnimation(tabAnimation) {
                sessionStore.insertSession(
                    promotedSession,
                    groupName: groupName,
                    select: false
                )
            }
            self.promotionInFlight?.didInsert = true

            await self.sleep(motion.dismissDelay - motion.tabInsertionDelay)
            guard !Task.isCancelled else { return }
            // INT-799: a workspace switch mid-animation leaves the shared panel
            // showing another workspace's slot. Always settle this promotion's
            // slot (the session already lives in the main store, so skipping
            // detach would leave dual ownership), but capture panel ownership
            // before detach nils the active slot so the selection/focus steps
            // below don't hijack the main window from the now-visible workspace.
            let ownsVisiblePanel = self.slots?.activeWorkspaceID == workspaceID
            self.detachPromotedSlot(workspaceID: workspaceID)
            self.promotionInFlight?.didDetach = true
            // Selection the user currently sees, captured before the settle sleep.
            let selectionAtDetach = sessionStore.selectedSessionID

            await self.sleep(motion.selectionDelay - motion.dismissDelay)
            guard !Task.isCancelled else { return }
            // INT-799: `ownsVisiblePanel` was snapshotted before this await; a
            // workspace switch or a re-opened floating panel during the settle
            // sleep makes it stale. Mirror cancelPromotion's ownership gate but
            // revalidate against the *current* state before taking selection or
            // focus, so a completion that lands after the user moved on can't
            // yank the main window away from what they chose: only proceed if
            // this promotion still owned the panel, no floating slot has since
            // become active, and the main-store selection is still untouched.
            if ownsVisiblePanel,
               self.slots?.activeWorkspaceID == nil,
               sessionStore.selectedSessionID == selectionAtDetach {
                sessionStore.selectedSessionID = promotedSessionID
                self.promotionPulseSessionID = promotedSessionID
                self.focusPromotedSession(sessionID: promotedSessionID, paneID: promotedPaneID)
            }

            let pulseClearDelay = motion.settleDelay - motion.selectionDelay
            if pulseClearDelay > .zero {
                await self.sleep(pulseClearDelay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self.promotionPulseSessionID = nil
            self.promotedSessionID = nil
            self.focusState.promotionPhase = .idle
            self.promotionInFlight = nil
        }
    }

    private func detachPromotedSlot(workspaceID: TerminalSession.ID) {
        guard let slots else { return }
        // INT-799: the panel and active slot are shared across workspaces, so
        // only touch the visible window when this promotion still owns it — a
        // switch to another workspace mid-promotion must not order out or
        // deactivate the panel now showing that other workspace. State
        // settlement (markClosed/removeStore) is unconditional so the promoted
        // session never lives in both the floating and main stores.
        if slots.activeWorkspaceID == workspaceID {
            pendingFocusWork?.cancel()
            pendingFocusWork = nil
            resetDismissConfirmation()
            deactivateFloatingPanel()
            presentation = .closed
            // A dragged-then-promoted panel must re-center on the next summon,
            // mirroring the dismiss/hide/evict position resets.
            panelUserPositioned = false
            slots.setActive(nil)
        }
        slots.markClosed(workspaceID)
        slots.removeStore(for: workspaceID)
        slots.recomputeBackgroundedRunningWork(isVisible: isVisible)
        workspacesWithBackgroundedRunningWork = slots.workspacesWithBackgroundedRunningWork
    }

    private func cancelPromotion() {
        pendingPromotionTask?.cancel()
        pendingPromotionTask = nil
        focusState.promotionPhase = .idle
        promotedSessionID = nil
        promotionPulseSessionID = nil
        // If insertion already committed, detach the floating copy so the same
        // session ID cannot live in both stores.
        if let promotion = promotionInFlight {
            if promotion.didInsert, !promotion.didDetach {
                // INT-799: the panel and active slot are shared across
                // workspaces. Resolve ownership BEFORE detach (detach clears the
                // active slot when it owns it, so reading after would always read
                // false) so a switch-away mid-promotion is seen. The data move is
                // unconditional — the insert already happened, so detach must run
                // or the session lives in both stores — but reassert selection
                // only when this promotion still owns the visible panel.
                // Otherwise a cancel that lands after the user switched to a
                // workspace with no open panel would bounce selection back to the
                // promoted terminal and undo their switch.
                let ownsVisiblePanel = slots?.activeWorkspaceID == promotion.workspaceID
                detachPromotedSlot(workspaceID: promotion.workspaceID)
                if ownsVisiblePanel {
                    promotion.sessionStore.selectedSessionID = promotion.session.id
                }
            }
            promotionInFlight = nil
        }
    }

    private func sleep(_ duration: Duration) async {
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }

    private func focusPromotedSession(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        attempt: Int = 0
    ) {
        DispatchQueue.main.async {
            // Promotion can start while the primary window is not key; resolve
            // the actual content window instead of trusting main/key window.
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            guard let window = Self.primaryContentWindow() else {
                return
            }
            window.makeKeyAndOrderFront(nil)
            if let surface = Self.terminalSurface(
                in: window.contentView,
                sessionID: sessionID,
                paneID: paneID
            ) {
                if window.makeFirstResponder(surface) {
                    self.postPromotionAnnouncement(in: window)
                    return
                }
            }
            // Retry while the promoted SwiftUI/AppKit surface mounts.
            guard attempt < Self.focusRetryAttemptCap else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusPromotedSession(
                    sessionID: sessionID,
                    paneID: paneID,
                    attempt: attempt + 1
                )
            }
        }
    }

    private static func primaryContentWindow() -> NSWindow? {
        NSApp.awesoMuxPrimaryContentWindow
    }

    private static func terminalSurface(
        in view: NSView?,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> GhosttySurfaceNSView? {
        guard let view else {
            return nil
        }
        if let surface = view as? GhosttySurfaceNSView,
           surface.sessionID == sessionID,
           surface.paneID == paneID {
            return surface
        }
        for subview in view.subviews {
            if let surface = terminalSurface(
                in: subview,
                sessionID: sessionID,
                paneID: paneID
            ) {
                return surface
            }
        }
        return nil
    }

    /// VoiceOver announcement for the promoted tab, posted on the primary
    /// content window after the float panel has been torn down.
    private func postPromotionAnnouncement(in window: NSWindow) {
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Moved floating terminal to workspace.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func postDismissConfirmationAnnouncement() {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Running work. Press Escape again to discard.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// AX / other reactions after key change — never call mid-sendEvent.
    private func handleExternalReKeyReaction(parentWorkspaceTitle: String?) {
        guard isVisible, focusState.isKeyWindow else { return }
        postRestoreFocusAnnouncement(parentWorkspaceTitle: parentWorkspaceTitle)
    }

    private func postRestoreFocusAnnouncement(parentWorkspaceTitle: String?) {
        guard let panel else { return }
        let message: String
        if let parentWorkspaceTitle, !parentWorkspaceTitle.isEmpty {
            message = String(
                localized: "Floating terminal panel focused for \(parentWorkspaceTitle).",
                comment: "VoiceOver announcement when the floating panel is re-keyed for a specific workspace."
            )
        } else {
            message = String(
                localized: "Floating terminal panel focused.",
                comment: "VoiceOver announcement when the floating panel is re-keyed without workspace context."
            )
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func postSummonAnnouncement(parentWorkspaceTitle: String?, concise: Bool) {
        guard let panel else { return }
        let context: String
        if let parentWorkspaceTitle, !parentWorkspaceTitle.isEmpty {
            context = "for \(parentWorkspaceTitle)"
        } else {
            context = "ephemeral shell"
        }
        // Workspace-switch restores use the concise variant; explicit summons
        // include the dismiss/hide chords.
        let message = concise
            ? "Floating terminal panel \(context)."
            : "Floating terminal panel \(context). Press Escape to dismiss, Command-W to hide."
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

enum PopUpTerminalPresentation: Equatable {
    case closed
    case expanded
    case minimized
}

/// How `show()` should announce itself to VoiceOver.
enum SummonAnnouncement {
    /// Explicit summon (Cmd-`): full announcement including the dismiss/hide chords.
    case full
    /// Workspace-switch restore: short announcement.
    case concise
    /// Re-keying an already-open panel from the shortcut: status only, no keymap.
    case restoreFocus
    /// No announcement.
    case none
}

#if DEBUG
extension TerminalPanelController {
    func seedDismissConfirmationTestSlot(
        workspaceID: TerminalSession.ID,
        store: SessionStore,
        isOpen: Bool = true,
        isVisible: Bool = true
    ) {
        guard let slots else { return }
        _ = slots.ensureStore(for: workspaceID, make: { store })
        slots.setActive(workspaceID)
        if isOpen {
            slots.markOpen(workspaceID)
        } else {
            slots.markClosed(workspaceID)
        }
        presentation = isVisible ? .expanded : .closed
        resetDismissConfirmation()
    }

    func seedRetainedPaneIDTestSlots(
        _ seeds: [(workspaceID: TerminalSession.ID, store: SessionStore)]
    ) {
        guard let slots else { return }
        for seed in seeds {
            _ = slots.ensureStore(for: seed.workspaceID, make: { seed.store })
        }
        if slots.activeWorkspaceID == nil {
            slots.setActive(seeds.first?.workspaceID)
        }
        resetDismissConfirmation()
    }

    func hasFloatingSlotForTesting(workspaceID: TerminalSession.ID) -> Bool {
        slots?.store(for: workspaceID) != nil
    }

    var isDismissConfirmationPendingForTesting: Bool {
        dismissConfirmation.isPending && focusState.discardConfirmationPending
    }

    static func shouldAnnounceExternalReKeyForTesting(
        wasKey: Bool,
        isKey: Bool,
        isVisible: Bool,
        isPresentingShow: Bool
    ) -> Bool {
        shouldAnnounceExternalReKey(
            wasKey: wasKey,
            isKey: isKey,
            isVisible: isVisible,
            isPresentingShow: isPresentingShow
        )
    }

    /// Seeds a post-insert, pre-detach promotion so a test can drive
    /// `cancelPromotion` without AppKit windows (detach is nil-panel safe). Set
    /// `activeWorkspaceID` to a different workspace to simulate a switch-away.
    func seedInFlightPromotionTestSlot(
        workspaceID: TerminalSession.ID,
        session: TerminalSession,
        mainStore: SessionStore,
        activeWorkspaceID: TerminalSession.ID?
    ) {
        guard let slots else { return }
        _ = slots.ensureStore(for: workspaceID, make: { SessionStore(groups: []) })
        slots.markOpen(workspaceID)
        slots.setActive(activeWorkspaceID)
        promotionInFlight = InFlightPromotion(
            workspaceID: workspaceID,
            session: session,
            sessionStore: mainStore,
            didInsert: true,
            didDetach: false
        )
    }

    func cancelPromotionForTesting() {
        cancelPromotion()
    }
}
#endif
