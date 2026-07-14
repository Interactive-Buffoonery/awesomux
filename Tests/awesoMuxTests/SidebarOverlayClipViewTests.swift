import AppKit
import Testing
@testable import awesoMux

@Suite("Sidebar overlay clip hit testing")
@MainActor
struct SidebarOverlayClipViewTests {
    struct HeldPresentation: Sendable {
        let translation: Double
        let coveredX: Double?
        let uncoveredX: Double?
    }

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

    @Test(
        "held presentation fractions route covered content and leave uncovered terminal live",
        arguments: [
            HeldPresentation(translation: -100, coveredX: nil, uncoveredX: 50),
            HeldPresentation(translation: -75, coveredX: 12, uncoveredX: 50),
            HeldPresentation(translation: -50, coveredX: 25, uncoveredX: 75),
            HeldPresentation(translation: 0, coveredX: 75, uncoveredX: nil),
            HeldPresentation(translation: 100, coveredX: nil, uncoveredX: 50),
            HeldPresentation(translation: 75, coveredX: 88, uncoveredX: 50),
            HeldPresentation(translation: 50, coveredX: 75, uncoveredX: 25),
            HeldPresentation(translation: 0, coveredX: 25, uncoveredX: nil),
        ])
    func heldFractionsRouteOnlyVisibleContent(
        fixture: HeldPresentation
    ) {
        let clip = SidebarOverlayClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let content = RoutedContentView(frame: clip.bounds)
        clip.addSubview(content)
        clip.contentView = content
        clip.presentationTranslationX = { CGFloat(fixture.translation) }

        if let coveredX = fixture.coveredX.map({ CGFloat($0) }) {
            #expect(clip.hitTest(NSPoint(x: coveredX, y: 20)) != nil)
        }
        if let uncoveredX = fixture.uncoveredX.map({ CGFloat($0) }) {
            // Returning nil is what lets mouse, scroll, and contextual events route
            // through the overlay to the terminal beneath it.
            #expect(clip.hitTest(NSPoint(x: uncoveredX, y: 20)) == nil)
        }
    }
}
