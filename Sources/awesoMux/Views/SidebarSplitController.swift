import AppKit
import AwesoMuxConfig
import AwesoMuxCore

private final class SidebarSubviewOrder {
    let sidebar: NSView
    let detail: NSView
    let position: AppearanceConfig.SidebarPosition

    init(sidebar: NSView, detail: NSView, position: AppearanceConfig.SidebarPosition) {
        self.sidebar = sidebar
        self.detail = detail
        self.position = position
    }

    func compare(_ lhs: NSView, _ rhs: NSView) -> ComparisonResult {
        let lhsRank = rank(of: lhs)
        let rhsRank = rank(of: rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank ? .orderedAscending : .orderedDescending }
        if lhs === rhs { return .orderedSame }
        let lhsAddress = UInt(bitPattern: Unmanaged.passUnretained(lhs).toOpaque())
        let rhsAddress = UInt(bitPattern: Unmanaged.passUnretained(rhs).toOpaque())
        return lhsAddress < rhsAddress ? .orderedAscending : .orderedDescending
    }

    private func rank(of view: NSView) -> Int {
        let leading = position == .left ? sidebar : detail
        let trailing = position == .left ? detail : sidebar
        if view === leading { return 0 }
        if view === trailing { return 1 }
        return 2
    }
}

private final class SidebarSplitRootView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

private struct SidebarApplicationFocusRecovery {
    let request: SidebarFocusHandoffRequest
    let sidebarAccessibilityElement: Any?
}

