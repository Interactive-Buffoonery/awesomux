import AppKit
import AwesoMuxConfig
import os

@MainActor
enum GhosttySurfaceFocusReadiness {
    static let didBecomeReadyNotification = Notification.Name(
        "com.interactivebuffoonery.awesomux.ghosttySurfaceFocusDidBecomeReady"
    )

    static func post(
        _ surface: GhosttySurfaceNSView,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(name: didBecomeReadyNotification, object: surface)
    }

    static func surface(from notification: Notification) -> GhosttySurfaceNSView? {
        notification.object as? GhosttySurfaceNSView
    }
}

@MainActor
final class GhosttySurfaceContainerView: NSView {
    private static let terminalDiagnosticsLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "TerminalDiagnostics"
    )
    private static let terminalDiagnosticsEnabled =
        TerminalDiagnosticsConfiguration.isEnabled()

    private let scrollView: NSScrollView
    private let documentView: NSView
    private weak var mountedSurfaceView: GhosttySurfaceNSView?
    private var isLiveScrolling = false
    private var isSynchronizingLayout = false
    private var surfaceMetricsSyncTask: Task<Void, Never>?
    private var lastSentScrollRow: Int?

    init(contentSize: CGSize) {
        scrollView = NSScrollView()
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("Terminal pane")
        // The terminal surface owns the accessible output. Keep the wrapper
        // and backing document out of the VoiceOver tree so users don't hear
        // duplicate nested scroll/document landmarks for one terminal pane.
        scrollView.setAccessibilityElement(false)
        documentView.setAccessibilityElement(false)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.usesPredominantAxisScrolling = true
        configureScrollerStyle()
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        surfaceMetricsSyncTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    func mount(_ surfaceView: GhosttySurfaceNSView, isActive: Bool, contentSize: CGSize) {
        let alignedSize = backingAlignedRect(
            NSRect(origin: .zero, size: contentSize),
            options: .alignAllEdgesNearest
        ).size
        if alignedSize.width > 0,
           alignedSize.height > 0,
           frame.size != alignedSize {
            setFrameSize(alignedSize)
        }

        // `alreadyMounted` also requires the surface to still be parented under
        // OUR documentView — self-healing. During a swap/same-shape move two live
        // containers exchange panes in one render pass; container2's mount can
        // adopt the surface container1 just took, and a later container1 pass
        // would otherwise see `mountedSurfaceView === surfaceView`, short-circuit,
        // and leave the surface detached → permanently blank pane.
        let alreadyMounted = mountedSurfaceView === surfaceView
            && surfaceView.superview === documentView

        if !alreadyMounted {
            // Only detach the PREVIOUS surface if we still own it. In a swap,
            // container2 adopts the surface this container previously held, then
            // points its `scrollContainer` at container2 — so by the time we run,
            // `previous.scrollContainer !== self`, and detaching it would rip the
            // surface back out of the container that now legitimately owns it.
            if let previous = mountedSurfaceView,
               previous !== surfaceView,
               previous.scrollContainer === self {
                previous.scrollContainer = nil
                previous.removeFromSuperview()
            }
            mountedSurfaceView = surfaceView
            surfaceView.scrollContainer = self
            surfaceView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            surfaceView.autoresizingMask = []
            documentView.addSubview(surfaceView)
            // A container-to-container move within the same window fires no
            // AppKit window callbacks, so the surface's pushed backing state
            // (size, scale, occlusion) can be stale after a split collapse or
            // swap — re-push it here (INT-600).
            surfaceView.surfaceWasRemounted()
        }

        setAccessibilityLabel(surfaceView.accessibilityPaneLabel(isActive: isActive))
        // No `alreadyMounted`/`lastIsActive` gate: the reclaim itself only
        // fires into a vacant responder (nil, the window, or a peer surface),
        // so re-running it on every mount is idempotent — and a collapse can
        // leave the vacancy on a mount where the old edge gate would have
        // skipped it (INT-562 recurrence family).
        let needsFocus = isActive
            && surfaceView.window?.firstResponder !== surfaceView
        if Self.terminalDiagnosticsEnabled {
            // Logged after the mount work so `window_attached` and `responder`
            // describe the state a collapse remount actually lands in
            // (`already_mounted` is the pre-mount decision input).
            let responder = surfaceView.window?.firstResponder
            Self.terminalDiagnosticsLogger.info(
                """
                terminal-diagnostics event=surface-container-mount \
                pane=\(surfaceView.paneID.uuidString.prefix(8), privacy: .public) \
                proposed_points=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(contentSize), privacy: .public) \
                aligned_points=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(alignedSize), privacy: .public) \
                container_bounds=\(GhosttySurfaceDiagnosticsFormat.sizeDescription(self.bounds.size), privacy: .public) \
                already_mounted=\(alreadyMounted, privacy: .public) \
                is_active=\(isActive, privacy: .public) \
                window_attached=\(surfaceView.window != nil, privacy: .public) \
                responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) \
                needs_focus=\(needsFocus, privacy: .public)
                """
            )
        }
        if needsFocus {
            surfaceView.requestFocusIfWindowHasNoTarget()
        }
        needsLayout = true
        synchronizeLayout()
        postFocusReadinessIfMounted(surfaceView)
    }

    override func layout() {
        super.layout()
        synchronizeLayout()
    }

    func surfaceMetricsDidChange() {
        guard surfaceMetricsSyncTask == nil else {
            return
        }

        surfaceMetricsSyncTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            surfaceMetricsSyncTask = nil
            synchronizeScrollView()
            synchronizeCoreSurface()
        }
    }

    @objc private func contentViewBoundsDidChange(_ notification: Notification) {
        guard !isSynchronizingLayout else {
            return
        }

        synchronizeSurfaceView()
    }

    @objc private func scrollViewWillStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func scrollViewDidEndLiveScroll(_ notification: Notification) {
        isLiveScrolling = false
    }

    @objc private func scrollViewDidLiveScroll(_ notification: Notification) {
        handleLiveScroll()
    }

    @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
        configureScrollerStyle()
    }

    private func configureScrollerStyle() {
        let preferredStyle = NSScroller.preferredScrollerStyle
        scrollView.scrollerStyle = preferredStyle
        scrollView.autohidesScrollers = preferredStyle == .overlay
    }

    /// The surface view this container still legitimately owns. After a swap
    /// or collapse another container can adopt `mountedSurfaceView` (which
    /// repoints its `scrollContainer`), but OUR weak reference keeps pointing
    /// at the same runtime-retained view — so a late `layout()` pass or an
    /// already-queued metrics task here must not keep writing geometry into a
    /// view someone else now owns.
    private var ownedSurfaceView: GhosttySurfaceNSView? {
        guard let mountedSurfaceView,
              mountedSurfaceView.scrollContainer === self else {
            return nil
        }
        return mountedSurfaceView
    }

    private func postFocusReadinessIfMounted(_ surfaceView: GhosttySurfaceNSView) {
        guard mountedSurfaceView === surfaceView,
            surfaceView.scrollContainer === self,
            surfaceView.superview === documentView,
            let contentView = surfaceView.window?.contentView,
            surfaceView.isDescendant(of: contentView)
        else { return }
        GhosttySurfaceFocusReadiness.post(surfaceView)
    }

    private func synchronizeLayout() {
        guard !isSynchronizingLayout else {
            return
        }

        isSynchronizingLayout = true
        defer { isSynchronizingLayout = false }

        scrollView.frame = bounds
        ownedSurfaceView?.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width

        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        ownedSurfaceView?.frame.origin = visibleRect.origin
    }

    private func synchronizeCoreSurface() {
        guard let surfaceView = ownedSurfaceView else { return }

        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        if width > 0, height > 0 {
            surfaceView.mountedSizeDidChange(CGSize(width: width, height: height))
        }
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling,
           let surfaceView = ownedSurfaceView,
           surfaceView.cellSize.height > 0,
           let scrollbar = surfaceView.scrollbar {
            let offsetY = CGFloat(scrollbar.rowsBelowVisibleStart)
                * surfaceView.cellSize.height
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            lastSentScrollRow = scrollbar.visibleStartRow
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleLiveScroll() {
        guard let surfaceView = ownedSurfaceView,
              surfaceView.cellSize.height > 0 else {
            return
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let scrollOffset = documentView.frame.height - visibleRect.origin.y - visibleRect.height
        let requestedRow = max(0, Int(scrollOffset / surfaceView.cellSize.height))
        let row = surfaceView.scrollbar.map {
            min(requestedRow, $0.maximumVisibleStartRow)
        } ?? requestedRow
        guard row != lastSentScrollRow else {
            return
        }

        lastSentScrollRow = row
        surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        guard let surfaceView = ownedSurfaceView,
              surfaceView.cellSize.height > 0,
              let scrollbar = surfaceView.scrollbar else {
            return contentHeight
        }

        let documentGridHeight = CGFloat(scrollbar.total) * surfaceView.cellSize.height
        let visibleGridHeight = CGFloat(scrollbar.visibleLength) * surfaceView.cellSize.height
        let padding = max(0, contentHeight - visibleGridHeight)
        return max(contentHeight, documentGridHeight + padding)
    }
}
