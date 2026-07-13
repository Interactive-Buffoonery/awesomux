import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

enum SidebarVisibilitySource {
    case pointer
    case explicit
}

struct SidebarHiddenWidthToggleResult: Equatable {
    let targetWidth: CGFloat
    let shouldReveal: Bool
}

enum SidebarHoverTransitionPolicy {
    static func transition(
        for source: SidebarVisibilitySource,
        reduceMotion: Bool
    ) -> SidebarSplitTransition {
        source == .pointer && !reduceMotion ? .hover(duration: 0.140) : .immediate
    }
}

enum SidebarHiddenWidthTogglePolicy {
    static func currentWidth(
        committedWidth: CGFloat,
        liveWidth: CGFloat,
        isTemporarilyRevealed: Bool
    ) -> CGFloat {
        isTemporarilyRevealed ? liveWidth : committedWidth
    }

    static func resolve(
        currentWidth: CGFloat,
        lastNonCollapsedWidth: CGFloat,
        persistentlyHidden: Bool
    ) -> SidebarHiddenWidthToggleResult {
        SidebarHiddenWidthToggleResult(
            targetWidth: SidebarWidthPolicy.toggleWidth(
                currentWidth: currentWidth,
                lastNonCollapsedWidth: lastNonCollapsedWidth
            ),
            shouldReveal: !persistentlyHidden
        )
    }
}

enum SidebarRuntimeVisibilityPolicy {
    static func isVisible(
        proximityState: SidebarPresentationModel.ProximityState,
        userWantsHidden: Bool
    ) -> Bool {
        !userWantsHidden || proximityState == .revealed
    }
}

struct ContentView: View {
    static let minimumWindowWidth: CGFloat = 720
    static let minimumWindowHeight: CGFloat = 640
    /// Seed size for a fresh window (no autosaved frame). Must stay >= the
    /// minimum above; `WindowFrameClampPolicyTests.defaultSizeNotBelowMinimum`
    /// enforces that so a future edit can't drop it below the floor.
    static let defaultWindowWidth: CGFloat = 1280
    static let defaultWindowHeight: CGFloat = 820
    /// Minimum width the terminal pane keeps; bounds the sidebar's dynamic max
    /// (`windowWidth − this`). Must stay below `minimumWindowWidth − collapsedWidth`.
    static let terminalMinimumWidth: CGFloat = 480

    @Bindable var sessionStore: SessionStore
    @Bindable var ghosttyRuntime: GhosttyRuntime
    @Bindable var floatingPanelController: TerminalPanelController
    let onCloseWorkspace: (TerminalSession) -> Void
    let onClearWorkspace: (TerminalSession) -> Void
    let onCloseWorkspaceGroup: (SessionGroup) -> Void
    let onRenameWorkspace: (TerminalSession) -> Void
    let onRenameWorkspaceGroup: (SessionGroup) -> Void
    let onNewWorkspaceGroup: () -> Void
    let onConnectViaSSH: (SessionGroup) -> Void
    let canMakeWorkspaceManaged: (TerminalSession) -> Bool
    let onMakeWorkspaceManaged: (TerminalSession) -> Void
    let onManagedSSHWorkspaceOffer: (TerminalSession.ID, TerminalPane.ID) -> Void
    let onReopenClosedWorkspace: () -> Void
    let hasRecoveryWarning: Bool
    let onOpenQuickSettings: () -> Void
    let onToggleCommandPalette: () -> Void
    let onOpenSelectedWorkspaceInIDE: () -> Void
    let onOpenSelectedWorkspaceInIDEWithApp: (URL, InstalledIDE) -> Void
    let onTerminalFooterHeightChange: (CGFloat) -> Void
    /// Jump to an exact agent pane from the sidebar activity panel (INT-722).
    let onFocusAgentPane: (TerminalSession.ID, UUID) -> Void
    let onFocusActiveTerminal: () -> Bool
    let sidebarFocusRequestID: UUID?
    let sidebarWidthToggleRequestID: UUID?
    let sidebarVisibilityToggleRequestID: UUID?