/// Native split host for the sidebar/detail divider (INT-535).
///
/// Hosts a bare `NSSplitView` inside a plain `NSViewController`. We deliberately do
/// NOT subclass `NSSplitViewController`: an `NSSplitViewController` returned from an
/// `NSViewControllerRepresentable` inside a SwiftUI window scene silently prevents
/// the window from being created (the scene tears down with no window and no crash).
/// A plain `NSViewController` hosting an `NSSplitView` works and gives us the same
/// real-divider `inLiveResize`. See skill `nssplitviewcontroller-representable-no-window`.
///
/// Because the divider is a real `NSSplitView` divider, dragging it enters genuine
/// AppKit `inLiveResize` — the divider and the libghostty Metal surface share a frame
/// clock (kills the seam shimmer) and the existing `SurfaceResizeUpdatePolicy`
/// coalescing engages for free.
final class SidebarSplitController: NSViewController, NSSplitViewDelegate {
    typealias AddLocalMouseMovedMonitor = (
        NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    typealias RemoveLocalMouseMovedMonitor = (Any) -> Void
    typealias CurrentMouseLocation = () -> NSPoint
    typealias ApplicationIsActive = () -> Bool

    /// Fires on every divider resize tick with the sidebar pane's live width.
    var onLiveWidthChange: ((CGFloat) -> Void)?

    /// Fires once when a user divider drag ends (wired in A6).
    var onCommitWidth: ((CGFloat) -> Void)?

    /// Moves focus out of the sidebar before it becomes zero-width and reports
    /// the exact destination plus the focus modalities established there.
    var onSidebarFocusHandoff: ((SidebarFocusHandoffRequest) -> SidebarFocusHandoffOutcome?)?

    var onEdgePointerMove: ((CGFloat, CGFloat) -> Void)?
    var onEdgeExit: (() -> Void)?
    var onTrackingAvailabilityLost: (() -> Void)?
    var hasActiveSidebarAccessibilityFocus: (() -> Bool)?
    var sidebarAccessibilityFocusedElement: (() -> Any?)?
    var onSidebarInteractionChanged: ((Bool) -> Void)?

    /// Minimum width the detail/terminal pane must retain. The sidebar's dynamic
    /// maximum is `splitView.bounds.width - terminalMinimumWidth`, evaluated live so
    /// it self-adjusts as the window resizes. Tunable.
    var terminalMinimumWidth: CGFloat = 480 {
        didSet { guard isViewLoaded else { return }; reclampToBounds() }
    }

    private let splitView = DividerTrackingSplitView()
    private let edgeTrackingView = SidebarEdgeTrackingView(position: .left)
    private let sidebarPaneContainer = NSView()
    private let sidebarHostClipView = SidebarHostClipView()
    private let sidebarHostView = NSView()
    private var overlayAnimator: SidebarOverlayAnimator?
    private var interactionMonitor: SidebarInteractionMonitor?
    private let sidebarChild: NSViewController
    private let detailChild: NSViewController
    var sidebarViewController: NSViewController { sidebarChild }
    var detailViewController: NSViewController { detailChild }
    private var sidebarPosition: AppearanceConfig.SidebarPosition = .left
    private var isSidebarHidden = false {
        didSet {
            splitView.isPersistentSidebarHidden = isSidebarHidden
        }
    }
    private var isEdgeTrackingEnabled = false
    private var hostMode: SidebarHostMode = .persistent(width: SidebarWidthPolicy.expandedWidth)
    private var selectedSidebarWidth: CGFloat = SidebarWidthPolicy.expandedWidth
    var hostPresentationState = SidebarHostPresentationState()
    private let overlayAnimationRunner: SidebarOverlayAnimator.AnimationRunner?
    private let overlayPresentationTranslation: (() -> CGFloat?)?
    private let interactionFocusedAccessibilityElement: SidebarInteractionMonitor.FocusedAccessibilityElement?
    private let interactionNotificationCenter: NotificationCenter
    private let addLocalMouseMovedMonitor: AddLocalMouseMovedMonitor
    private let removeLocalMouseMovedMonitor: RemoveLocalMouseMovedMonitor
    private let currentMouseLocation: CurrentMouseLocation
    private let applicationIsActive: ApplicationIsActive
    private var localMouseMovedMonitor: Any?
    private weak var localMouseMovedWindow: NSWindow?
    private var localMouseMovedWindowPreviouslyAcceptedEvents = false
    private var applicationActivityObservations: [NSObjectProtocol] = []
    private var acceptsApplicationPointerEvents = true
    /// Single deferred focus-repair record. A hide requested while the primary
    /// window is not key (Settings frontmost, app inactive, or a mid-remount gap)
    /// hides immediately and stashes the handoff here; the two readiness triggers
    /// — primary `didBecomeKey` and Ghostty-surface-readiness — replay the handoff
    /// once the window can accept focus, retry the still-failed modalities per
    /// firing, and clear on success, a persistent show, or detach.
    private var pendingFocusRepair: SidebarApplicationFocusRecovery?

    /// Set around our own `setPosition` calls so `splitViewDidResizeSubviews` (which
    /// also fires for programmatic position changes and window layout) does not echo
    /// a programmatic change back out as a "live" width change.
    private var isSettingPositionProgrammatically = false
    private var isFinalized = false
    private weak var installedCommandProxy: SidebarSplitProxy?
    private var installedCommandHostGeneration: Int?
    private var didPublishUsableCommandHost = false
    #if DEBUG
        private var isGeometryInstrumentationArmedForTesting = false
        private var splitPositionMutationIntentCount = 0
    #endif

    /// Width requested before the split had real bounds (first launch / restore).
    /// Applied once the first non-zero layout lands — dodges the zero-bounds trap
    /// where `maxSidebarWidth` collapses to the floor.
    private var pendingWidth: CGFloat?

    /// The most recent expanded width the sidebar actually rendered. Restored when
    /// the window grows back after a too-narrow window forced the rail.
    private var lastExpandedPaneWidth: CGFloat = SidebarWidthPolicy.expandedWidth

    /// True when the rail is the user's own choice (⌘\ or a drag to the rail), so a
    /// window-widen must NOT auto-expand. Set by every deliberate `setSidebarWidth`.
    private var userChoseRail = false

    init(
        sidebar: NSViewController,
        detail: NSViewController,
        overlayPresentationTranslation: (() -> CGFloat?)? = nil,
        overlayAnimationRunner: SidebarOverlayAnimator.AnimationRunner? = nil,
        interactionFocusedAccessibilityElement: SidebarInteractionMonitor.FocusedAccessibilityElement? = nil,
        interactionNotificationCenter: NotificationCenter = .default,
        addLocalMouseMovedMonitor: @escaping AddLocalMouseMovedMonitor = NSEvent.addLocalMonitorForEvents,
        removeLocalMouseMovedMonitor: @escaping RemoveLocalMouseMovedMonitor = NSEvent.removeMonitor,
        currentMouseLocation: @escaping CurrentMouseLocation = { NSEvent.mouseLocation },
        applicationIsActive: @escaping ApplicationIsActive = { NSApp.isActive }
    ) {
        sidebarChild = sidebar
        detailChild = detail
        self.overlayPresentationTranslation = overlayPresentationTranslation
        self.overlayAnimationRunner = overlayAnimationRunner
        self.interactionFocusedAccessibilityElement = interactionFocusedAccessibilityElement
        self.interactionNotificationCenter = interactionNotificationCenter
        self.addLocalMouseMovedMonitor = addLocalMouseMovedMonitor
        self.removeLocalMouseMovedMonitor = removeLocalMouseMovedMonitor
        self.currentMouseLocation = currentMouseLocation
        self.applicationIsActive = applicationIsActive
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        // A user divider drag runs a synchronous tracking loop inside the split
        // view's mouseDown; commit the settled width when it returns.
        splitView.onDragEnded = { [weak self] in
            guard let self, !self.isSidebarHidden else { return }
            self.onCommitWidth?(self.sidebarPaneWidth)
        }
        splitView.sidebarWidthProvider = { [weak self] in self?.sidebarPaneWidth }
        addChild(sidebarChild)
        addChild(detailChild)
        // NSSplitView treats its direct subviews as panes (index 0 = leading).
        // The sidebar renders from the root-level `sidebarHostView` full-time;
        // `sidebarPaneContainer` is a permanently empty width-reservation spacer
        // that the host mirrors while the sidebar is persistently visible.
        sidebarChild.view.translatesAutoresizingMaskIntoConstraints = true
        sidebarHostView.addSubview(sidebarChild.view)
        sidebarChild.view.frame = sidebarHostView.bounds
        sidebarChild.view.autoresizingMask = [.width, .height]
        if sidebarPosition == .left {
            splitView.addSubview(sidebarPaneContainer)
            splitView.addSubview(detailChild.view)
        } else {
            splitView.addSubview(detailChild.view)
            splitView.addSubview(sidebarPaneContainer)
        }
        edgeTrackingView.isHidden = !isEdgeTrackingEnabled
        edgeTrackingView.position = sidebarPosition
        edgeTrackingView.onPointerMove = { [weak self] x, width in
            self?.onEdgePointerMove?(x, width)
        }
        edgeTrackingView.onExit = { [weak self] in
            self?.onEdgeExit?()
        }
        edgeTrackingView.onAvailabilityLost = { [weak self] in
            guard let self else { return }
            let availabilityLost = self.onTrackingAvailabilityLost
            self.settleDetached()
            availabilityLost?()
        }
        let root = SidebarSplitRootView()
        root.onWindowChanged = { [weak self] window in
            guard let self else { return }
            if window == nil {
                let availabilityLost = self.onTrackingAvailabilityLost
                self.settleDetached()
                availabilityLost?()
            } else {
                self.settleAttached()
            }
        }
        root.addSubview(splitView)
        sidebarHostClipView.wantsLayer = true
        sidebarHostClipView.layer?.masksToBounds = true
        sidebarHostView.wantsLayer = true
        if let layer = sidebarHostView.layer {
            overlayAnimator = SidebarOverlayAnimator(
                layer: layer,
                presentationTranslation: overlayPresentationTranslation,
                animationRunner: overlayAnimationRunner)
            hostPresentationState.overlayPresentationTranslation = { [weak overlayAnimator] in
                overlayAnimator?.currentTranslation
            }
        }
        sidebarHostClipView.contentView = sidebarHostView
        sidebarHostClipView.addSubview(sidebarHostView)
        sidebarHostClipView.isHidden = isSidebarHidden
        root.addSubview(sidebarHostClipView)
        root.addSubview(edgeTrackingView)
        view = root
        installApplicationActivityObserversIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitView.frame = view.bounds
        publishCommandHostUsableIfNeeded()
        if case .overlay = hostMode { layoutOverlayPreservingAnimation(deferringPublication: true) }
        let trackingWidth = max(0, view.bounds.width / 3)
        let trackingFrame = CGRect(
            x: sidebarPosition == .left ? 0 : view.bounds.width - trackingWidth,
            y: 0,
            width: trackingWidth,
            height: view.bounds.height
        )
        if edgeTrackingView.frame != trackingFrame {
            edgeTrackingView.frame = trackingFrame
            edgeTrackingView.republishPointerAfterGeometryChange()
        }
        guard !isSidebarHidden else {
            applyHiddenPosition()
            return
        }
        if let pending = pendingWidth, splitView.bounds.width > 0 {
            pendingWidth = nil
            applyPosition(pending)
        }
        // The sidebar holds its width while the window resizes (shouldAdjustSize
        // returns false for it), so a window shrink alone would let the terminal
        // pane fall below terminalMinimumWidth — AppKit only re-applies
        // constrainMaxCoordinate during a divider drag, not a window resize.
        // Re-clamp on every layout so the terminal can never be starved.
        reclampToBounds()
        syncSidebarHostFrame()
    }

    override func viewWillDisappear() {
        let availabilityLost = onTrackingAvailabilityLost
        settleDetached()
        availabilityLost?()
        super.viewWillDisappear()
    }

    override func viewDidDisappear() {
        settleDetached()
        super.viewDidDisappear()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        settleAttached()
    }

    isolated deinit {
        settleFinal()
    }

    // MARK: - Public API

    /// Move the divider so the sidebar pane is `width` points wide, clamped to
    /// `[collapsedWidth, maxSidebarWidth]`. Un-animated.
    func setSidebarWidth(_ width: CGFloat) {
        selectedSidebarWidth = width
        // A deliberate request decides whether the rail is the user's choice: if
        // they're asking for a rail-band width, honor it and don't auto-expand on a
        // later window-widen; otherwise they want an expanded sidebar.
        userChoseRail = width < SidebarWidthPolicy.railThreshold
        // Seed the restore target from the *requested* expanded width, not just
        // rendered ones: a cold launch into a too-narrow window clamps the render
        // straight to the rail, so restore-on-grow would otherwise hand back the
        // policy default instead of the user's persisted width.
        recordIfExpanded(width)
        if isSidebarHidden {
            pendingWidth = width
            hostPresentationState.beginOverlayTransition(
                presented: false,
                width: width,
                position: sidebarPosition)
            return
        }
        guard isViewLoaded, splitView.bounds.width > 0 else {
            pendingWidth = width
            return
        }
        applyPosition(width)
    }

    func setSelectedSidebarWidth(_ width: CGFloat) {
        selectedSidebarWidth = Self.clampedWidth(width, maxWidth: .greatestFiniteMagnitude)
        userChoseRail = selectedSidebarWidth < SidebarWidthPolicy.railThreshold
        recordIfExpanded(selectedSidebarWidth)
        pendingWidth = selectedSidebarWidth
        switch hostMode {
        case .overlay:
            layoutOverlayPreservingAnimation()
            onLiveWidthChange?(selectedSidebarWidth)
        case .persistent:
            setSidebarWidth(selectedSidebarWidth)
        case .hidden:
            hostPresentationState.beginOverlayTransition(
                presented: false,
                width: selectedSidebarWidth,
                position: sidebarPosition)
        }
    }

    @discardableResult
    func setOverlayPresentedImmediately(_ presented: Bool) -> Bool {
        setOverlayPresented(presented, transition: .immediate, reduceMotion: true)
    }

    @discardableResult
    func setOverlayPresented(
        _ presented: Bool,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool
    ) -> Bool {
        guard isSidebarHidden else { return false }
        if presented {
            guard sidebarHostView.layer != nil, overlayAnimator != nil else {
                settleHidden()
                return false
            }
            let wasStablyHidden = hostMode == .hidden
            sidebarHostClipView.isHidden = false
            layoutOverlay(presented: false)
            hostMode = .overlay(width: selectedSidebarWidth)
            installInteractionMonitor()
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: selectedSidebarWidth)
            if wasStablyHidden {
                onLiveWidthChange?(sidebarHostClipView.bounds.width)
                overlayAnimator?.cancelAndSettle(
                    presented: false,
                    width: sidebarHostClipView.bounds.width,
                    position: sidebarPosition)
            }
        } else {
            let hasAccessibilityFocus = sidebarAccessibilityFocusIsActive
            guard !hasAccessibilityFocus, interactionMonitor?.isActive != true else {
                interactionMonitor?.synchronizeActiveState()
                return true
            }
            sidebarChild.view.setAccessibilityHidden(true)
        }
        hostPresentationState.beginOverlayTransition(
            presented: presented,
            width: sidebarHostClipView.bounds.width,
            position: sidebarPosition)
        overlayAnimator?.setPresented(
            presented,
            width: sidebarHostClipView.bounds.width,
            position: sidebarPosition,
            transition: transition,
            reduceMotion: reduceMotion
        ) { [weak self] _ in
            self?.finishOverlayTransition(presented: presented)
        }
        hostPresentationState.setOverlayAnimating(overlayAnimator?.isAnimating == true)
        return true
    }

