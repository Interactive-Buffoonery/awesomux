import AppKit
import AwesoMuxConfig
import AwesoMuxCore

@MainActor
private final class SidebarWidthAnimation: NSObject {
    private let fromWidth: CGFloat
    private let toWidth: CGFloat
    private let duration: TimeInterval
    private let update: (CGFloat) -> Void
    private let completion: () -> Void
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?

    init(
        fromWidth: CGFloat,
        toWidth: CGFloat,
        duration: TimeInterval,
        update: @escaping (CGFloat) -> Void,
        completion: @escaping () -> Void
    ) {
        self.fromWidth = fromWidth
        self.toWidth = toWidth
        self.duration = max(0, duration)
        self.update = update
        self.completion = completion
    }

    func start() {
        guard duration > 0 else {
            update(toWidth)
            completion()
            return
        }
        let timer = Timer(
            timeInterval: 1 / 120,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let progress = min(1, max(0, elapsed / duration))
        let eased = progress * progress * (3 - 2 * progress)
        update(fromWidth + (toWidth - fromWidth) * eased)
        guard progress >= 1 else { return }
        cancel()
        completion()
    }
}

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
    typealias AnimationRunner = (
        TimeInterval, @escaping () -> Void, @escaping () -> Void
    ) -> Void

    struct AnimationRecord: Equatable {
        let fromWidth: CGFloat
        let toWidth: CGFloat
        let duration: TimeInterval
    }
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

    /// Minimum width the detail/terminal pane must retain. The sidebar's dynamic
    /// maximum is `splitView.bounds.width - terminalMinimumWidth`, evaluated live so
    /// it self-adjusts as the window resizes. Tunable.
    var terminalMinimumWidth: CGFloat = 480 {
        didSet { guard isViewLoaded else { return }; reclampToBounds() }
    }

    private let splitView = DividerTrackingSplitView()
    private let edgeTrackingView = SidebarEdgeTrackingView(position: .left)
    private let sidebarChild: NSViewController
    private let detailChild: NSViewController
    var sidebarViewController: NSViewController { sidebarChild }
    var detailViewController: NSViewController { detailChild }
    private var sidebarPosition: AppearanceConfig.SidebarPosition = .left
    private var isSidebarHidden = false
    private var isEdgeTrackingEnabled = false
    private var animationGeneration = 0
    private var requestedSidebarVisible = true
    private var isHoverAnimating = false
    private var activeHoverTargetWidth: CGFloat?
    private var activeHoverPaneExtent: CGFloat?
    private let animationRunner: AnimationRunner?
    private var widthAnimation: SidebarWidthAnimation?
    private(set) var lastAnimationForTesting: AnimationRecord?
    private(set) var lastAnimationTargetCoordinateForTesting: CGFloat?

