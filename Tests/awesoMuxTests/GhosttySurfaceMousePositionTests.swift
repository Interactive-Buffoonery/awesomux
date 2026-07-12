import AppKit
import Testing
@testable import awesoMux

/// INT-138: `viewMousePosition` must report raw (unclamped) coordinates so
/// libghostty receives the negative "cursor left the viewport" sentinel during
/// drags/exits, matching upstream Ghostty (`SurfaceView_AppKit.swift`, which
/// clamps nowhere). These pin the full contract — x passthrough for both signs
/// and the exact y-flip — so a future "helpful" re-clamp of either axis fails here.
@Suite("GhosttySurfaceMousePosition")
struct GhosttySurfaceMousePositionTests {
    @Test("in-bounds point: x passes through, y flips top-left to bottom-left")
    func inBoundsFlip() {
        let pos = GhosttySurfaceNSView.viewMousePosition(
            viewLocalPoint: CGPoint(x: 30, y: 90),
            boundsHeight: 100
        )
        #expect(pos.x == 30)
        #expect(pos.y == 10)
    }

    @Test("negative x survives — sentinel not clamped to 0")
    func negativeXPassesThrough() {
        let pos = GhosttySurfaceNSView.viewMousePosition(
            viewLocalPoint: CGPoint(x: -5, y: 40),
            boundsHeight: 100
        )
        #expect(pos.x == -5)
        #expect(pos.y == 60)
    }

    @Test("drag exiting past the top edge yields negative y after flip")
    func dragAboveTopEdgeYieldsNegativeY() {
        // In AppKit's unflipped view space, localPoint.y > boundsHeight means the
        // pointer is above the view's top edge; the top-left flip drives y negative.
        let pos = GhosttySurfaceNSView.viewMousePosition(
            viewLocalPoint: CGPoint(x: -12, y: 130),
            boundsHeight: 100
        )
        #expect(pos.x == -12)
        #expect(pos.y == -30)
    }

    @Test("origin maps to top-left cell, not clamped away")
    func originFlips() {
        let pos = GhosttySurfaceNSView.viewMousePosition(
            viewLocalPoint: .zero,
            boundsHeight: 100
        )
        #expect(pos.x == 0)
        #expect(pos.y == 100)
    }
}