    var maxSidebarWidth: CGFloat {
        max(SidebarWidthPolicy.collapsedWidth, paneExtent - terminalMinimumWidth)
    }

    func setSidebarPosition(_ position: AppearanceConfig.SidebarPosition) {
        guard position != sidebarPosition else { return }
        interactionMonitor?.synchronizeActiveState()
        let preservesVisibleOverlay: Bool
        if isViewLoaded, isSidebarHidden, case .overlay = hostMode,
            interactionMonitor?.isActive == true
        {
            preservesVisibleOverlay = true
        } else {
            preservesVisibleOverlay = false
        }
        if isViewLoaded, isSidebarHidden, case .overlay = hostMode {
            overlayAnimator?.cancelAndSettle(
                presented: preservesVisibleOverlay,
                width: sidebarHostClipView.bounds.width,
                position: sidebarPosition)
            sidebarHostView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
            if !preservesVisibleOverlay {
                settleHidden()
            }
        }
        let width = sidebarPaneWidth
        sidebarPosition = position
        edgeTrackingView.position = position
        if isSidebarHidden {
            if preservesVisibleOverlay {
                hostPresentationState.setOverlayAnimating(false)
            } else {
                hostPresentationState.beginOverlayTransition(
                    presented: false,
                    width: selectedSidebarWidth,
                    position: position)
            }
        }
        guard isViewLoaded else { return }
        view.needsLayout = true
        let responder = view.window?.firstResponder
        let ownsResponder = [sidebarChild.view, detailChild.view].contains { root in
            guard let responderView = responder as? NSView else { return false }
            return responderView === root || responderView.isDescendant(of: root)
        }
        let order = SidebarSubviewOrder(
            sidebar: sidebarPaneContainer, detail: detailChild.view, position: position
        )
        splitView.sortSubviews(
            { lhs, rhs, context in
                guard let context else { return .orderedSame }
                return Unmanaged<SidebarSubviewOrder>.fromOpaque(context)
                    .takeUnretainedValue().compare(lhs, rhs)
            }, context: Unmanaged.passUnretained(order).toOpaque())
        splitView.adjustSubviews()
        if isSidebarHidden {
            applyHiddenPosition()
            if preservesVisibleOverlay {
                layoutOverlay(presented: true)
                overlayAnimator?.cancelAndSettle(
                    presented: true,
                    width: sidebarHostClipView.bounds.width,
                    position: position)
                sidebarHostClipView.isHidden = false
                sidebarChild.view.setAccessibilityHidden(false)
                hostMode = .overlay(width: sidebarHostClipView.bounds.width)
                hostPresentationState.settle(
                    mode: hostMode,
                    effectiveVisibleWidth: sidebarHostClipView.bounds.width)
            } else if case .overlay = hostMode {
                layoutOverlay(presented: true)
            }
        } else {
            applyPosition(width)
            // The reserved pane just moved to the other side; mirror it so the host
            // follows the new leading/trailing origin.
            syncSidebarHostFrame()
        }
        if ownsResponder, view.window?.firstResponder !== responder {
            view.window?.makeFirstResponder(responder)
        }
    }

    func setSidebarHidden(_ hidden: Bool) {
        setPersistentSidebarVisible(!hidden)
    }

    @discardableResult
    func setPersistentSidebarVisible(_ visible: Bool) -> Bool {
        guard !isFinalized else { return false }
        return applyPersistentSidebarVisible(visible) == .applied
    }

    func deliverPersistentSidebarVisible(
        _ visible: Bool
    ) -> SidebarPersistentVisibilityDeliveryResult {
        guard !isFinalized else { return .deferredUntilHostReady }
        guard
            isViewLoaded,
            splitView.bounds.width > 0,
            sidebarHostView.layer != nil
        else { return .deferredUntilHostReady }
        return applyPersistentSidebarVisible(visible)
    }

    private func applyPersistentSidebarVisible(
        _ visible: Bool
    ) -> SidebarPersistentVisibilityDeliveryResult {
        if visible {
            if !isSidebarHidden, case .persistent = hostMode { return .applied }
            return performAtomicPersistentShow()
        } else {
            if isSidebarHidden, hostMode == .hidden { return .applied }
            return performAtomicPersistentHide()
        }
    }

    func setEdgeTrackingEnabled(_ enabled: Bool) {
        guard enabled != isEdgeTrackingEnabled else { return }
        isEdgeTrackingEnabled = enabled
        guard isViewLoaded else { return }
        edgeTrackingView.isHidden = !enabled
        if enabled {
            installEdgeMouseMovedMonitorIfNeeded()
        } else {
            removeEdgeMouseMovedMonitor()
            edgeTrackingView.invalidatePointer()
        }
    }

    func sidebarPointerChanged(_ inside: Bool) {
        interactionMonitor?.pointerChanged(inside)
    }

