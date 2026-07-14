import AppKit

final class SidebarOverlayClipView: NSView {
    weak var contentView: NSView?
    var presentationTranslationX: () -> CGFloat = { 0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
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
