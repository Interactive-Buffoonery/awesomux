import AppKit
import Testing
@testable import awesoMux

@Suite("Sidebar overlay clip hit testing")
@MainActor
struct SidebarOverlayClipViewTests {
    private final class Sentinel: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    }

    private final class RoutedContentView: NSView {
        let left = Sentinel()
        let right = Sentinel()

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return point.x < bounds.midX ? left : right
        }
    }

    @Test("partially translated content only hits its visible transformed region", arguments: [CGFloat(-50), 50])
    func partialHitTesting(translation: CGFloat) {
        let clip = SidebarOverlayClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = RoutedContentView(frame: clip.bounds)
        clip.addSubview(content)
        clip.contentView = content
        clip.presentationTranslationX = { translation }

        if translation < 0 {
            #expect(clip.hitTest(NSPoint(x: 25, y: 20)) === content.right)
            #expect(clip.hitTest(NSPoint(x: 75, y: 20)) == nil)
        } else {
            #expect(clip.hitTest(NSPoint(x: 25, y: 20)) == nil)
            #expect(clip.hitTest(NSPoint(x: 75, y: 20)) === content.left)
        }
    }

    @Test("fully hidden translated content rejects hits", arguments: [CGFloat(-100), 100])
    func fullyHidden(translation: CGFloat) {
        let clip = SidebarOverlayClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = Sentinel(frame: clip.bounds)
        clip.addSubview(content)
        clip.contentView = content
        clip.presentationTranslationX = { translation }
        #expect(clip.hitTest(NSPoint(x: 50, y: 20)) == nil)
    }
}