    /// Set around our own `setPosition` calls so `splitViewDidResizeSubviews` (which
    /// also fires for programmatic position changes and window layout) does not echo
    /// a programmatic change back out as a "live" width change.
    private var isSettingPositionProgrammatically = false

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
        animationRunner: AnimationRunner? = nil
    ) {
        sidebarChild = sidebar
        detailChild = detail
        self.animationRunner = animationRunner
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
            guard let self, !self.isSidebarHidden, !self.isHoverAnimating else { return }
            self.onCommitWidth?(self.sidebarPaneWidth)
        }
        splitView.sidebarWidthProvider = { [weak self] in self?.sidebarPaneWidth }
        addChild(sidebarChild)
        addChild(detailChild)
        // NSSplitView treats its direct subviews as panes (index 0 = leading).
        if sidebarPosition == .left {
            splitView.addSubview(sidebarChild.view)
            splitView.addSubview(detailChild.view)
        } else {
            splitView.addSubview(detailChild.view)
            splitView.addSubview(sidebarChild.view)
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
            self?.onTrackingAvailabilityLost?()
        }
        let root = NSView()
        root.addSubview(splitView)
        root.addSubview(edgeTrackingView)
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitView.frame = view.bounds
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

    // MARK: - Public API

    /// Move the divider so the sidebar pane is `width` points wide, clamped to
    /// `[collapsedWidth, maxSidebarWidth]`. Un-animated.
    func setSidebarWidth(_ width: CGFloat) {
        if isHoverAnimating { cancelHoverAnimation() }
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

    var maxSidebarWidth: CGFloat {
        max(SidebarWidthPolicy.collapsedWidth, paneExtent - terminalMinimumWidth)
    }

    func setSidebarPosition(_ position: AppearanceConfig.SidebarPosition) {
        guard position != sidebarPosition else { return }
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
            sidebar: sidebarChild.view, detail: detailChild.view, position: position
        )
        splitView.sortSubviews(
            { lhs, rhs, context in
                guard let context else { return .orderedSame }
                return Unmanaged<SidebarSubviewOrder>.fromOpaque(context)
                    .takeUnretainedValue().compare(lhs, rhs)
            }, context: Unmanaged.passUnretained(order).toOpaque())
        splitView.adjustSubviews()
        if isSidebarHidden { applyHiddenPosition() } else { applyPosition(width) }
        if ownsResponder, view.window?.firstResponder !== responder {
            view.window?.makeFirstResponder(responder)
        }
    }

    func setSidebarHidden(_ hidden: Bool) {
        setSidebarVisible(!hidden, transition: .immediate, reduceMotion: false)
    }

    func setSidebarVisible(
        _ visible: Bool,
        transition: SidebarSplitTransition,
        reduceMotion: Bool
    ) {
        let target = targetWidth(forVisible: visible)
        if case .hover = transition,
            isHoverAnimating,
            requestedSidebarVisible == visible,
            activeHoverTargetWidth == target
        {
            return
        }
        if !isHoverAnimating, abs(sidebarPaneWidth - target) < 0.5 {
            requestedSidebarVisible = visible
            normalizeSidebarVisibility(visible)
            return
        }
        let wasHoverAnimating = isHoverAnimating
        cancelHoverAnimation()
        requestedSidebarVisible = visible
        if abs(sidebarPaneWidth - target) < 0.5 {
            normalizeSidebarVisibility(visible)
            return
        }
        switch transition {
        case .immediate:
            applySidebarVisibilityImmediately(
                visible, rememberCurrentWidth: !wasHoverAnimating
            )
        case let .hover(duration) where !reduceMotion:
            animateSidebarVisibility(
                visible, duration: duration, rememberCurrentWidth: !wasHoverAnimating
            )
        case .hover:
            applySidebarVisibilityImmediately(
                visible, rememberCurrentWidth: !wasHoverAnimating
            )
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

    func installVisibilityHandler(on proxy: SidebarSplitProxy) {
        proxy.setVisibility = { [weak self] visible, transition, reduceMotion in
            self?.setSidebarVisible(
                visible, transition: transition, reduceMotion: reduceMotion
            )
        }
    }

    func simulateDividerDragCompletionForTesting() {
        splitView.onDragEnded?()
    }

    var edgeTrackingFrameForTesting: CGRect { edgeTrackingView.frame }
    var isEdgeTrackingVisibleForTesting: Bool { !edgeTrackingView.isHidden }
    var splitPaneViewsForTesting: [NSView] { splitView.subviews }
    var paneExtentForTesting: CGFloat { paneExtent }
    var animationGenerationForTesting: Int { animationGeneration }

    func setSidebarPaneWidthForTesting(_ width: CGFloat) {
        setDividerPosition(width)
    }

    func simulateTrackingAvailabilityLostForTesting() {
        onTrackingAvailabilityLost?()
    }

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

    /// Read the sidebar child's view width directly — unambiguous, vs. guessing
    /// which `subviews`/`arrangedSubviews` index is the leading pane.
    private var sidebarPaneWidth: CGFloat {
        sidebarChild.view.frame.width
    }

    private var paneExtent: CGFloat {
        max(0, splitView.bounds.width - splitView.dividerThickness)
    }

    private func targetWidth(forVisible visible: Bool) -> CGFloat {
        guard visible else { return 0 }
        return Self.clampedWidth(
            pendingWidth ?? lastExpandedPaneWidth,
            maxWidth: maxSidebarWidth
        )
    }

    private func cancelHoverAnimation() {
        widthAnimation?.cancel()
        widthAnimation = nil
        animationGeneration += 1
        isHoverAnimating = false
        activeHoverTargetWidth = nil
        activeHoverPaneExtent = nil
    }

    private func normalizeSidebarVisibility(_ visible: Bool) {
        isSidebarHidden = !visible
        requestedSidebarVisible = visible
        isHoverAnimating = false
        activeHoverTargetWidth = nil
        activeHoverPaneExtent = nil
        if visible { pendingWidth = nil }
    }

    private func applySidebarVisibilityImmediately(
        _ visible: Bool,
        rememberCurrentWidth: Bool = true
    ) {
        if !visible {
            handOffSidebarFocusIfNeeded()
            let current = sidebarPaneWidth
            if rememberCurrentWidth, current > 0 { pendingWidth = current }
            recordIfExpanded(current)
            isSidebarHidden = true
            applyHiddenPosition()
        } else {
            isSidebarHidden = false
            let target = targetWidth(forVisible: true)
            pendingWidth = nil
            applyPosition(target)
        }
        normalizeSidebarVisibility(visible)
    }

    private func animateSidebarVisibility(
        _ visible: Bool,
        duration: TimeInterval,
        rememberCurrentWidth: Bool
    ) {
        let fromWidth = sidebarPaneWidth
        let target = targetWidth(forVisible: visible)
        if !visible {
            handOffSidebarFocusIfNeeded()
            if rememberCurrentWidth, fromWidth > 0 { pendingWidth = fromWidth }
            recordIfExpanded(fromWidth)
        } else {
            isSidebarHidden = false
        }
        isHoverAnimating = true
        activeHoverTargetWidth = target
        activeHoverPaneExtent = paneExtent
        animationGeneration += 1
        let generation = animationGeneration
        lastAnimationForTesting = .init(
            fromWidth: fromWidth, toWidth: target, duration: duration
        )
        let coordinate = Self.dividerCoordinate(
            forSidebarWidth: target, paneExtent: paneExtent, position: sidebarPosition
        )
        lastAnimationTargetCoordinateForTesting = coordinate
        if let animationRunner {
            animationRunner(
                duration,
                { [weak self] in
                    self?.setDividerPosition(target)
                },
                { [weak self] in
                    Task { @MainActor in self?.finishHoverAnimation(generation: generation) }
                })
        } else {
            let animation = SidebarWidthAnimation(
                fromWidth: fromWidth,
                toWidth: target,
                duration: duration,
                update: { [weak self] width in self?.setDividerPosition(width) },
                completion: { [weak self] in
                    self?.finishHoverAnimation(generation: generation)
                }
            )
            widthAnimation = animation
            animation.start()
        }
    }

    private func finishHoverAnimation(generation: Int) {
        guard generation == animationGeneration else { return }
        widthAnimation = nil
        let visible = requestedSidebarVisible
        let target = activeHoverTargetWidth
        isHoverAnimating = false
        activeHoverTargetWidth = nil
        activeHoverPaneExtent = nil
        if visible {
            pendingWidth = nil
            isSidebarHidden = false
            setDividerPosition(target ?? targetWidth(forVisible: true))
        } else {
            isSidebarHidden = true
            setDividerPosition(0)
        }
    }

    private func setDividerPosition(_ width: CGFloat) {
        let coordinate = Self.dividerCoordinate(
            forSidebarWidth: width, paneExtent: paneExtent, position: sidebarPosition
        )
        isSettingPositionProgrammatically = true
        splitView.setPosition(coordinate, ofDividerAt: 0)
        isSettingPositionProgrammatically = false
    }

    private func applyPosition(_ width: CGFloat) {
        let target = Self.clampedWidth(width, maxWidth: maxSidebarWidth)
        isSettingPositionProgrammatically = true
        let coordinate = Self.dividerCoordinate(
            forSidebarWidth: target, paneExtent: paneExtent, position: sidebarPosition
        )
        splitView.setPosition(coordinate, ofDividerAt: 0)
        isSettingPositionProgrammatically = false
        let rendered = sidebarPaneWidth
        recordIfExpanded(rendered)
        // Report the rendered pane width, not just the requested target. AppKit
        // can preserve a wider child during first layout or constraint pressure;
        // SwiftUI's sidebar mode must follow the pane that actually rendered.
        onLiveWidthChange?(rendered)
    }

    private func applyHiddenPosition() {
        guard isViewLoaded, splitView.bounds.width > 0, sidebarPaneWidth > 0 else { return }
        isSettingPositionProgrammatically = true
        splitView.setPosition(sidebarPosition == .left ? 0 : paneExtent, ofDividerAt: 0)
        isSettingPositionProgrammatically = false
    }

    /// Remember the last expanded width so restore-on-grow has a target. Rail
    /// widths are deliberately ignored — they are never a restore destination.
    private func recordIfExpanded(_ width: CGFloat) {
        if width >= SidebarWidthPolicy.railThreshold {
            lastExpandedPaneWidth = width
        }
    }

    private func reclampToBounds() {
        guard splitView.bounds.width > 0 else { return }
        if isHoverAnimating {
            guard activeHoverPaneExtent != paneExtent else { return }
            let visible = requestedSidebarVisible
            cancelHoverAnimation()
            applySidebarVisibilityImmediately(visible)
            return
        }
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
        if isHoverAnimating {
            return sidebarPosition == .left ? 0 : terminalMinimumWidth
        }
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
        if isHoverAnimating {
            return sidebarPosition == .left ? maxSidebarWidth : paneExtent
        }
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
        if isHoverAnimating { return proposedPosition }
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
        view !== sidebarChild.view
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isSettingPositionProgrammatically, !isSidebarHidden, !isHoverAnimating else { return }
        let width = sidebarPaneWidth
        // A user divider drag into expanded territory is the other source of a
        // restore target, so record it here too.
        recordIfExpanded(width)
        onLiveWidthChange?(width)
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