    @State private var sidebarWidth = SidebarWidthPreferenceStore().width()
    @State private var lastNonCollapsedSidebarWidth =
        SidebarWidthPreferenceStore().lastNonCollapsedWidth()
    /// Live width published by the native divider; read by the titlebar and the
    /// sidebar pane (not ContentView's body) so a drag re-renders only those.
    @State private var sidebarLiveWidth = SidebarLiveWidth(value: SidebarWidthPreferenceStore().width())
    /// Command channel to move the native divider (the `⌘\` toggle).
    @State private var splitProxy = SidebarSplitProxy()
    @State private var sidebarPresentation = SidebarPresentationModel()
    @State private var appliedSidebarPosition: AppearanceConfig.SidebarPosition = .left
    /// Collapsed-rail hover peek card, hoisted above the split (INT-533/535).
    /// The sidebar tile (inside the rail pane, which clips to its bounds)
    /// publishes which session is peeked and where; the card draws here, over
    /// the terminal. See `SidebarPeekModel`.
    @State private var peekModel = SidebarPeekModel()
    /// This view's own hosting window, captured via `WindowAccessor` rather
    /// than read from `NSApp.keyWindow` at execution time — a recovery
    /// alert, the command palette, or Settings can be key by the time the
    /// deferred initial-focus fix below actually runs, and clearing THEIR
    /// first responder instead of ours is the wrong window entirely.
    @State private var hostingWindow: NSWindow?
    /// Keeps the initial-empty-launch focus fix pending until this view's
    /// hosting window is actually key. Once it clears focus successfully (or
    /// a session appears), later window activations cannot strip focus the
    /// user deliberately established.
    @State private var initialEmptyFocusClearState = InitialEmptyFocusClearState()

    // The split hosts each pane in its own NSHostingController, a fresh SwiftUI
    // environment root — the app-level `.environment(appSettingsStore)` /
    // `.appearanceBridge` do NOT reach it. Re-read the store here and re-apply both
    // to each pane inside the split closures so the panes keep their environment.
    @Environment(AppSettingsStore.self) private var appSettingsStore

    private let sidebarWidthPreferenceStore = SidebarWidthPreferenceStore()