    func resampleSidebarPointer() -> Bool? {
        guard isViewLoaded, let window = view.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: currentMouseLocation())
        edgeTrackingView.synchronizePointer(locationInWindow: windowPoint)
        let sidebarPoint = sidebarChild.view.convert(windowPoint, from: nil)
        return sidebarChild.view.bounds.contains(sidebarPoint)
    }

    func installCommandHandlers(on proxy: SidebarSplitProxy) {
        guard !isFinalized else { return }
        proxy.setSelectedWidth = { [weak self] width in
            self?.setSelectedSidebarWidth(width)
        }
        proxy.setOverlayVisible = { [weak self] visible, transition, reduceMotion in
            self?.setOverlayPresented(
                visible, transition: transition, reduceMotion: reduceMotion) == true
        }
        proxy.setPersistentVisible = { [weak self] visible in
            guard let self else { return .deferredUntilHostReady }
            return self.deliverPersistentSidebarVisible(visible)
        }
        proxy.setPosition = { [weak self] position in
            self?.setSidebarPosition(position)
        }
        proxy.sidebarPointerChanged = { [weak self] inside in
            self?.sidebarPointerChanged(inside)
        }
        proxy.resampleSidebarPointer = { [weak self] in
            self?.resampleSidebarPointer()
        }
        installedCommandProxy = proxy
        installedCommandHostGeneration = proxy.commandHostDidInstall()
        didPublishUsableCommandHost = false
        publishCommandHostUsableIfNeeded()
    }

    private func publishCommandHostUsableIfNeeded() {
        guard
            !isFinalized,
            !didPublishUsableCommandHost,
            let proxy = installedCommandProxy,
            let generation = installedCommandHostGeneration,
            isViewLoaded,
            splitView.bounds.width > 0,
            sidebarHostView.layer != nil
        else { return }
        didPublishUsableCommandHost = true
        proxy.commandHostBecameUsable(for: generation)
    }

    func simulateDividerDragCompletionForTesting() {
        splitView.onDragEnded?()
    }

    var edgeTrackingFrameForTesting: CGRect { edgeTrackingView.frame }
    var edgeTrackingViewForTesting: SidebarEdgeTrackingView { edgeTrackingView }
    var isEdgeTrackingVisibleForTesting: Bool { !edgeTrackingView.isHidden }
    var splitPaneViewsForTesting: [NSView] { splitView.subviews }
    var splitViewForTesting: NSSplitView { splitView }
    var dividerThicknessForTesting: CGFloat { splitView.dividerThickness }
    var sidebarPaneContainerForTesting: NSView { sidebarPaneContainer }
    var sidebarHostViewForTesting: NSView { sidebarHostView }
    var sidebarHostFrameForTesting: CGRect { sidebarHostClipView.frame }
    var sidebarPaneFrameForTesting: CGRect { sidebarPaneContainer.frame }
    var sidebarHostClipViewForTesting: SidebarHostClipView { sidebarHostClipView }
    var hostModeForTesting: SidebarHostMode { hostMode }
    var sidebarSplitPaneWidthForTesting: CGFloat { sidebarPaneContainer.frame.width }
    func resampleSidebarPointerForTesting() -> Bool? { resampleSidebarPointer() }
    #if DEBUG
        var splitPositionMutationIntentCountForTesting: Int { splitPositionMutationIntentCount }
    #endif
    var sidebarHostOccurrenceCountForTesting: Int {
        [sidebarPaneContainer, sidebarHostView].filter {
            sidebarChild.view === $0 || sidebarChild.view.isDescendant(of: $0)
        }.count
    }
    var interactionObserverCountForTesting: Int {
        interactionMonitor?.observerCountForTesting ?? 0
    }
    var isFinalizedForTesting: Bool { isFinalized }
    func simulateTrackingAvailabilityLostForTesting() {
        onTrackingAvailabilityLost?()
    }
    func simulateEdgePointerMoveForTesting(x: CGFloat, width: CGFloat) {
        edgeTrackingView.onPointerMove?(x, width)
    }
    func simulateEdgeExitForTesting() {
        edgeTrackingView.onExit?()
    }

    #if DEBUG
        func resetGeometryInstrumentationForTesting() {
            splitPositionMutationIntentCount = 0
            isGeometryInstrumentationArmedForTesting = true
        }

        func stopGeometryInstrumentationForTesting() {
            isGeometryInstrumentationArmedForTesting = false
        }
    #endif

    static func dividerCoordinate(
        forSidebarWidth width: CGFloat,
        paneExtent: CGFloat,
        position: AppearanceConfig.SidebarPosition
    ) -> CGFloat {
        let extent = paneExtent.isFinite ? max(0, paneExtent) : 0
        let safeWidth = width.isFinite ? min(max(0, width), extent) : 0
        return position == .left ? safeWidth : extent - safeWidth
    }

    static func sidebarWidth(
        forDividerCoordinate coordinate: CGFloat,
        paneExtent: CGFloat,
        position: AppearanceConfig.SidebarPosition
    ) -> CGFloat {
        let extent = paneExtent.isFinite ? max(0, paneExtent) : 0
        let safeCoordinate = coordinate.isFinite ? min(max(0, coordinate), extent) : 0
        return position == .left ? safeCoordinate : extent - safeCoordinate
    }

    /// Pure clamp, factored out for unit testing.
    static func clampedWidth(_ proposed: CGFloat, maxWidth: CGFloat) -> CGFloat {
        SidebarWidthPolicy.constrainedLiveWidth(for: proposed, maxWidth: maxWidth)
    }

    /// What a layout-pass reclamp should do. Pure, so the drag-gating policy is
    /// unit-testable without a live `NSSplitView`.
    enum ReclampAction: Equatable {
        case restoreExpanded(CGFloat)
        case clamp(CGFloat)
        case none
    }

    /// Decide the reclamp for one layout pass.
    ///
    /// Restore-on-grow is suppressed during an active divider drag: layout ticks
    /// run inside the drag's nested run loop and `userChoseRail` only flips on
    /// commit, so a sidebar being dragged toward the rail from an expanded start
    /// would satisfy `shouldRestoreExpanded` and get yanked back out — the rail
    /// becomes unreachable by dragging (regression from INT-535 #206).
    ///
    /// The terminal-starvation clamp is NOT suppressed during a drag: a window
    /// shrink concurrent with the drag (display disconnect, Stage Manager) must
    /// still pull the sidebar in so the terminal can't fall below its minimum.
    /// `constrainMaxCoordinate` misses window resizes (see `viewDidLayout`), so the
    /// clamp is the only guard there; it can't fight a real drag because the user
    /// can't drag the divider past `constrainMaxCoordinate` in the first place.
    static func reclampAction(
        currentWidth: CGFloat,
        maxWidth: CGFloat,
        lastExpandedWidth: CGFloat,
        userChoseRail: Bool,
        isDraggingDivider: Bool
    ) -> ReclampAction {
        if !isDraggingDivider,
            SidebarWidthPolicy.shouldRestoreExpanded(
                currentWidth: currentWidth, maxWidth: maxWidth, userChoseRail: userChoseRail
            )
        {
            return .restoreExpanded(lastExpandedWidth)
        }
        let clamped = clampedWidth(currentWidth, maxWidth: maxWidth)
        return clamped == currentWidth ? .none : .clamp(clamped)
    }

    // MARK: - Internals

    private func handOffSidebarFocusIfNeeded(requiresAccessibilityFocus: Bool) -> Bool {
        let window = view.window
        let responderView = window?.firstResponder as? NSView
        let sidebarKeyboardFocus = sidebarKeyboardFocusView(for: responderView)
        let keyboardFocusIsInSidebar = sidebarKeyboardFocus != nil
        guard keyboardFocusIsInSidebar || requiresAccessibilityFocus else { return true }
        let originalResponder = keyboardFocusOwner(for: responderView)
        let originalSidebarAccessibilityElement =
            requiresAccessibilityFocus ? focusedSidebarAccessibilityElement : nil

        let request = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: keyboardFocusIsInSidebar,
            requiresAccessibilityFocus: requiresAccessibilityFocus)
        let outcome = onSidebarFocusHandoff?(request)
        let keyboardHandoffSucceeded =
            !keyboardFocusIsInSidebar
            || outcome.map { hasVerifiedKeyboardFocus($0, in: window) } == true
        let accessibilityHandoffSucceeded =
            !requiresAccessibilityFocus
            || outcome.map { hasVerifiedAccessibilityFocus($0, in: window) } == true
        guard keyboardHandoffSucceeded, accessibilityHandoffSucceeded else {
            restoreSidebarFocus(
                responder: originalResponder,
                accessibilityElement: originalSidebarAccessibilityElement,
                in: window)
            return false
        }
        if requiresAccessibilityFocus,
            let element = originalSidebarAccessibilityElement as? NSAccessibilityProtocol,
            sidebarContainsAccessibilityElement(element)
        {
            element.setAccessibilityFocused(false)
        }
        return true
    }

    private func sidebarKeyboardFocusView(for responder: NSResponder?) -> NSView? {
        guard let view = responder as? NSView else { return nil }
        if let fieldEditor = view as? NSTextView,
            fieldEditor.isFieldEditor,
            let owner = fieldEditor.delegate as? NSView,
            owner === sidebarChild.view || owner.isDescendant(of: sidebarChild.view)
        {
            return owner
        }
        if view === sidebarChild.view || view.isDescendant(of: sidebarChild.view) {
            return view
        }
        return nil
    }

    private func clearSidebarKeyboardFocusIfNeeded(in window: NSWindow?) -> Bool {
        guard let window,
            sidebarKeyboardFocusView(for: window.firstResponder) != nil
        else { return true }
        window.endEditing(for: nil)
        if sidebarKeyboardFocusView(for: window.firstResponder) == nil {
            return true
        }
        guard window.makeFirstResponder(nil) else { return false }
        return sidebarKeyboardFocusView(for: window.firstResponder) == nil
    }

    private func keyboardFocusOwner(for responder: NSResponder?) -> NSView? {
        guard let view = responder as? NSView else { return nil }
        if let fieldEditor = view as? NSTextView,
            fieldEditor.isFieldEditor,
            let owner = fieldEditor.delegate as? NSView
        {
            return owner
        }
        return view
    }

    private func hasVisibleKeyboardFocusOutsideSidebar(in window: NSWindow?) -> Bool {
        guard let window, let responderView = window.firstResponder as? NSView,
            sidebarKeyboardFocusView(for: responderView) == nil
        else { return false }
        let focusView = keyboardFocusOwner(for: responderView) ?? responderView
        return isVisibleKeyView(focusView, in: window)
    }

    private func hasVerifiedKeyboardFocus(
        _ outcome: SidebarFocusHandoffOutcome,
        in window: NSWindow?
    ) -> Bool {
        guard outcome.keyboardFocusSucceeded,
            let window,
            isValidHandoffDestination(outcome.destination, in: window),
            let responder = window.firstResponder
        else { return false }
        return keyboardFocusOwner(for: responder) === outcome.destination
    }

    private func hasVerifiedAccessibilityFocus(
        _ outcome: SidebarFocusHandoffOutcome,
        in window: NSWindow?
    ) -> Bool {
        guard outcome.accessibilityFocusSucceeded,
            let window,
            isValidHandoffDestination(outcome.destination, in: window),
            outcome.destination.isAccessibilityFocused(),
            let focusedElement = currentFocusedAccessibilityElement
        else { return false }
        return SidebarInteractionMonitor.containsAccessibilityElement(
            focusedElement, in: outcome.destination)
    }

    private func isValidHandoffDestination(_ destination: NSView, in window: NSWindow) -> Bool {
        guard destination.window === window,
            let root = window.contentView,
            destination === root || destination.isDescendant(of: root),
            destination !== sidebarChild.view,
            !destination.isDescendant(of: sidebarChild.view)
        else { return false }
        return isVisibleKeyView(destination, in: window)
    }

    private func hasVisibleAccessibilityFocusOutsideSidebar(in window: NSWindow) -> Bool {
        guard window.isVisible, window.isKeyWindow,
            let root = window.contentView,
            let element = currentFocusedAccessibilityElement,
            !sidebarContainsAccessibilityElement(element),
            SidebarInteractionMonitor.containsAccessibilityElement(element, in: root),
            let focusView = accessibilityFocusView(for: element)
        else { return false }
        return isVisibleKeyView(focusView, in: window)
    }

    private func accessibilityFocusView(for element: Any) -> NSView? {
        SidebarInteractionMonitor.accessibilityAncestorView(of: element)
    }

    private func isVisibleKeyView(_ view: NSView, in window: NSWindow) -> Bool {
        guard view.window === window, let root = window.contentView else { return false }
        var current: NSView? = view
        while let ancestor = current {
            if ancestor.isHidden || ancestor.alphaValue == 0 { return false }
            current = ancestor.superview
        }

        let clippedBounds = view.bounds.intersection(view.visibleRect)
        guard !clippedBounds.isEmpty else { return false }
        let frameInRoot = view.convert(clippedBounds, to: root)
        let rootVisibleBounds = root.bounds.intersection(root.visibleRect)
        return !frameInRoot.intersection(rootVisibleBounds).isEmpty
    }

    private func restoreSidebarFocus(
        responder: NSView?,
        accessibilityElement: Any?,
        in window: NSWindow?
    ) {
        guard isFocusHandoffReady(in: window) else { return }
        if let window, let responder, isVisibleKeyView(responder, in: window) {
            window.makeFirstResponder(responder)
        }
        if let accessibilityElement = accessibilityElement as? NSAccessibilityProtocol,
            sidebarContainsAccessibilityElement(accessibilityElement)
        {
            accessibilityElement.setAccessibilityFocused(true)
        }
    }

    private func isFocusHandoffReady(in window: NSWindow?) -> Bool {
        applicationIsActive() && window?.isVisible == true && window?.isKeyWindow == true
    }

    private func performAtomicPersistentShow() -> SidebarPersistentVisibilityDeliveryResult {
        guard isViewLoaded, splitView.bounds.width > 0, sidebarHostView.layer != nil else {
            if isSidebarHidden {
                setEdgeTrackingEnabled(true)
            }
            return .deferredUntilHostReady
        }
        // The sidebar never moves — it already lives in `sidebarHostView`. This is
        // a pure geometry settle: the reserved pane expands and the host mirrors it.
        overlayAnimator?.cancelAndSettle(
            presented: true, width: sidebarHostClipView.bounds.width, position: sidebarPosition)
        sidebarHostView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
        isSidebarHidden = false
        let target = Self.clampedWidth(selectedSidebarWidth, maxWidth: maxSidebarWidth)
        pendingWidth = nil
        hostMode = .persistent(width: target)
        // Keep the zero-duration / disabled-actions wrapper: the layer-transform,
        // clip-visibility, divider, and a11y mutations can still expose one-frame
        // implicit-animation mismatches even though nothing reparents anymore.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            sidebarChild.view.setAccessibilityHidden(false)
            setDividerPosition(target)
            splitView.layoutSubtreeIfNeeded()
            syncSidebarHostFrame()
        }
        let rendered = sidebarPaneWidth
        hostMode = .persistent(width: rendered)
        recordIfExpanded(rendered)
        onLiveWidthChange?(rendered)
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: rendered)
        setEdgeTrackingEnabled(false)
        removeInteractionMonitor()
        pendingFocusRepair = nil
        return .applied
    }

    private func performAtomicPersistentHide() -> SidebarPersistentVisibilityDeliveryResult {
        if isViewLoaded {
            let requiresAccessibilityFocus = sidebarAccessibilityFocusIsActive
            let requiresKeyboardFocus =
                sidebarKeyboardFocusView(for: view.window?.firstResponder) != nil
            if requiresKeyboardFocus || requiresAccessibilityFocus,
                !isFocusHandoffReady(in: view.window)
            {
                pendingFocusRepair = SidebarApplicationFocusRecovery(
                    request: SidebarFocusHandoffRequest(
                        requiresKeyboardFocus: requiresKeyboardFocus,
                        requiresAccessibilityFocus: requiresAccessibilityFocus),
                    sidebarAccessibilityElement: requiresAccessibilityFocus
                        ? focusedSidebarAccessibilityElement : nil)
                guard clearSidebarKeyboardFocusIfNeeded(in: view.window) else {
                    pendingFocusRepair = nil
                    return .rejected
                }
            } else {
                guard
                    handOffSidebarFocusIfNeeded(
                        requiresAccessibilityFocus: requiresAccessibilityFocus)
                else { return .rejected }
            }
        }
        guard isViewLoaded, splitView.bounds.width > 0, sidebarHostView.layer != nil else {
            isSidebarHidden = true
            settleHidden()
            applyHiddenPosition()
            setEdgeTrackingEnabled(true)
            return .applied
        }
        pendingWidth = selectedSidebarWidth
        recordIfExpanded(sidebarPaneWidth)
        // Keep the zero-duration / disabled-actions wrapper around the settlement
        // block: the host frame collapse, layer-transform reset, clip-visibility,
        // divider, and a11y mutations can still expose one-frame implicit-animation
        // mismatches even though nothing reparents anymore.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            overlayAnimator?.cancelAndSettle(
                presented: false, width: sidebarHostClipView.bounds.width, position: sidebarPosition)
            sidebarHostView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
            interactionMonitor?.pointerChanged(false)
            isSidebarHidden = true
            hostMode = .hidden
            applyHiddenPosition()
            splitView.layoutSubtreeIfNeeded()
            // The sidebar renders from the root container full-time; collapse the
            // host onto the now-zero-width spacer pane so a hidden sidebar has zero
            // width (the moved-into-collapsing-pane behavior the old dual host gave).
            sidebarHostClipView.frame = sidebarPaneContainer.frame
            sidebarHostView.frame = sidebarHostClipView.bounds
            sidebarChild.view.frame = sidebarHostView.bounds
            sidebarHostView.layer?.transform = CATransform3DIdentity
            sidebarHostClipView.isHidden = true
            sidebarChild.view.setAccessibilityHidden(true)
        }
        removeInteractionMonitor()
        hostPresentationState.settle(mode: .hidden, effectiveVisibleWidth: 0)
        hostPresentationState.beginOverlayTransition(
            presented: false,
            width: selectedSidebarWidth,
            position: sidebarPosition)
        setEdgeTrackingEnabled(true)
        return .applied
    }

    private var sidebarPaneWidth: CGFloat {
        sidebarPaneContainer.frame.width
    }

    /// One host: the split's sidebar pane is an empty width reservation; the
    /// sidebar renders from this root-level container, which mirrors the pane
    /// frame whenever the sidebar is persistently visible. In HIDDEN mode the
    /// overlay path (`layoutOverlay`) is the geometry authority instead — the two
    /// are mutually exclusive on `isSidebarHidden`.
    private func syncSidebarHostFrame() {
        guard !isSidebarHidden else { return }
        sidebarHostClipView.frame = sidebarPaneContainer.frame
        sidebarHostView.frame = sidebarHostClipView.bounds
        sidebarChild.view.frame = sidebarHostView.bounds
        sidebarHostView.layer?.transform = CATransform3DIdentity
        sidebarHostClipView.isHidden = false
        sidebarHostClipView.presentationTranslationX = { 0 }
    }

    private func settleHidden() {
        interactionMonitor?.pointerChanged(false)
        overlayAnimator?.cancelAndSettle(
            presented: false, width: sidebarHostView.bounds.width, position: sidebarPosition)
        sidebarHostView.layer?.setAffineTransform(.identity)
        sidebarHostClipView.isHidden = true
        hostMode = .hidden
        sidebarChild.view.setAccessibilityHidden(true)
        hostPresentationState.settle(mode: .hidden, effectiveVisibleWidth: 0)
        hostPresentationState.beginOverlayTransition(
            presented: false,
            width: selectedSidebarWidth,
            position: sidebarPosition)
        removeInteractionMonitor()
    }

    private var sidebarAccessibilityFocusIsActive: Bool {
        if let hasActiveSidebarAccessibilityFocus {
            return hasActiveSidebarAccessibilityFocus()
        }
        if let interactionMonitor {
            return interactionMonitor.hasAccessibilityFocus
        }
        return focusedSidebarAccessibilityElement != nil
    }

    private var focusedSidebarAccessibilityElement: Any? {
        if let sidebarAccessibilityFocusedElement {
            guard let element = sidebarAccessibilityFocusedElement() else { return nil }
            return sidebarContainsAccessibilityElement(element) ? element : nil
        }
        if let interactionMonitor {
            return interactionMonitor.focusedAccessibilityElementInsideSidebar
        }
        let element = currentFocusedAccessibilityElement
        guard let element else { return nil }
        return sidebarContainsAccessibilityElement(element) ? element : nil
    }

    private var currentFocusedAccessibilityElement: Any? {
        interactionFocusedAccessibilityElement?()
            ?? NSApp.accessibilityFocusedUIElement
    }

    private func sidebarContainsAccessibilityElement(_ element: Any) -> Bool {
        interactionMonitor?.containsAccessibilityElement(element)
            ?? SidebarInteractionMonitor.containsAccessibilityElement(
                element, in: sidebarChild.view)
    }

    private func installInteractionMonitor() {
        guard isViewLoaded, case .overlay = hostMode, interactionMonitor == nil else { return }
        interactionMonitor = SidebarInteractionMonitor(
            sidebarRoot: sidebarChild.view,
            focusedAccessibilityElement: interactionFocusedAccessibilityElement,
            notificationCenter: interactionNotificationCenter,
            isAccessibilityRefreshRelevant: { [weak self] in
                guard let self, case .overlay = self.hostMode else { return false }
                return true
            },
            onActiveChange: { [weak self] active in
                self?.onSidebarInteractionChanged?(active)
            })
    }

    private func removeInteractionMonitor() {
        interactionMonitor?.detach()
        interactionMonitor = nil
    }

    func settleDetached() {
        pendingFocusRepair = nil
        removeApplicationActivityObservers()
        removeEdgeMouseMovedMonitor()
        edgeTrackingView.invalidatePointer()
        removeInteractionMonitor()
        guard isViewLoaded else { return }
        overlayAnimator?.cancelAndSettle(
            presented: false,
            width: sidebarHostClipView.bounds.width,
            position: sidebarPosition)
        sidebarHostView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
        if isSidebarHidden {
            settleHidden()
        } else {
            // The sidebar stays in the permanent root host; a reattach layout
            // re-mirrors it via `syncSidebarHostFrame`. Hiding the host here matches
            // the prior detach resting state and avoids a stale frame flash.
            sidebarHostView.layer?.transform = CATransform3DIdentity
            sidebarHostClipView.isHidden = true
            sidebarChild.view.setAccessibilityHidden(true)
            hostMode = .persistent(width: sidebarPaneWidth)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: sidebarPaneWidth)
        }
    }

    private func settleAttached() {
        guard !isFinalized else { return }
        installApplicationActivityObserversIfNeeded()
        installEdgeMouseMovedMonitorIfNeeded()
        if case .overlay = hostMode {
            installInteractionMonitor()
        }
        guard !isSidebarHidden, case .persistent = hostMode else { return }
        sidebarChild.view.setAccessibilityHidden(false)
        hostPresentationState.settle(
            mode: hostMode, effectiveVisibleWidth: sidebarPaneWidth)
    }

    private func clearExternalCallbacks() {
        onLiveWidthChange = nil
        onCommitWidth = nil
        onSidebarFocusHandoff = nil
        onEdgePointerMove = nil
        onEdgeExit = nil
        onTrackingAvailabilityLost = nil
        hasActiveSidebarAccessibilityFocus = nil
        sidebarAccessibilityFocusedElement = nil
        onSidebarInteractionChanged = nil
    }

    func finalizeOwnedLifecycle() {
        guard !isFinalized else { return }
        isFinalized = true
        interactionMonitor?.detach()
        interactionMonitor = nil
        clearExternalCallbacks()
        guard isViewLoaded else { return }
        settleDetached()
    }

    private func settleFinal() {
        finalizeOwnedLifecycle()
    }

    private func installEdgeMouseMovedMonitorIfNeeded() {
        guard
            isEdgeTrackingEnabled,
            isViewLoaded,
            let owningWindow = view.window
        else { return }
        if let localMouseMovedWindow, localMouseMovedWindow !== owningWindow {
            removeEdgeMouseMovedMonitor()
        }
        guard localMouseMovedMonitor == nil else { return }
        let previouslyAcceptedEvents = owningWindow.acceptsMouseMovedEvents
        owningWindow.acceptsMouseMovedEvents = true
        guard
            let monitor = addLocalMouseMovedMonitor(
                .mouseMoved,
                { [weak self] event in
                    guard
                        let self,
                        self.acceptsApplicationPointerEvents,
                        let owningWindow = self.view.window,
                        event.window === owningWindow
                    else { return event }
                    self.edgeTrackingView.synchronizePointer(locationInWindow: event.locationInWindow)
                    return event
                })
        else {
            owningWindow.acceptsMouseMovedEvents = previouslyAcceptedEvents
            return
        }
        localMouseMovedWindow = owningWindow
        localMouseMovedWindowPreviouslyAcceptedEvents = previouslyAcceptedEvents
        localMouseMovedMonitor = monitor
    }

    private func removeEdgeMouseMovedMonitor() {
        if let localMouseMovedMonitor {
            removeLocalMouseMovedMonitor(localMouseMovedMonitor)
        }
        localMouseMovedWindow?.acceptsMouseMovedEvents =
            localMouseMovedWindowPreviouslyAcceptedEvents
        self.localMouseMovedMonitor = nil
        localMouseMovedWindow = nil
        localMouseMovedWindowPreviouslyAcceptedEvents = false
    }

    private func installApplicationActivityObserversIfNeeded() {
        guard applicationActivityObservations.isEmpty else { return }
        acceptsApplicationPointerEvents = applicationIsActive()
        edgeTrackingView.acceptsPointerUpdates = acceptsApplicationPointerEvents
        applicationActivityObservations.append(
            interactionNotificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.acceptsApplicationPointerEvents = false
                    self.edgeTrackingView.acceptsPointerUpdates = false
                    if self.isSidebarHidden {
                        let existingRecovery = self.pendingFocusRepair
                        let currentAccessibilityFocus =
                            self.sidebarAccessibilityFocusIsActive
                        let currentKeyboardFocus =
                            self.sidebarKeyboardFocusView(
                                for: self.view.window?.firstResponder) != nil
                        let requiresKeyboardFocus =
                            existingRecovery?.request.requiresKeyboardFocus == true
                            || currentKeyboardFocus
                        let requiresAccessibilityFocus =
                            existingRecovery?.request.requiresAccessibilityFocus == true
                            || currentAccessibilityFocus
                        if requiresKeyboardFocus || requiresAccessibilityFocus {
                            let currentSidebarAccessibilityElement =
                                currentAccessibilityFocus
                                ? self.focusedSidebarAccessibilityElement : nil
                            self.pendingFocusRepair = SidebarApplicationFocusRecovery(
                                request: SidebarFocusHandoffRequest(
                                    requiresKeyboardFocus: requiresKeyboardFocus,
                                    requiresAccessibilityFocus: requiresAccessibilityFocus),
                                sidebarAccessibilityElement: requiresAccessibilityFocus
                                    ? currentSidebarAccessibilityElement
                                        ?? existingRecovery?.sidebarAccessibilityElement
                                    : nil)
                            _ = self.clearSidebarKeyboardFocusIfNeeded(in: self.view.window)
                        }
                    } else {
                        self.pendingFocusRepair = nil
                    }
                    self.onTrackingAvailabilityLost?()
                    if self.isSidebarHidden {
                        self.settleHidden()
                    }
                }
            })
        applicationActivityObservations.append(
            interactionNotificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.acceptsApplicationPointerEvents = true
                    self.edgeTrackingView.acceptsPointerUpdates = true
                    // AppKit does not guarantee `didBecomeKey` fires after the app is
                    // active. On a key-first reactivation (the primary window is already
                    // key when the app reactivates) the repair's app-active guard skips
                    // the `didBecomeKey` firing and nothing retries, stranding a pending
                    // repair. Retrying on activation closes that ordering hole; every
                    // precondition is re-checked inside `recoverApplicationFocusIfReady`,
                    // so a redundant fire on the ordinary path is a no-op.
                    guard let window = self.view.window else { return }
                    self.recoverApplicationFocusIfReady(in: window)
                }
            })
        applicationActivityObservations.append(
            interactionNotificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow else { return }
                    self.windowDidBecomeKey(window)
                }
            })
        applicationActivityObservations.append(
            interactionNotificationCenter.addObserver(
                forName: GhosttySurfaceFocusReadiness.didBecomeReadyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let self,
                        self.pendingFocusRepair != nil,
                        let surface = GhosttySurfaceFocusReadiness.surface(from: notification),
                        let window = self.view.window,
                        surface.window === window,
                        window.isAwesoMuxPrimaryContentWindow,
                        self.applicationIsActive(),
                        window.isVisible,
                        window.isKeyWindow
                    else { return }
                    self.recoverApplicationFocusIfReady(in: window)
                }
            })
    }

    private func windowDidBecomeKey(_ window: NSWindow) {
        guard pendingFocusRepair != nil else { return }
        guard window === view.window else { return }
        recoverApplicationFocusIfReady(in: window)
    }

    private func recoverApplicationFocusIfReady(in window: NSWindow) {
        guard pendingFocusRepair != nil,
            applicationIsActive(),
            window === view.window,
            window.isVisible,
            window.isKeyWindow
        else { return }
        reduceApplicationFocusRecovery(for: window)
        guard let recovery = pendingFocusRepair else { return }

        let outcome = onSidebarFocusHandoff?(recovery.request)
        let keyboardSucceeded =
            !recovery.request.requiresKeyboardFocus
            || outcome.map { hasVerifiedKeyboardFocus($0, in: window) } == true
        let accessibilitySucceeded =
            !recovery.request.requiresAccessibilityFocus
            || outcome.map { hasVerifiedAccessibilityFocus($0, in: window) } == true
        if keyboardSucceeded, accessibilitySucceeded {
            if recovery.request.requiresAccessibilityFocus,
                let element = recovery.sidebarAccessibilityElement as? NSAccessibilityProtocol,
                sidebarContainsAccessibilityElement(element)
            {
                element.setAccessibilityFocused(false)
            }
            pendingFocusRepair = nil
            return
        }
        pendingFocusRepair = SidebarApplicationFocusRecovery(
            request: SidebarFocusHandoffRequest(
                requiresKeyboardFocus: !keyboardSucceeded,
                requiresAccessibilityFocus: !accessibilitySucceeded),
            sidebarAccessibilityElement: accessibilitySucceeded
                ? nil : recovery.sidebarAccessibilityElement)
    }

    private func reduceApplicationFocusRecovery(for window: NSWindow) {
        guard let recovery = pendingFocusRepair,
            window.isVisible,
            window.isKeyWindow
        else { return }
        let requiresKeyboardFocus =
            recovery.request.requiresKeyboardFocus
            && !hasVisibleKeyboardFocusOutsideSidebar(in: window)
        let requiresAccessibilityFocus =
            recovery.request.requiresAccessibilityFocus
            && !hasVisibleAccessibilityFocusOutsideSidebar(in: window)
        guard requiresKeyboardFocus || requiresAccessibilityFocus else {
            pendingFocusRepair = nil
            return
        }
        pendingFocusRepair = SidebarApplicationFocusRecovery(
            request: SidebarFocusHandoffRequest(
                requiresKeyboardFocus: requiresKeyboardFocus,
                requiresAccessibilityFocus: requiresAccessibilityFocus),
            sidebarAccessibilityElement: requiresAccessibilityFocus
                ? recovery.sidebarAccessibilityElement : nil)
    }

    private func removeApplicationActivityObservers() {
        applicationActivityObservations.forEach(interactionNotificationCenter.removeObserver)
        applicationActivityObservations.removeAll()
    }

    private func invalidateOverlayForDetach() {
        settleDetached()
    }

    private func finishOverlayTransition(presented: Bool) {
        hostPresentationState.setOverlayAnimating(false)
        if presented {
            sidebarChild.view.setAccessibilityHidden(false)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: sidebarHostClipView.bounds.width)
        } else {
            settleHidden()
        }
    }

    private func layoutOverlayPreservingAnimation(deferringPublication: Bool = false) {
        let oldWidth = sidebarHostClipView.bounds.width
        layoutOverlay(presented: true)
        let newWidth = sidebarHostClipView.bounds.width
        hostMode = .overlay(width: newWidth)
        if deferringPublication {
            // viewDidLayout path: writing @Observable state synchronously inside an
            // AppKit layout pass invalidates the SwiftUI titlebar that owns this
            // representable and can re-enter layout (the codebase's documented
            // crash class). Frames are already applied above; publish one hop later.
            DispatchQueue.main.async { [weak self] in
                guard let self, case .overlay = self.hostMode else { return }
                self.publishOverlayLayout(oldWidth: oldWidth, newWidth: newWidth)
            }
        } else {
            publishOverlayLayout(oldWidth: oldWidth, newWidth: newWidth)
        }
    }

    private func publishOverlayLayout(oldWidth: CGFloat, newWidth: CGFloat) {
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: newWidth)
        guard oldWidth > 0, oldWidth != newWidth,
            let requestedPresented = overlayAnimator?.requestedPresentedState
        else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        overlayAnimator?.reframe(
            fromWidth: oldWidth,
            toWidth: newWidth,
            position: sidebarPosition,
            transition: .hover,
            reduceMotion: reduceMotion
        ) { [weak self] _ in
            self?.finishOverlayTransition(presented: requestedPresented)
        }
        hostPresentationState.setOverlayAnimating(overlayAnimator?.isAnimating == true)
    }

    private func layoutOverlay(presented: Bool) {
        let width = Self.dividerCoordinate(
            forSidebarWidth: selectedSidebarWidth, paneExtent: paneExtent, position: .left)
        let x = sidebarPosition == .left ? 0 : view.bounds.maxX - width
        sidebarHostClipView.frame = CGRect(x: x, y: 0, width: width, height: view.bounds.height)
        sidebarHostView.frame = sidebarHostClipView.bounds
        sidebarHostView.autoresizingMask = [.width, .height]
        sidebarChild.view.frame = sidebarHostView.bounds
        let hiddenTranslation = sidebarPosition == .left ? -width : width
        sidebarHostClipView.presentationTranslationX = { [weak overlayAnimator] in
            overlayAnimator?.currentTranslation ?? (presented ? 0 : hiddenTranslation)
        }
    }

    private var paneExtent: CGFloat {
        max(0, splitView.bounds.width - splitView.dividerThickness)
    }

    private func setDividerPosition(_ width: CGFloat) {
        let coordinate = Self.dividerCoordinate(
            forSidebarWidth: width, paneExtent: paneExtent, position: sidebarPosition
        )
        isSettingPositionProgrammatically = true
        #if DEBUG
            if isGeometryInstrumentationArmedForTesting {
                splitPositionMutationIntentCount += 1
            }
        #endif
        splitView.setPosition(coordinate, ofDividerAt: 0)
        isSettingPositionProgrammatically = false
    }

    private func applyPosition(_ width: CGFloat) {
        let target = Self.clampedWidth(width, maxWidth: maxSidebarWidth)
        setDividerPosition(target)
        let rendered = sidebarPaneWidth
        hostMode = .persistent(width: rendered)
        recordIfExpanded(rendered)
        // Report the rendered pane width, not just the requested target. AppKit
        // can preserve a wider child during first layout or constraint pressure;
        // SwiftUI's sidebar mode must follow the pane that actually rendered.
        onLiveWidthChange?(rendered)
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: rendered)
    }

    private func applyHiddenPosition() {
        // `sidebarPaneWidth > 0` is load-bearing: re-issuing setPosition(0) on an
        // already-collapsed pane from viewDidLayout is what caused the hidden
        // cold-launch layout recursion (see persistedHiddenColdLaunch regression
        // test). Do not "simplify" this guard back to a bounds-only check.
        guard isViewLoaded, splitView.bounds.width > 0, sidebarPaneWidth > 0 else { return }
        setDividerPosition(0)
    }

    /// Remember the last expanded width so restore-on-grow has a target. Rail
    /// widths are deliberately ignored — they are never a restore destination.
    private func recordIfExpanded(_ width: CGFloat) {
        if width >= SidebarWidthPolicy.railThreshold {
            lastExpandedPaneWidth = width
        }
    }

    private func reclampToBounds() {
        guard !isSidebarHidden, splitView.bounds.width > 0 else { return }
        switch Self.reclampAction(
            currentWidth: sidebarPaneWidth,
            maxWidth: maxSidebarWidth,
            lastExpandedWidth: lastExpandedPaneWidth,
            userChoseRail: userChoseRail,
            isDraggingDivider: splitView.isTrackingDividerDrag
        ) {
        // Both cases carry a target width and apply identically; only the pure
        // decision distinguishes restore-on-grow from a starvation clamp.
        case let .restoreExpanded(width), let .clamp(width):
            applyPosition(width)
        case .none:
            break
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if isSidebarHidden { return sidebarPosition == .left ? 0 : paneExtent }
        return sidebarPosition == .left
            ? SidebarWidthPolicy.collapsedWidth
            : terminalMinimumWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if isSidebarHidden { return sidebarPosition == .left ? 0 : paneExtent }
        return sidebarPosition == .left
            ? maxSidebarWidth
            : paneExtent - SidebarWidthPolicy.collapsedWidth
    }

    /// The sidebar is either the tight rail or a readable full-rows width — never
    /// parked in the dead zone between. Snapping a proposed divider position in that
    /// zone to the nearer edge means dragging out of the rail jumps straight to full
    /// rows (no wide, empty rail), and dragging in jumps straight to the tight rail.
    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if isSidebarHidden { return sidebarPosition == .left ? 0 : paneExtent }
        let width = Self.sidebarWidth(
            forDividerCoordinate: proposedPosition, paneExtent: paneExtent, position: sidebarPosition
        )
        let rail = SidebarWidthPolicy.collapsedWidth
        let full = SidebarWidthPolicy.railThreshold
        guard width > rail, width < full else { return proposedPosition }
        let snapped = width < (rail + full) / 2 ? rail : full
        return Self.dividerCoordinate(
            forSidebarWidth: snapped, paneExtent: paneExtent, position: sidebarPosition
        )
    }

    /// Sidebar holds its absolute width; the detail/terminal pane absorbs window
    /// resize. (Bare-NSSplitView equivalent of a high sidebar holdingPriority.)
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== sidebarPaneContainer
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Mirror the reserved pane into the host on every resize (divider drag,
        // programmatic setPosition, window layout). The sync is idempotent and
        // no-ops while hidden, so it is safe ahead of the echo-suppression guard.
        syncSidebarHostFrame()
        guard !isSettingPositionProgrammatically, !isSidebarHidden else {
            return
        }
        let width = sidebarPaneWidth
        // A user divider drag into expanded territory is the other source of a
        // restore target, so record it here too.
        recordIfExpanded(width)
        onLiveWidthChange?(width)
        hostMode = .persistent(width: width)
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: width)
    }
}

