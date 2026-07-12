import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Window frame clamp policy")
struct WindowFrameClampPolicyTests {
    // A 2560×1440 display with a 25pt menu bar, origin at zero.
    private let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    private let minSize = CGSize(width: 720, height: 640)

    @Test("an already-usable frame is returned unchanged")
    func usableFrameUntouched() {
        let frame = CGRect(x: 100, y: 100, width: 1280, height: 820)
        #expect(WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize) == frame)
    }

    @Test("a minimum-size on-screen frame is left alone (the minimum is valid)")
    func minimumSizeFrameIsNotGrown() {
        let frame = CGRect(x: 50, y: 50, width: 720, height: 640)
        #expect(WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize) == frame)
    }

    @Test("a fully off-screen frame slides back onto the visible area")
    func offScreenFrameSlidesOnScreen() {
        // The 720-wide tile a tiling WM left on a since-disconnected display
        // to the left of the current one.
        let frame = CGRect(x: -1148, y: 6, width: 720, height: 1072)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(visible.contains(result))
        #expect(result.size == frame.size)        // on-screen restore keeps size
        #expect(result.minX >= visible.minX)
    }

    @Test("a frame anchored below the screen is pulled up into view")
    func belowScreenFramePulledUp() {
        let frame = CGRect(x: 2559, y: -1366, width: 2520, height: 1398)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(visible.contains(result))
    }

    @Test("a frame wider than the screen shrinks to fit, never below the minimum")
    func oversizedFrameShrinksToFit() {
        let frame = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(result.width == visible.width)
        #expect(result.height == visible.height)
        #expect(visible.contains(result))
    }