    var body: some View {
        content(sidebarWidth: sidebarWidth)
            .ignoresSafeArea(.container)
            .background(WindowAccessor { hostingWindow = $0 })
            .onAppear {
                applySidebarPosition(appSettingsStore.appearance.value.sidebarPosition)
                sessionStore.selectFirstSessionIfNeeded()
                // `.onAppear` can fire more than once (window re-show, scene
                // reactivation); wire the peek callback only once.
                if peekModel.onSelectPane == nil {
                    wirePeekSelection()
                }
                // No session to claim first responder (empty workspace list) means
                // AppKit's key-view loop falls back to the sidebar search field —
                // the only focusable control in that state. Deferred a tick so
                // this wins the race against that automatic selection; the
                // condition is re-checked inside the closure since a session (or
                // another deliberate focus request) can legitimately win first
                // responder before the deferred tick runs.
                initialEmptyFocusClearState.requestIfNeeded(
                    hasSelectedSession: sessionStore.selectedSessionID != nil
                )
                DispatchQueue.main.async { clearInitialEmptyFocusIfEligible() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
                notification in
                guard notification.object as? NSWindow === hostingWindow else { return }
                // Handle the key transition before its activating mouse event is
                // dispatched, so a click into search can establish focus afterward.
                clearInitialEmptyFocusIfEligible()
            }
            .onChange(of: sidebarWidthToggleRequestID) { _, requestID in
                guard requestID != nil else { return }
                toggleSidebarWidth()
            }
            .onChange(of: sidebarVisibilityToggleRequestID) { _, requestID in
                guard requestID != nil else {
                    return
                }
                sidebarPresentation.togglePersistentVisibility()
                settleSidebarVisibilityExplicitly()
            }
            .onChange(of: sidebarFocusRequestID) { _, requestID in
                guard requestID != nil else { return }
                sidebarPresentation.showPersistently()
                settleSidebarVisibilityExplicitly()
            }
            .onChange(of: appSettingsStore.appearance.value.sidebarPosition) { _, position in
                applySidebarPosition(position)
            }
            .background(Color.aw.surface.window)
            .background(
                WindowChromeConfigurator(windowRole: .primaryContent)
                    .allowsHitTesting(false)
            )
    }

    private func clearInitialEmptyFocusIfEligible() {
        guard let hostingWindow,
            initialEmptyFocusClearState.consumeIfEligible(
                hasSelectedSession: sessionStore.selectedSessionID != nil,
                isHostingWindowKey: hostingWindow.isKeyWindow
            )
        else {
            return
        }
        hostingWindow.makeFirstResponder(nil)
    }

    private func content(sidebarWidth: CGFloat) -> some View {
        // Read backgrounded-work HERE in ContentView's body so the @Observable
        // subscription registers at this layer (hoisting the read into the hosted
        // sidebar closure would move the subscription and leave stale dots).
        let backgroundedWork = floatingPanelController.workspacesWithBackgroundedRunningWork
        let promotedSessionID = floatingPanelController.promotedSessionID
        let promotionPulseSessionID = floatingPanelController.promotionPulseSessionID
        let sidebarPosition = appliedSidebarPosition
        let layoutPolicy = SidebarPresentationLayoutPolicy(position: sidebarPosition)
        return VStack(spacing: 0) {
            AppTitlebarView(
                session: sessionStore.selectedSession,
                onRenameWorkspace: onRenameWorkspace,
                sidebarLiveWidth: sidebarLiveWidth,
                sidebarPosition: sidebarPosition,
                isSidebarVisible: sidebarPresentation.isSidebarVisible
            )

            SidebarSplitView(
                terminalMinimumWidth: Self.terminalMinimumWidth,
                initialWidth: sidebarWidth,
                proxy: splitProxy,
                position: sidebarPosition,
                initiallyHidden: !sidebarPresentation.isSidebarVisible,
                edgeTrackingEnabled: sidebarPresentation.userWantsHidden,
                onLiveWidthChange: { width in sidebarLiveWidth.value = width },
                onCommitWidth: { width in commitSidebarWidth(width) },
                onSidebarFocusHandoff: onFocusActiveTerminal,
                onEdgePointerMove: { x, width in
                    sidebarPresentation.pointerMoved(
                        x: x,
                        width: width,
                        position: appliedSidebarPosition
                    )
                },
                onEdgeExit: sidebarPresentation.trackingRegionExited,
                onTrackingAvailabilityLost: sidebarPresentation.invalidateTransientState,
                sidebar: {
                    SidebarView(
                        sessionStore: sessionStore,
                        ghosttyRuntime: ghosttyRuntime,
                        workspacesWithBackgroundedFloatingWork: backgroundedWork,
                        promotedSessionID: promotedSessionID,
                        promotionPulseSessionID: promotionPulseSessionID,
                        onCloseWorkspace: onCloseWorkspace,
                        onClearWorkspace: onClearWorkspace,
                        onCloseWorkspaceGroup: onCloseWorkspaceGroup,
                        onRenameWorkspace: onRenameWorkspace,
                        onRenameWorkspaceGroup: onRenameWorkspaceGroup,
                        onNewWorkspaceGroup: onNewWorkspaceGroup,
                        onConnectViaSSH: onConnectViaSSH,
                        canMakeWorkspaceManaged: canMakeWorkspaceManaged,
                        onMakeWorkspaceManaged: onMakeWorkspaceManaged,
                        onOpenQuickSettings: onOpenQuickSettings,
                        onToggleCommandPalette: onToggleCommandPalette,
                        onFocusPane: onFocusAgentPane,
                        focusRequestID: sidebarFocusRequestID,
                        sidebarLiveWidth: sidebarLiveWidth,
                        onSidebarHover: sidebarPresentation.sidebarPointerChanged
                    )
                    .environment(appSettingsStore)
                    .environment(peekModel)
                    .appearanceBridge(appSettingsStore)
                },
                detail: {
                    SessionDetailView(
                        session: sessionStore.selectedSession,
                        sessionStore: sessionStore,
                        ghosttyRuntime: ghosttyRuntime,
                        onRenameWorkspace: onRenameWorkspace,
                        onManagedSSHWorkspaceOffer: onManagedSSHWorkspaceOffer,
                        onReopenClosedWorkspace: onReopenClosedWorkspace,
                        onOpenSelectedWorkspaceInIDE: onOpenSelectedWorkspaceInIDE,
                        onOpenSelectedWorkspaceInIDEWithApp: onOpenSelectedWorkspaceInIDEWithApp,
                        onFooterHeightChange: onTerminalFooterHeightChange,
                        hasRecoveryWarning: hasRecoveryWarning
                    )
                    .environment(appSettingsStore)
                    .appearanceBridge(appSettingsStore)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Peek card lives here, above the split, so it can overflow the rail
            // pane onto the terminal. The model's coordinates arrive in the
            // sidebar's whole-window `.global` space; the overlay converts them
            // into its own titlebar-inset space by subtracting its measured
            // origin (INT-790 — see `SidebarPeekModel`'s doc comment).
            // A dedicated leaf view so the per-frame anchorY/tileHeight observation
            // invalidates only it, not ContentView's body (the SidebarLiveWidth
            // scoping discipline — keep the terminal pane off the drag/scroll path).
            .overlay(alignment: .topLeading) {
                SidebarPeekCardOverlay(model: peekModel)
            }
            .overlay(alignment: layoutPolicy.edge == .leading ? .leading : .trailing) {
                SidebarProximityCue(
                    visible: sidebarPresentation.isCueVisible
                )
            }
            .onChange(of: sidebarPresentation.proximityState) { _, state in
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                splitProxy.setVisibility?(
                    SidebarRuntimeVisibilityPolicy.isVisible(
                        proximityState: state,
                        userWantsHidden: sidebarPresentation.userWantsHidden
                    ),
                    SidebarHoverTransitionPolicy.transition(
                        for: sidebarPresentation.visibilitySource,
                        reduceMotion: reduceMotion
                    ),
                    reduceMotion
                )
            }
        }
    }

    private func applySidebarPosition(_ position: AppearanceConfig.SidebarPosition) {
        guard position != appliedSidebarPosition else { return }
        // Ordering is deliberate: invalidate every stale interaction before
        // moving the native split, then publish the new overlay geometry.
        sidebarPresentation.positionDidChange()
        splitProxy.setVisibility?(sidebarPresentation.isSidebarVisible, .immediate, true)
        peekModel.hideAll()
        splitProxy.setPosition?(position)
        appliedSidebarPosition = position
        peekModel.updatePosition(position)
    }

    /// Wire the multi-pane peek card's click-to-jump once, when the overlay is
    /// installed. Re-resolves the live workspace and confirms the pane still
    /// exists before acting — a pane can close while the card is open (538 R6).
    /// Selecting + focusing the clicked pane then acknowledging it is an
    /// explicit gesture, so it acks immediately (ADR-0003 explicit-vs-dwell).
    ///
    /// `acknowledgeSession` acks the workspace's ACTIVE pane; `setActivePane`
    /// runs first so the clicked pane *is* the active one by then — that is why
    /// the active-pane ack lands on exactly the clicked pane (per-pane ack,
    /// INT-504 hybrid model). The `setActivePane` call is load-bearing for that
    /// ack, not redundant, even when the clicked pane was already active.
    ///
    /// VoiceOver gets the same "Focused pane N" announcement the keyboard
    /// `⌘⌥N` path emits, so an assistive-tech user who triggers the jump from
    /// the tile's per-pane action hears that focus moved (INT-538 a11y review).
    private func wirePeekSelection() {
        peekModel.onSelectPane = { [weak peekModel] sessionID, paneID in
            guard let live = sessionStore.session(id: sessionID),
                let paneIndex = live.layout.paneIDs.firstIndex(of: paneID)
            else {
                peekModel?.hide(for: sessionID)
                return
            }
            sessionStore.selectedSessionID = sessionID
            sessionStore.setActivePane(id: paneID, in: sessionID)
            sessionStore.acknowledgeSession(id: sessionID)
            peekModel?.hide(for: sessionID)
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Focused pane \(paneIndex + 1)",
                    comment: "VoiceOver announcement when jumping to a pane from the sidebar peek card."
                )
            )
        }
        peekModel.onSelectGroupSession = { [weak peekModel] groupID, sessionID in
            guard sessionStore.session(id: sessionID) != nil else {
                peekModel?.hideGroup(for: groupID)
                return
            }
            sessionStore.selectedSessionID = sessionID
            sessionStore.acknowledgeSession(id: sessionID)
            peekModel?.hideGroup(for: groupID)
        }
    }

    /// Persist a free-drag width on commit (drag end). Preserves the exact width
    /// (no snap) and updates the last-non-collapsed restore width.
    private func commitSidebarWidth(_ width: CGFloat) {
        let committed = SidebarWidthPolicy.committedWidth(for: width)
        let updatedLastNonCollapsedWidth = SidebarWidthPolicy.updatedLastNonCollapsedWidth(
            currentWidth: committed,
            previousLastNonCollapsedWidth: lastNonCollapsedSidebarWidth
        )
        sidebarWidth = committed
        sidebarLiveWidth.value = committed
        lastNonCollapsedSidebarWidth = updatedLastNonCollapsedWidth
        sidebarWidthPreferenceStore.saveWidth(committed)
        sidebarWidthPreferenceStore.saveLastNonCollapsedWidth(updatedLastNonCollapsedWidth)
        // Move the divider to the committed width: snaps a rail-zone release tight to
        // the collapsed width, and is a no-op when the user released above it.
        splitProxy.setWidth?(committed)
    }

    private func toggleSidebarWidth() {
        // Read the LIVE rendered width, not the committed `sidebarWidth`: a
        // programmatic clamp (e.g. a window-narrow force-collapse) moves the live
        // width without re-committing, so the committed copy can be stale. Toggling
        // off the stale value inverts the first press (it thinks a collapsed rail is
        // still expanded and re-collapses it).
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: sidebarPresentation.userWantsHidden
                ? SidebarHiddenWidthTogglePolicy.currentWidth(
                    committedWidth: sidebarWidth,
                    liveWidth: sidebarLiveWidth.value,
                    isTemporarilyRevealed: sidebarPresentation.isTemporarilyRevealed
                )
                : sidebarLiveWidth.value,
            lastNonCollapsedWidth: lastNonCollapsedSidebarWidth,
            persistentlyHidden: sidebarPresentation.userWantsHidden
        )
        // Collapse/expand by commanding the native divider directly — instant
        // (commitSidebarWidth moves the divider).
        commitSidebarWidth(result.targetWidth)
    }

