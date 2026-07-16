import AppKit
import AwesoMuxConfig

final class SidebarEdgeTrackingView: NSView {
    var position: AppearanceConfig.SidebarPosition
    var onPointerMove: ((CGFloat, CGFloat) -> Void)?
    var onExit: (() -> Void)?
    var onAvailabilityLost: (() -> Void)?
    var currentMouseLocationInWindow: (NSWindow) -> CGPoint = { $0.mouseLocationOutsideOfEventStream }
    var acceptsPointerUpdates = true {
        didSet {
            if !acceptsPointerUpdates {
                invalidatePointer()
            }
        }
    }

    private var pointerTrackingArea: NSTrackingArea?
    private var lastPointerLocationInWindow: CGPoint?

    init(position: AppearanceConfig.SidebarPosition) {
        self.position = position
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityIsIgnored() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        // The controller's window-local monitor is the single mouse-move path.
        // Requesting movement here too would republish every event the monitor
        // returns for normal AppKit dispatch.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            lastPointerLocationInWindow = nil
            onAvailabilityLost?()
            return
        }
    }

    override func mouseEntered(with event: NSEvent) {
        synchronizePointer(locationInWindow: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard acceptsPointerUpdates else { return }
        guard let window else {
            invalidatePointer()
            return
        }
        let locationInWindow = currentMouseLocationInWindow(window)
        let local = convert(locationInWindow, from: nil)
        if containsInEffectiveRegion(local) {
            report(locationInWindow: locationInWindow)
        } else {
            invalidatePointer()
        }
    }

    func invalidatePointer() {
        guard lastPointerLocationInWindow != nil else { return }
        lastPointerLocationInWindow = nil
        onExit?()
    }

    func republishPointerAfterGeometryChange() {
        guard acceptsPointerUpdates else { return }
        guard let lastPointerLocationInWindow else { return }
        let local = convert(lastPointerLocationInWindow, from: nil)
        guard containsInEffectiveRegion(local) else {
            self.lastPointerLocationInWindow = nil
            onExit?()
            return
        }
        onPointerMove?(local.x, bounds.width)
    }

    func synchronizePointer(locationInWindow: CGPoint) {
        guard acceptsPointerUpdates else { return }
        let local = convert(locationInWindow, from: nil)
        if containsInEffectiveRegion(local) {
            report(locationInWindow: locationInWindow)
        } else if lastPointerLocationInWindow != nil {
            invalidatePointer()
        }
    }

    static func distance(
        x: CGFloat,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition
    ) -> CGFloat {
        let safeWidth = width.isFinite ? max(0, width) : 0
        let safeX = x.isFinite ? min(max(0, x), safeWidth) : 0
        return position == .left ? safeX : safeWidth - safeX
    }

    private func containsInEffectiveRegion(_ point: CGPoint) -> Bool {
        bounds.contains(point) && visibleRect.contains(point)
    }

    private func report(locationInWindow: CGPoint) {
        lastPointerLocationInWindow = locationInWindow
        let local = convert(locationInWindow, from: nil)
        onPointerMove?(local.x, bounds.width)
    }
}
