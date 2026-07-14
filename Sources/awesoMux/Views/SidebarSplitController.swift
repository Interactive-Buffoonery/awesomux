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
    /// Fires on every divider resize tick with the sidebar pane's live width.
    var onLiveWidthChange: ((CGFloat) -> Void)?

    /// Fires once when a user divider drag ends (wired in A6).
    var onCommitWidth: ((CGFloat) -> Void)?

    /// Moves focus out of the sidebar before it becomes zero-width. Returns
    /// whether the caller established a visible first responder.
    var onSidebarFocusHandoff: (() -> Bool)?

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
    private let overlayClipView = SidebarOverlayClipView()
    private let overlayContentView = NSView()
    private var overlayAnimator: SidebarOverlayAnimator?
    private var interactionMonitor: SidebarInteractionMonitor?
    private let sidebarChild: NSViewController
    private let detailChild: NSViewController
    var sidebarViewController: NSViewController { sidebarChild }
    var detailViewController: NSViewController { detailChild }
    private var sidebarPosition: AppearanceConfig.SidebarPosition = .left
    private var isSidebarHidden = false
    private var isEdgeTrackingEnabled = false
    private var hostMode: SidebarHostMode = .persistent(width: SidebarWidthPolicy.expandedWidth)
    private var selectedSidebarWidth: CGFloat = SidebarWidthPolicy.expandedWidth
    var hostPresentationState = SidebarHostPresentationState()
    var handoffActionObserverForTesting: ((SidebarHostHandoffAction) -> Void)?
    var persistentHandoffBeforeAccessibilityValidationForTesting: (() -> Void)?
    private let overlayAnimationRunner: SidebarOverlayAnimator.AnimationRunner?
    private let overlayPresentationTranslation: (() -> CGFloat?)?
    private let interactionFocusedAccessibilityElement: SidebarInteractionMonitor.FocusedAccessibilityElement?
    private let interactionNotificationCenter: NotificationCenter

    /// Set around our own `setPosition` calls so `splitViewDidResizeSubviews` (which
    /// also fires for programmatic position changes and window layout) does not echo
    /// a programmatic change back out as a "live" width change.
    private var isSettingPositionProgrammatically = false
    private var isPerformingHostHandoff = false
    #if DEBUG
        private var dividerIntentCount = 0
        private var isGeometryInstrumentationArmedForTesting = false
        private var splitPositionMutationIntentCount = 0
    #endif
    private(set) var lastCapturedSidebarAccessibilityFocusForTesting = false
    private(set) var lastPreservedSidebarAccessibilityElementForTesting = false

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
        interactionNotificationCenter: NotificationCenter = .default
    ) {
        sidebarChild = sidebar
        detailChild = detail
        self.overlayPresentationTranslation = overlayPresentationTranslation
        self.overlayAnimationRunner = overlayAnimationRunner
        self.interactionFocusedAccessibilityElement = interactionFocusedAccessibilityElement
        self.interactionNotificationCenter = interactionNotificationCenter
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
        sidebarChild.view.translatesAutoresizingMaskIntoConstraints = true
        sidebarPaneContainer.addSubview(sidebarChild.view)
        sidebarChild.view.frame = sidebarPaneContainer.bounds
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
            self?.installInteractionMonitor()
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
        overlayClipView.wantsLayer = true
        overlayClipView.layer?.masksToBounds = true
        overlayContentView.wantsLayer = true
        if let layer = overlayContentView.layer {
            overlayAnimator = SidebarOverlayAnimator(
                layer: layer,
                presentationTranslation: overlayPresentationTranslation,
                animationRunner: overlayAnimationRunner)
        }
        overlayClipView.contentView = overlayContentView
        overlayClipView.addSubview(overlayContentView)
        overlayClipView.isHidden = true
        root.addSubview(overlayClipView)
        root.addSubview(edgeTrackingView)
        view = root
        installInteractionMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitView.frame = view.bounds
        if case .overlay = hostMode { layoutOverlayPreservingAnimation() }
        let trackingWidth = min(SidebarPresentationModel.cueDistance, view.bounds.width)
        edgeTrackingView.frame = CGRect(
            x: sidebarPosition == .left ? 0 : view.bounds.width - trackingWidth,
            y: 0,
            width: trackingWidth,
            height: view.bounds.height
        )
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

    deinit {
        MainActor.assumeIsolated {
            settleFinal()
        }
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
            return
        }
        guard isViewLoaded, splitView.bounds.width > 0 else {
            pendingWidth = width
            return
        }
        applyPosition(width)
    }

    func setSelectedSidebarWidth(_ width: CGFloat) {
        selectedSidebarWidth = Self.clampedWidth(width, maxWidth: maxSidebarWidth)
        pendingWidth = selectedSidebarWidth
        switch hostMode {
        case .overlay:
            layoutOverlayPreservingAnimation()
            onLiveWidthChange?(selectedSidebarWidth)
        case .persistent:
            setSidebarWidth(selectedSidebarWidth)
        case .hidden:
            break
        }
    }

    func setOverlayPresentedImmediately(_ presented: Bool) {
        setOverlayPresented(presented, transition: .immediate, reduceMotion: true)
    }

    func setOverlayPresented(
        _ presented: Bool,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool
    ) {
        guard isSidebarHidden else { return }
        if presented {
            guard overlayContentView.layer != nil, overlayAnimator != nil else {
                reconcileStableHiddenOwnership()
                return
            }
            let wasStablyHidden = hostMode == .hidden
            moveSidebarHost(to: overlayContentView)
            overlayClipView.isHidden = false
            layoutOverlay(presented: false)
            hostMode = .overlay(width: selectedSidebarWidth)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: selectedSidebarWidth)
            if wasStablyHidden {
                overlayAnimator?.cancelAndSettle(
                    presented: false,
                    width: overlayClipView.bounds.width,
                    position: sidebarPosition)
            }
        } else {
            guard !sidebarAccessibilityFocusIsActive else { return }
            sidebarChild.view.setAccessibilityHidden(true)
        }
        overlayAnimator?.setPresented(
            presented,
            width: overlayClipView.bounds.width,
            position: sidebarPosition,
            transition: transition,
            reduceMotion: reduceMotion
        ) { [weak self] _ in
            self?.finishOverlayTransition(presented: presented)
        }
    }

    var maxSidebarWidth: CGFloat {
        max(SidebarWidthPolicy.collapsedWidth, paneExtent - terminalMinimumWidth)
    }

    func setSidebarPosition(_ position: AppearanceConfig.SidebarPosition) {
        guard position != sidebarPosition else { return }
        if isViewLoaded, isSidebarHidden, case .overlay = hostMode {
            overlayAnimator?.cancelAndSettle(
                presented: false, width: overlayClipView.bounds.width, position: sidebarPosition)
            reconcileStableHiddenOwnership()
        }
        let width = sidebarPaneWidth
        sidebarPosition = position
        edgeTrackingView.position = position
        guard isViewLoaded else { return }
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
            if case .overlay = hostMode { layoutOverlay(presented: true) }
        } else {
            applyPosition(width)
        }
        if ownsResponder, view.window?.firstResponder !== responder {
            view.window?.makeFirstResponder(responder)
        }
    }

    func setSidebarHidden(_ hidden: Bool) {
        setPersistentSidebarVisible(!hidden)
    }

    func setPersistentSidebarVisible(_ visible: Bool) {
        if visible {
            if !isSidebarHidden, case .persistent = hostMode { return }
            performAtomicPersistentShow()
        } else {
            if isSidebarHidden, hostMode == .hidden { return }
            performAtomicPersistentHide()
        }
    }

    func setEdgeTrackingEnabled(_ enabled: Bool) {
        guard enabled != isEdgeTrackingEnabled else { return }
        isEdgeTrackingEnabled = enabled
        guard isViewLoaded else { return }
        edgeTrackingView.isHidden = !enabled
        if !enabled {
            onEdgeExit?()
        }
    }

    func sidebarPointerChanged(_ inside: Bool) {
        interactionMonitor?.pointerChanged(inside)
    }

    func installPersistentVisibilityHandler(on proxy: SidebarSplitProxy) {
        proxy.setPersistentVisible = { [weak self] visible in
            self?.setPersistentSidebarVisible(visible)
        }
    }

    func simulateDividerDragCompletionForTesting() {
        splitView.onDragEnded?()
    }

    var edgeTrackingFrameForTesting: CGRect { edgeTrackingView.frame }
    var isEdgeTrackingVisibleForTesting: Bool { !edgeTrackingView.isHidden }
    var splitPaneViewsForTesting: [NSView] { splitView.subviews }
    var sidebarPaneContainerForTesting: NSView { sidebarPaneContainer }
    var overlayClipViewForTesting: SidebarOverlayClipView { overlayClipView }
    var overlayContentViewForTesting: NSView { overlayContentView }
    var hostModeForTesting: SidebarHostMode { hostMode }
    var sidebarSplitPaneWidthForTesting: CGFloat { sidebarPaneContainer.frame.width }
    #if DEBUG
        var dividerIntentCountForTesting: Int { dividerIntentCount }
        var splitPositionMutationIntentCountForTesting: Int { splitPositionMutationIntentCount }
    #endif
    var sidebarHostOccurrenceCountForTesting: Int {
        [sidebarPaneContainer, overlayContentView].filter {
            sidebarChild.view === $0 || sidebarChild.view.isDescendant(of: $0)
        }.count
    }
    var interactionObserverCountForTesting: Int {
        interactionMonitor?.observerCountForTesting ?? 0
    }
    func simulateTrackingAvailabilityLostForTesting() {
        onTrackingAvailabilityLost?()
    }
    func simulateEdgePointerMoveForTesting(x: CGFloat, width: CGFloat) {
        edgeTrackingView.onPointerMove?(x, width)
    }
    func simulateEdgeExitForTesting() {
        edgeTrackingView.onExit?()
    }
    func settleFinalForTesting() {
        settleFinal()
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

    private func handOffSidebarFocusIfNeeded() {
        guard let window = view.window,
            let responderView = window.firstResponder as? NSView,
            responderView === sidebarChild.view || responderView.isDescendant(of: sidebarChild.view)
        else {
            return
        }

        let establishedVisibleResponder = onSidebarFocusHandoff?() == true
        let currentResponderIsStillInSidebar =
            (window.firstResponder as? NSView).map {
                $0 === sidebarChild.view || $0.isDescendant(of: sidebarChild.view)
            } ?? false
        if !establishedVisibleResponder || currentResponderIsStillInSidebar {
            window.makeFirstResponder(nil)
        }
    }

    private func performAtomicPersistentShow() {
        guard isViewLoaded, splitView.bounds.width > 0, overlayContentView.layer != nil else {
            isSidebarHidden = true
            reconcileStableHiddenOwnership()
            applyHiddenPosition()
            setEdgeTrackingEnabled(true)
            return
        }
        let target = Self.clampedWidth(selectedSidebarWidth, maxWidth: maxSidebarWidth)
        var capturedResponder: NSResponder?
        let capturedAccessibilityElement = focusedSidebarAccessibilityElement
        var handoffSucceeded = true
        isPerformingHostHandoff = true
        record(.beginNoActionsTransaction)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            record(.cancelOverlayGeneration)
            overlayAnimator?.cancelAndSettle(
                presented: true, width: overlayClipView.bounds.width, position: sidebarPosition)
            record(.captureSidebarResponder)
            if let responder = view.window?.firstResponder as? NSView,
                responder === sidebarChild.view || responder.isDescendant(of: sidebarChild.view)
            {
                capturedResponder = responder
            }
            record(.removeOverlayAnimation)
            overlayContentView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
            record(.reparentHostToSplitContainer)
            moveSidebarHost(to: sidebarPaneContainer)
            persistentHandoffBeforeAccessibilityValidationForTesting?()
            if let capturedAccessibilityElement,
                !sidebarContainsAccessibilityElement(capturedAccessibilityElement)
            {
                handoffSucceeded = false
                lastPreservedSidebarAccessibilityElementForTesting = false
                moveSidebarHost(to: overlayContentView)
                overlayClipView.isHidden = false
                layoutOverlay(presented: true)
                sidebarChild.view.setAccessibilityHidden(false)
                return
            }
            record(.setPersistentState)
            isSidebarHidden = false
            pendingWidth = nil
            hostMode = .persistent(width: target)
            sidebarChild.view.setAccessibilityHidden(false)
            record(.applySingleDividerIntent(target))
            setDividerPosition(target)
            record(.settleLayout)
            splitView.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            record(.clearTransform)
            overlayContentView.layer?.transform = CATransform3DIdentity
            record(.hideOverlayContainer)
            overlayClipView.isHidden = true
            record(.restoreSidebarResponder)
            if let capturedResponder = capturedResponder as? NSView,
                capturedResponder === sidebarChild.view
                    || capturedResponder.isDescendant(of: sidebarChild.view)
            {
                view.window?.makeFirstResponder(capturedResponder)
            }
            lastPreservedSidebarAccessibilityElementForTesting =
                capturedAccessibilityElement.map(sidebarContainsAccessibilityElement) ?? false
        }
        record(.endNoActionsTransaction)
        isPerformingHostHandoff = false
        guard handoffSucceeded else {
            hostMode = .overlay(width: selectedSidebarWidth)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: selectedSidebarWidth)
            return
        }
        let rendered = sidebarPaneWidth
        hostMode = .persistent(width: rendered)
        recordIfExpanded(rendered)
        onLiveWidthChange?(rendered)
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: rendered)
        setEdgeTrackingEnabled(false)
    }

    private func performAtomicPersistentHide() {
        guard isViewLoaded, splitView.bounds.width > 0, overlayContentView.layer != nil else {
            isSidebarHidden = true
            reconcileStableHiddenOwnership()
            applyHiddenPosition()
            setEdgeTrackingEnabled(true)
            return
        }
        pendingWidth = selectedSidebarWidth
        recordIfExpanded(sidebarPaneWidth)
        record(.captureSidebarResponder)
        record(.querySidebarAccessibilityFocus)
        lastCapturedSidebarAccessibilityFocusForTesting = sidebarAccessibilityFocusIsActive
        record(.handOffSidebarFocus)
        handOffSidebarFocusIfNeeded()
        isPerformingHostHandoff = true
        record(.beginNoActionsTransaction)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            record(.cancelOverlayGeneration)
            overlayAnimator?.cancelAndSettle(
                presented: false, width: overlayClipView.bounds.width, position: sidebarPosition)
            record(.removeOverlayAnimation)
            overlayContentView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
            record(.reparentHostToSplitContainer)
            moveSidebarHost(to: sidebarPaneContainer)
            record(.setHiddenState)
            isSidebarHidden = true
            hostMode = .hidden
            record(.applySingleCollapseIntent)
            applyHiddenPosition()
            record(.settleLayout)
            splitView.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            record(.clearTransform)
            overlayContentView.layer?.transform = CATransform3DIdentity
            record(.hideOverlayContainer)
            overlayClipView.isHidden = true
            record(.hideSidebarAccessibility)
            sidebarChild.view.setAccessibilityHidden(true)
        }
        record(.endNoActionsTransaction)
        isPerformingHostHandoff = false
        hostPresentationState.settle(mode: .hidden, effectiveVisibleWidth: 0)
        record(.enableEdgeTracking)
        setEdgeTrackingEnabled(true)
    }

    private func record(_ action: SidebarHostHandoffAction) {
        handoffActionObserverForTesting?(action)
    }

    private var sidebarPaneWidth: CGFloat {
        sidebarPaneContainer.frame.width
    }

    private func moveSidebarHost(to destination: NSView) {
        guard sidebarChild.view.superview !== destination else { return }
        removeConstraints(for: sidebarChild.view, from: sidebarChild.view.superview)
        removeConstraints(for: sidebarChild.view, from: destination)
        sidebarChild.view.removeFromSuperview()
        sidebarChild.view.translatesAutoresizingMaskIntoConstraints = true
        destination.addSubview(sidebarChild.view)
        sidebarChild.view.frame = destination.bounds
        sidebarChild.view.autoresizingMask = [.width, .height]
    }

    private func reconcileStableHiddenOwnership() {
        overlayAnimator?.cancelAndSettle(
            presented: false, width: overlayContentView.bounds.width, position: sidebarPosition)
        moveSidebarHost(to: sidebarPaneContainer)
        overlayContentView.layer?.setAffineTransform(.identity)
        overlayClipView.isHidden = true
        hostMode = .hidden
        sidebarChild.view.setAccessibilityHidden(true)
        hostPresentationState.settle(mode: .hidden, effectiveVisibleWidth: 0)
    }

    private var sidebarAccessibilityFocusIsActive: Bool {
        if let hasActiveSidebarAccessibilityFocus {
            return hasActiveSidebarAccessibilityFocus()
        }
        return interactionMonitor?.hasAccessibilityFocus == true
    }

    private var focusedSidebarAccessibilityElement: Any? {
        if let sidebarAccessibilityFocusedElement {
            guard let element = sidebarAccessibilityFocusedElement() else { return nil }
            return sidebarContainsAccessibilityElement(element) ? element : nil
        }
        return interactionMonitor?.focusedAccessibilityElementInsideSidebar
    }

    private func sidebarContainsAccessibilityElement(_ element: Any) -> Bool {
        interactionMonitor?.containsAccessibilityElement(element)
            ?? ((element as? NSView).map {
                $0 === sidebarChild.view || $0.isDescendant(of: sidebarChild.view)
            } ?? false)
    }

    private func installInteractionMonitor() {
        guard isViewLoaded, interactionMonitor == nil else { return }
        interactionMonitor = SidebarInteractionMonitor(
            sidebarRoot: sidebarChild.view,
            focusedAccessibilityElement: interactionFocusedAccessibilityElement,
            notificationCenter: interactionNotificationCenter,
            onActiveChange: { [weak self] active in
                self?.onSidebarInteractionChanged?(active)
            })
    }

    func settleDetached() {
        interactionMonitor?.detach()
        interactionMonitor = nil
        guard isViewLoaded else { return }
        overlayAnimator?.cancelAndSettle(
            presented: false,
            width: overlayClipView.bounds.width,
            position: sidebarPosition)
        overlayContentView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
        if isSidebarHidden {
            reconcileStableHiddenOwnership()
        } else {
            moveSidebarHost(to: sidebarPaneContainer)
            overlayContentView.layer?.transform = CATransform3DIdentity
            overlayClipView.isHidden = true
            sidebarChild.view.setAccessibilityHidden(true)
            hostMode = .persistent(width: sidebarPaneWidth)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: sidebarPaneWidth)
        }
    }

    private func settleAttached() {
        installInteractionMonitor()
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
        handoffActionObserverForTesting = nil
        persistentHandoffBeforeAccessibilityValidationForTesting = nil
    }

    private func settleFinal() {
        interactionMonitor?.detach()
        interactionMonitor = nil
        clearExternalCallbacks()
        guard isViewLoaded else { return }
        settleDetached()
    }

    private func invalidateOverlayForDetach() {
        settleDetached()
    }

    private func finishOverlayTransition(presented: Bool) {
        if presented {
            sidebarChild.view.setAccessibilityHidden(false)
            hostPresentationState.settle(
                mode: hostMode, effectiveVisibleWidth: overlayClipView.bounds.width)
        } else {
            reconcileStableHiddenOwnership()
        }
    }

    private func layoutOverlayPreservingAnimation() {
        let oldWidth = overlayClipView.bounds.width
        layoutOverlay(presented: true)
        let newWidth = overlayClipView.bounds.width
        hostMode = .overlay(width: newWidth)
        hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: newWidth)
        guard oldWidth > 0, oldWidth != newWidth,
            let requestedPresented = overlayAnimator?.requestedPresentedState
        else { return }
        overlayAnimator?.reframe(
            fromWidth: oldWidth,
            toWidth: newWidth,
            position: sidebarPosition,
            transition: .hover,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) { [weak self] _ in
            self?.finishOverlayTransition(presented: requestedPresented)
        }
    }

    private func removeConstraints(for child: NSView, from container: NSView?) {
        guard let container else { return }
        container.removeConstraints(
            container.constraints.filter {
                ($0.firstItem as AnyObject?) === child || ($0.secondItem as AnyObject?) === child
            })
    }

    private func layoutOverlay(presented: Bool) {
        let width = Self.clampedWidth(selectedSidebarWidth, maxWidth: maxSidebarWidth)
        let x = sidebarPosition == .left ? 0 : view.bounds.maxX - width
        overlayClipView.frame = CGRect(x: x, y: 0, width: width, height: view.bounds.height)
        overlayContentView.frame = overlayClipView.bounds
        overlayContentView.autoresizingMask = [.width, .height]
        sidebarChild.view.frame = overlayContentView.bounds
        let hiddenTranslation = sidebarPosition == .left ? -width : width
        overlayClipView.presentationTranslationX = { [weak overlayAnimator] in
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
            dividerIntentCount += 1
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
        if !isPerformingHostHandoff {
            onLiveWidthChange?(rendered)
            hostPresentationState.settle(mode: hostMode, effectiveVisibleWidth: rendered)
        }
    }

    private func applyHiddenPosition() {
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
        guard !isSettingPositionProgrammatically, !isPerformingHostHandoff, !isSidebarHidden else {
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