    private func settleSidebarVisibilityExplicitly() {
        sidebarPresentation.invalidateTransientState()
        splitProxy.setVisibility?(sidebarPresentation.isSidebarVisible, .immediate, true)
    }

}

private struct SidebarProximityCue: View {
    let visible: Bool
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(
                Color.aw.focusAccent(
                    accentResolver.accent,
                    terminalBackground: Color.aw.surface.window
                )
            )
            .frame(width: 4)
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AppTitlebarView: View {
    let session: TerminalSession?
    /// Same rename closure the sidebar tile uses — the titlebar workspace name
    /// invokes it on a double-click (INT-720).
    let onRenameWorkspace: (TerminalSession) -> Void
    /// Live sidebar width (from the native divider) so the titlebar mirrors the
    /// body's `[sidebar | content]` column split frame-for-frame during a drag.
    /// The two zones below are anchored to the column they describe — brand
    /// over the sidebar, workspace cluster over the content pane — so the
    /// wide-monitor empty space reads as intentional negative space between
    /// two anchored elements rather than vacuum around a centered cluster.
    /// Reading `.value` here re-renders only the titlebar, not `ContentView`.
    let sidebarLiveWidth: SidebarLiveWidth
    let sidebarPosition: AppearanceConfig.SidebarPosition
    let isSidebarVisible: Bool
    private var sidebarWidth: CGFloat { isSidebarVisible ? sidebarLiveWidth.value : 0 }
    private var layoutPolicy: SidebarPresentationLayoutPolicy {
        SidebarPresentationLayoutPolicy(position: sidebarPosition)
    }

    // Read the accent from the environment (published by AppearanceBridge)
    // rather than the bare `Color.aw.accent` getter. The bare getter reads the
    // `AwAccentRuntime.current` mailbox, and reading that mailbox in a view
    // body establishes no SwiftUI dependency — so the folder icon kept its
    // first-rendered (default) accent and only picked up a non-peach accent
    // once a workspace switch forced AppTitlebarView to re-render (INT-712).
    @Environment(\.awAccent) private var accentResolver

    private static let brandWithTextMinimumWidth = AppTitlebarMetrics.trafficLightClearance + 94
    private static let brandIconMinimumWidth = AppTitlebarMetrics.trafficLightClearance + 28

    var body: some View {
        HStack(spacing: 0) {
            if sidebarPosition == .left {
                sidebarColumn(isPhysicalLeading: true)
                contentColumn(isPhysicalLeading: false)
            } else {
                contentColumn(isPhysicalLeading: true)
                sidebarColumn(isPhysicalLeading: false)
            }
        }
        // Titlebar height stays fixed: it abuts macOS window chrome
        // (traffic-light controls) which does not scale with Dynamic Type.
        // Inner labels use `.lineLimit(1)` and truncate at extreme sizes.
        // Tracked: INT-237 (AwFont call-site Dynamic Type audit).
        .frame(height: AwSpacing.titlebar)
        .background {
            ZStack {
                LinearGradient(
                    colors: [Color.aw.surface.chrome2, Color.aw.surface.chrome],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    /// Brand anchored over the sidebar column. The fixed-width frame matches
    /// the body's sidebar column width so a window resize keeps the brand
    /// aligned with the column beneath it.
    ///
    /// The wordmark only appears when the sidebar is wide enough to clear
    /// traffic lights and fit the label. Narrow modes keep the titlebar quiet
    /// instead of clipping the brand into the content column.
    private func sidebarColumn(isPhysicalLeading: Bool) -> some View {
        HStack(spacing: 0) {
            if layoutPolicy.titlebarLockupAlignment == .trailing {
                Spacer(minLength: 0)
                titleLockup
            } else {
                titleLockup
                Spacer(minLength: 0)
            }
        }
        .padding(
            .leading,
            isPhysicalLeading
                ? AppTitlebarMetrics.trafficLightClearance
                : layoutPolicy.dividerGutterColumn == .sidebar
                    ? AppTitlebarMetrics.contentColumnGutter : 10
        )
        .padding(.trailing, layoutPolicy.titlebarLockupOuterPadding)
        .frame(
            width: sidebarWidth,
            alignment: layoutPolicy.titlebarLockupAlignment == .trailing ? .trailing : .leading
        )
    }

    @ViewBuilder
    private var titleLockup: some View {
        if sidebarWidth >= Self.brandWithTextMinimumWidth {
            Brandmark()
                .allowsHitTesting(false)
        } else if sidebarWidth >= Self.brandIconMinimumWidth {
            Brandmark(showsText: false)
                .allowsHitTesting(false)
        }
    }

    /// Workspace cluster anchored to the start of the content pane (i.e. the
    /// right side of the sidebar/content divider). Folder icon + title sit
    /// left-aligned here; the wide remaining space stays
    /// draggable via the `WindowDragGesture` on the outer `HStack`'s
    /// background — do NOT attach a tap/click handler to this column without
    /// considering that it would compete with the underlying drag.
    private func contentColumn(isPhysicalLeading: Bool) -> some View {
        HStack(spacing: 0) {
            if let session {
                workspaceCluster(session)
            } else {
                Text("no workspace")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 12)
        }
        .padding(
            .leading,
            layoutPolicy.dividerGutterColumn == .detail ? AppTitlebarMetrics.contentColumnGutter : 10
        )
        .padding(
            .leading,
            sidebarPosition == .left
                ? max(0, AppTitlebarMetrics.trafficLightClearance + 10 - sidebarWidth)
                : AppTitlebarMetrics.trafficLightClearance
        )
        .padding(.trailing, 10)
    }

    private func workspaceCluster(_ session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.aw.accent(accentResolver.accent))
                .accessibilityHidden(true)

            Text(session.title)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
        }
        // A tightly-scoped AppKit overlay owns the cluster's mouse events: a
        // stationary double-click renames, a press-drag moves the window. The
        // whole titlebar was `.allowsHitTesting(false)` so clicks fell through
        // to the sibling `WindowDragGesture` layer; forwarding the drag with
        // `performDrag(with:)` preserves that window-move behavior on the name
        // itself while capturing only the double-click (INT-720). SwiftUI
        // gesture arbitration between `WindowDragGesture` and a double-tap is
        // not a documented contract, so an explicit `clickCount` branch is used
        // instead — same disambiguation the pane title bar's drag source makes.
        .overlay {
            WindowDragRenameHandle(onDoubleClick: { onRenameWorkspace(session) })
                // Fill the cluster: an NSViewRepresentable in an `.overlay` can
                // otherwise collapse to its (zero) intrinsic size, leaving the
                // name non-interactive (the proven PaneTitleBarView placement).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .help("Drag to move window · double-click to rename")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        // Double-click is pointer-only; expose the same rename as a named
        // action so assistive-tech users reach it too (mirrors the sidebar tile).
        .accessibilityAction(named: "Rename Workspace") {
            onRenameWorkspace(session)
        }
    }
}

/// Titlebar workspace-name drag region. Captures a stationary double-click for
/// rename while forwarding a press-drag to the window, so the name stays a
/// window-move handle. `WindowDragGesture` is opaque with no documented movement
/// threshold, so an explicit `mouseDown` `clickCount` branch is the reliable
/// contract here rather than SwiftUI gesture arbitration (INT-720).
private struct WindowDragRenameHandle: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragRegionView {
        let view = DragRegionView()
        view.onDoubleClick = onDoubleClick
        view.toolTip = Self.tooltip
        return view
    }

    func updateNSView(_ nsView: DragRegionView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    // The overlay NSView is the hit-test winner, so the tooltip must live on it
    // — a SwiftUI `.help` on the parent cluster is under the overlay and never
    // shows on hover. Same wording as the cluster's `.help` (which stays as the
    // VoiceOver hint).
    static let tooltip = String(
        localized: "Drag to move window · double-click to rename",
        comment: "Tooltip on the titlebar workspace name explaining its pointer affordances."
    )

    final class DragRegionView: NSView {
        var onDoubleClick: (() -> Void)?
        /// The original mouseDown event, held until a drag threshold is crossed.
        /// `performWindowDragWithEvent` is documented to want the *original*
        /// mouseDown event, not a later mouseDragged one.
        private var mouseDownEvent: NSEvent?

        // Match the old `.allowsWindowActivationEvents(true)` layer: a click on
        // an inactive window's name should activate AND start the drag/rename,
        // not just raise the window and swallow the gesture.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // A double-click is a rename intent — clear the drag origin so no
            // later mouseDragged fires, and forward to the rename flow.
            if event.clickCount >= 2 {
                mouseDownEvent = nil
                onDoubleClick?()
                return
            }
            // Defer the window drag to mouseDragged (past a threshold) rather
            // than calling performDrag here: performDrag runs a modal
            // event-tracking loop, and entering it on the FIRST click of a
            // double-click can swallow the inter-click timing so the second
            // click never registers as clickCount 2 (rename would be lost).
            // This mirrors PaneDragSource's press-drag disambiguation.
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent else { return }
            let start = convert(mouseDownEvent.locationInWindow, from: nil)
            let current = convert(event.locationInWindow, from: nil)
            let dx = current.x - start.x
            let dy = current.y - start.y
            // 3pt mirrors AppKit's own drag slop; below it it's still a click.
            guard (dx * dx + dy * dy) >= 9 else { return }
            self.mouseDownEvent = nil
            // Hand the *original* mouseDown event to the Window Server drag —
            // the documented contract for performWindowDragWithEvent.
            window?.performDrag(with: mouseDownEvent)
        }

        override func mouseUp(with event: NSEvent) {
            // A press that never crossed the threshold is a plain click on the
            // name — nothing to do (matches the prior click-through no-op).
            mouseDownEvent = nil
        }
    }
}

/// Draws the collapsed-rail peek card above the split, tracking the hovered
/// tile. A dedicated view so the per-frame `anchorY`/`tileHeight` reads from
/// `SidebarPeekModel` invalidate only this leaf — not `ContentView`'s body, and
/// so never the terminal pane (the same scoping `SidebarLiveWidth` buys for the
/// divider drag). Appear/disappear animates here because the model mutation
/// fires in the sidebar's separate hosting tree, whose transaction can't cross
/// the `NSHostingController` boundary into this overlay.
private struct SidebarPeekCardOverlay: View {
    let model: SidebarPeekModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 0

    /// Keep the whole card on-screen near the rail's top/bottom edges.
    private static let edgeInset: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let session = model.session,
                let location = model.location,
                let tint = model.tint
            {
                // The model's anchors are measured in the sidebar pane's
                // hosting root, which spans the whole window — including the
                // titlebar (the rail renders behind the transparent titlebar).
                // This overlay's local space starts *below* the titlebar, so
                // the two spaces differ by this overlay's own origin within
                // the shared window root. Subtract it instead of assuming the
                // origins coincide: measured live, so it should adapt if
                // chrome changes this overlay's inset again (INT-790 — the
                // cards drifted down by titlebar height when that happened).
                // INVARIANT this still leans on: the sidebar's hosting root
                // keeps spanning the whole window. If the sidebar ever becomes
                // titlebar-inset like this overlay, its anchors arrive already
                // corrected and this subtraction OVER-corrects — the card
                // floats titlebar-height too HIGH. Re-derive here if so.
                let overlayOrigin = proxy.frame(in: .global).origin
                // Only the multi-pane card is interactive — its rows jump. The
                // single-pane summary has no actionable content, so it stays
                // non-hittable and never steals a terminal click (538 R4).
                let interactive = session.layout.paneCount > 1
                SidebarSessionPeekCard(
                    session: session,
                    location: location,
                    tint: tint,
                    paneItems: model.paneItems,
                    onSelectPane: { paneID in model.onSelectPane?(session.id, paneID) },
                    onHoverChanged: { over in model.setPointerOverCard(over, for: session.id) }
                )
                // `.leading` is load-bearing: the single-pane summary card
                // hugs its content (no expanding Spacer, unlike the pane
                // rows), so the default `.center` alignment would float the
                // visible card ~(cardWidth − contentWidth)/2 right of the
                // rail while the `.position` math below assumes it starts
                // at this frame's leading edge (INT-790). Like `anchorX`,
                // this assumes LTR; an RTL locale would need the whole
                // peek positioning system revisited, not just this line.
                .frame(width: SidebarPeekMetrics.cardWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    cardHeight = $0
                }
                // `.position` centers the card here: leading edge just past
                // the hovered row's right edge (`anchorX`) — the collapsed
                // rail's edge or the expanded row's edge, so it floats right
                // of the sidebar in both modes — vertically centered on the
                // tile but clamped so a near-edge tile's card doesn't clip.
                .position(
                    x: clampedCenterX(
                        containerWidth: proxy.size.width,
                        overlayOriginX: overlayOrigin.x
                    ),
                    y: clampedCenterY(containerHeight: proxy.size.height, overlayOriginY: overlayOrigin.y)
                )
                .allowsHitTesting(interactive)
                .transition(
                    reduceMotion
                        ? .identity
                        : .opacity.combined(
                            with: .scale(
                                scale: 0.98,
                                anchor: model.peekDirection == .right ? .leading : .trailing
                            )
                        )
                )
            } else if let group = model.group,
                let tint = model.tint
            {
                let overlayOrigin = proxy.frame(in: .global).origin
                SidebarGroupPeekCard(
                    group: group,
                    tint: tint,
                    items: model.groupSessionItems,
                    onSelectSession: { sessionID in model.onSelectGroupSession?(group.id, sessionID) },
                    onHoverChanged: { over in model.setPointerOverGroupCard(over, for: group.id) }
                )
                // Always hittable — every row jumps, unlike the
                // session card's single-pane summary variant.
                .frame(width: SidebarPeekMetrics.cardWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    cardHeight = $0
                }
                .position(
                    x: clampedCenterX(
                        containerWidth: proxy.size.width,
                        overlayOriginX: overlayOrigin.x
                    ),
                    y: clampedTopAlignedY(containerHeight: proxy.size.height, overlayOriginY: overlayOrigin.y)
                )
                .transition(
                    reduceMotion
                        ? .identity
                        : .opacity.combined(
                            with: .scale(
                                scale: 0.98,
                                anchor: model.peekDirection == .right ? .leading : .trailing
                            )
                        )
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.session?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.group?.id)
        // `cardHeight` is shared across both card kinds (session vs group),
        // so switching kinds without a fresh 0-height frame in between would
        // clamp the newly-shown card against the OLD kind's stale height for
        // one frame — a visible glitch. Reset it whenever the shown card's
        // identity changes kind.
        .onChange(of: model.session?.id) { _, _ in cardHeight = 0 }
        .onChange(of: model.group?.id) { _, _ in cardHeight = 0 }
    }

    private func clampedCenterX(containerWidth: CGFloat, overlayOriginX: CGFloat) -> CGFloat {
        let inwardOffset = SidebarPeekMetrics.cardGap + SidebarPeekMetrics.cardWidth / 2
        let rawCenter =
            model.anchorX - overlayOriginX
            + (model.peekDirection == .right ? inwardOffset : -inwardOffset)
        let halfCard = SidebarPeekMetrics.cardWidth / 2
        let lower = halfCard + Self.edgeInset
        let upper = containerWidth - halfCard - Self.edgeInset
        guard lower <= upper else { return rawCenter }
        return min(max(rawCenter, lower), upper)
    }

    private func clampedCenterY(containerHeight: CGFloat, overlayOriginY: CGFloat) -> CGFloat {
        let center = model.anchorY - overlayOriginY + model.tileHeight / 2
        // Until the card has measured its height, place it raw (corrected next frame).
        guard cardHeight > 0, containerHeight > 0 else { return center }
        let halfCard = cardHeight / 2
        let lower = halfCard + Self.edgeInset
        let upper = containerHeight - halfCard - Self.edgeInset
        guard lower <= upper else { return center }
        return min(max(center, lower), upper)
    }

    /// The group roster card anchors its TOP edge to the header instead of
    /// centering on it (unlike `clampedCenterY`) — the collapsed header is a
    /// thin 26pt row, so centering a multi-row card on it reads as floating
    /// disconnected from what triggered it; top-aligning reads like an
    /// ordinary dropdown expanding from its invoker (eD, 2026-07-13).
    private func clampedTopAlignedY(containerHeight: CGFloat, overlayOriginY: CGFloat) -> CGFloat {
        let top = model.anchorY - overlayOriginY
        // `.position` sets the view's CENTER, so the top-aligned target
        // center is the top edge plus half the card's own height. Before
        // the card has measured its real height, estimate using the
        // trigger element's own height rather than the raw top — using
        // `top` directly here would make `.position` treat it as the
        // card's CENTER, visually overshooting upward by half the card's
        // eventual height until the next frame corrects it.
        guard cardHeight > 0, containerHeight > 0 else { return top + model.tileHeight / 2 }
        let halfCard = cardHeight / 2
        let center = top + halfCard
        let lower = halfCard + Self.edgeInset
        let upper = containerHeight - halfCard - Self.edgeInset
        guard lower <= upper else { return center }
        return min(max(center, lower), upper)
    }
}

/// Geometry of the collapsed-rail hover peek card. The card renders as a
/// `ContentView` overlay above the split (see `SidebarPeekModel`); these place
/// its leading edge just right of the rail.
enum SidebarPeekMetrics {
    /// Horizontal gap between the hovered row's right edge and the card's
    /// leading edge.
    static let cardGap: CGFloat = AwSpacing.overlayGap
    static let cardWidth: CGFloat = 240
    /// Beyond this many rows a peek card's list scrolls instead of growing
    /// the card past the window — shared by the multi-pane card and the
    /// group-roster card so both cap at the same visual height.
    static let maxVisibleRows = 5
    static let rowHeight: CGFloat = 30
}