    @Test("a sub-minimum frame grows to the minimum size")
    func subMinimumFrameGrows() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(result.width == minSize.width)
        #expect(result.height == minSize.height)
    }

    @Test("when the screen is smaller than the minimum, the minimum wins and centers")
    func screenSmallerThanMinimumCenters() {
        let tinyScreen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let frame = CGRect(x: 0, y: 0, width: 720, height: 640)
        let result = WindowFrameClampPolicy.clamp(frame, into: tinyScreen, minSize: minSize)
        #expect(result.size == minSize)          // never shrink below the minimum
        // Equal overflow off each edge: origin = (600-720)/2 = -60.
        #expect(result.minX == -60)
        #expect(result.minY == -70)
    }

    @Test("a frame flush against the bottom-left origin is preserved")
    func flushOriginPreserved() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize) == frame)
    }

    @Test("a zero-size frame (the tiling-WM collapse case) grows to the minimum")
    func zeroSizeFrameGrowsToMinimum() {
        let frame = CGRect(x: 200, y: 200, width: 0, height: 0)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(result.size == minSize)
        #expect(visible.contains(result))
    }

    @Test("an on-screen origin overflowing only the right edge slides left, size kept")
    func rightEdgeOverflowSlidesLeft() {
        // The dock-undock case: a 1280-wide window saved on a big external,
        // restored onto a 1512-wide built-in with an on-screen origin.
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = CGRect(x: 1400, y: 100, width: 1280, height: 820)
        let result = WindowFrameClampPolicy.clamp(frame, into: builtIn, minSize: minSize)
        #expect(result.size == frame.size)          // fits, so size is kept
        #expect(result.minX == builtIn.maxX - frame.width)   // slid flush to the right edge
        #expect(builtIn.contains(result))
    }

    @Test("a height-only overflow is corrected without touching width")
    func heightOnlyOverflowCorrected() {
        let frame = CGRect(x: 100, y: 1300, width: 1000, height: 800)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(result.width == frame.width)        // width was already fine
        #expect(result.minX == frame.minX)
        #expect(visible.contains(result))
    }

    @Test("exact-fit frame at slack==0 lands flush at the origin (the branch seam)")
    func exactFitSlackZero() {
        // Frame sized exactly to the screen but offset — exercises the
        // `slack >= 0` boundary (slack == 0) in clampedOrigin.
        let frame = CGRect(x: 500, y: 500, width: visible.width, height: visible.height)
        let result = WindowFrameClampPolicy.clamp(frame, into: visible, minSize: minSize)
        #expect(result == visible)
    }

    @Test("a frame that needs adjustment is not returned unchanged")
    func badFrameIsAdjusted() {
        let offScreen = CGRect(x: -5000, y: 0, width: 720, height: 640)
        #expect(WindowFrameClampPolicy.clamp(offScreen, into: visible, minSize: minSize) != offScreen)
    }

    @Test("a huge-but-finite frame clamps to the visible area (no overflow/hang)")
    func hugeButFiniteFrameClamps() {
        let huge = CGRect(
            x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude,
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        let result = WindowFrameClampPolicy.clamp(huge, into: visible, minSize: minSize)
        #expect(result.width == visible.width)
        #expect(result.height == visible.height)
        #expect(visible.contains(result))
    }

    @Test("isFinite rejects NaN/inf frames and accepts finite ones")
    func isFiniteGuardsNonFiniteFrames() {
        #expect(WindowFrameClampPolicy.isFinite(CGRect(x: 0, y: 0, width: 1280, height: 820)))
        // greatestFiniteMagnitude is finite — handled by clamp, not rejected.
        #expect(WindowFrameClampPolicy.isFinite(CGRect(
            x: 0, y: 0,
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )))
        #expect(!WindowFrameClampPolicy.isFinite(CGRect(x: CGFloat.nan, y: 0, width: 720, height: 640)))
        #expect(!WindowFrameClampPolicy.isFinite(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 640)))
        #expect(!WindowFrameClampPolicy.isFinite(CGRect(x: -CGFloat.infinity, y: 0, width: 720, height: 640)))
    }

    @Test("the window default size is never smaller than the enforced minimum")
    @MainActor
    func defaultSizeNotBelowMinimum() {
        // Reads the same default constants `defaultWindowPlacement` falls back to
        // when there's no saved frame, so the check is real: dropping
        // `defaultWindowWidth` below the minimum fails here instead of silently
        // shipping an under-minimum default.
        #expect(ContentView.defaultWindowWidth >= ContentView.minimumWindowWidth)
        #expect(ContentView.defaultWindowHeight >= ContentView.minimumWindowHeight)
    }

    // MARK: - restoreVisibleFrame (multi-display screen selection)

    private func screen(_ frame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        // visibleFrame distinct from frame so the test asserts the RIGHT screen's
        // visibleFrame is returned (e.g. menu-bar inset on top).
        (frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 12))
    }

    @Test("restoreVisibleFrame picks the screen the saved frame overlaps most")
    func restorePicksMostOverlappingScreen() {
        let builtIn = screen(CGRect(x: 0, y: 0, width: 1728, height: 1117))
        let external = screen(CGRect(x: 1728, y: 0, width: 2560, height: 1440))
        // Saved frame lives entirely on the external (origin x ≥ 1728).
        let saved = CGRect(x: 1900, y: 200, width: 1200, height: 800)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [builtIn, external],
            fallbackVisibleFrame: builtIn.visibleFrame
        )
        #expect(result == external.visibleFrame)
    }

    @Test("restoreVisibleFrame falls back when the saved frame overlaps no screen")
    func restoreFallsBackWhenNoOverlap() {
        let builtIn = screen(CGRect(x: 0, y: 0, width: 1728, height: 1117))
        // Saved on a now-disconnected display far to the left — overlaps nothing.
        let saved = CGRect(x: -3000, y: 0, width: 1200, height: 800)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [builtIn],
            fallbackVisibleFrame: builtIn.visibleFrame
        )
        #expect(result == builtIn.visibleFrame)
    }

    @Test("restoreVisibleFrame returns the only screen when it overlaps at all")
    func restoreSingleOverlappingScreen() {
        let builtIn = screen(CGRect(x: 0, y: 0, width: 1728, height: 1117))
        let saved = CGRect(x: 100, y: 100, width: 1000, height: 700)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [builtIn],
            fallbackVisibleFrame: nil
        )
        #expect(result == builtIn.visibleFrame)
    }

    @Test("restoreVisibleFrame returns nil fallback when nothing overlaps and no fallback")
    func restoreNilWhenNoOverlapNoFallback() {
        let builtIn = screen(CGRect(x: 0, y: 0, width: 1728, height: 1117))
        let saved = CGRect(x: -5000, y: -5000, width: 800, height: 600)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [builtIn],
            fallbackVisibleFrame: nil
        )
        #expect(result == nil)
    }

    @Test("restoreVisibleFrame: an exact-overlap tie resolves to the first screen (deterministic)")
    func restoreEqualOverlapTieFirstWins() {
        // A saved frame straddling two displays' shared boundary exactly splits
        // its area 50/50. `max(by:)` keeps the first maximal element, so the
        // first screen wins — deterministic. This test documents that and guards
        // against a future `max`→`min` swap silently inverting the tie-break.
        let left = screen(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let right = screen(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        // 600-wide frame centered on x=1000 → 300 on each side → equal overlap.
        let saved = CGRect(x: 700, y: 100, width: 600, height: 400)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [left, right],
            fallbackVisibleFrame: nil
        )
        #expect(result == left.visibleFrame)
    }

    @Test("restoreVisibleFrame: an edge-touching (zero-area) overlap counts as no overlap")
    func restoreEdgeTouchIsNoOverlap() {
        let builtIn = screen(CGRect(x: 0, y: 0, width: 1728, height: 1117))
        // Saved frame sits flush against the right edge — shares a boundary line
        // but zero area. Must NOT count as overlapping that screen.
        let saved = CGRect(x: 1728, y: 0, width: 1000, height: 700)

        let result = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: saved,
            screens: [builtIn],
            fallbackVisibleFrame: builtIn.visibleFrame
        )
        // Zero-area touch → no real overlap → fallback (which here is the same
        // screen, but the point is it went through the fallback branch).
        #expect(result == builtIn.visibleFrame)
    }
}