/// `NSSplitView` whose divider drag we can bracket: `mouseDown` runs AppKit's
/// synchronous divider-tracking loop, so `super.mouseDown` returns only once the
/// drag finishes — the moment to commit the settled width.
final class DividerTrackingSplitView: NSSplitView {
    var onDragEnded: (() -> Void)?
    var sidebarWidthProvider: (() -> CGFloat?)?
    var isPersistentSidebarHidden = false {
        didSet {
            guard isPersistentSidebarHidden != oldValue else { return }
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override var dividerThickness: CGFloat {
        isPersistentSidebarHidden ? 0 : super.dividerThickness
    }

    /// True for the duration of a user divider drag's synchronous tracking loop.
    /// Restore-on-grow must not fire inside that loop or it fights the drag and the
    /// rail becomes unreachable from an expanded sidebar (see
    /// `SidebarSplitController.reclampAction`).
    private(set) var isTrackingDividerDrag = false

    override func mouseDown(with event: NSEvent) {
        // Compare the semantic sidebar width supplied by the controller. Only
        // commit if the divider actually moved during the tracking loop — a bare click on the divider
        // (or a cancelled drag) leaves the width unchanged and shouldn't persist.
        let widthBefore = sidebarWidthProvider?()
        isTrackingDividerDrag = true
        // `defer` (not a trailing assignment) so an ObjC exception unwinding through
        // AppKit's nested tracking loop can't weld the flag true and permanently
        // no-op reclamp. It clears AFTER `onDragEnded` commits, so the flag is still
        // set while the commit flips `userChoseRail` — no flag-clear/stale-flag gap.
        defer { isTrackingDividerDrag = false }
        super.mouseDown(with: event)
        if sidebarWidthProvider?() != widthBefore {
            onDragEnded?()
        }
    }
}
