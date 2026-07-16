import AppKit

final class SidebarOverlayClipView: NSView {
    weak var contentView: NSView?
    var presentationTranslationX: () -> CGFloat = { 0 }

    override func accessibilityIsIgnored() -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit delivers the point in the SUPERVIEW's coordinate space. Comparing it
        // against local bounds only works while this view's frame origin is (0, 0) —
        // true for a leading sidebar, false for a trailing one, whose revealed overlay
        // otherwise rejects every hit and lets clicks fall through to the terminal.
        let point = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, bounds.contains(point), let contentView else { return nil }
        let translation = presentationTranslationX()
        let visualFrame = contentView.frame.offsetBy(dx: translation, dy: 0)
        guard visualFrame.intersection(bounds).contains(point) else { return nil }
        let contentPoint = NSPoint(
            x: point.x - contentView.frame.minX - translation,
            y: point.y - contentView.frame.minY
        )
        return contentView.hitTest(contentPoint)
    }
}
