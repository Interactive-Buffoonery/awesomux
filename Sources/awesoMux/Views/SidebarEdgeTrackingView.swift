import AppKit
import AwesoMuxConfig

final class SidebarEdgeTrackingView: NSView {
    var position: AppearanceConfig.SidebarPosition
    var onPointerMove: ((CGFloat, CGFloat) -> Void)?
    var onExit: (() -> Void)?
    var onAvailabilityLost: (() -> Void)?

    private var pointerTrackingArea: NSTrackingArea?
    private var lastPointerLocationInWindow: CGPoint?

    init(position: AppearanceConfig.SidebarPosition) {
        self.position = position
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityIsIgnored() -> Bool { true }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        guard let window else {
            lastPointerLocationInWindow = nil
            onAvailabilityLost?()
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func mouseMoved(with event: NSEvent) {
        report(event)
    }

    override func mouseEntered(with event: NSEvent) {
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        invalidatePointer()
    }

    func invalidatePointer() {
        lastPointerLocationInWindow = nil
        onExit?()
    }

    func republishPointerAfterGeometryChange() {
        guard let lastPointerLocationInWindow else { return }
        let local = convert(lastPointerLocationInWindow, from: nil)
        guard bounds.contains(local) else {
            self.lastPointerLocationInWindow = nil
            onExit?()
            return
        }
        onPointerMove?(local.x, bounds.width)
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

    private func report(_ event: NSEvent) {
        lastPointerLocationInWindow = event.locationInWindow
        let local = convert(event.locationInWindow, from: nil)
        onPointerMove?(local.x, bounds.width)
    }

    @objc private func windowDidResignKey() {
        lastPointerLocationInWindow = nil
        onAvailabilityLost?()
    }
}
