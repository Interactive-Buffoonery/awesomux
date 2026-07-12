import CoreGraphics

/// Pure geometry for keeping a restored window frame usable.
///
/// SwiftUI's window-frame autosave faithfully replays whatever frame the window
/// last had — including a frame a tiling window manager squeezed to the minimum,
/// or one anchored to a display that has since been disconnected. The result is
/// a window that launches off-screen or larger than the current screen. This
/// clamps such a frame back onto the visible area at a sane minimum size, while
/// leaving an already-usable frame untouched (so it never fights a window the
/// user deliberately placed and sized).
///
/// Kept AppKit-free (CGRect/CGSize only) so it unit-tests without a real screen.
/// The thin AppKit caller in `AppDelegate` supplies `NSScreen.visibleFrame`.
enum WindowFrameClampPolicy {
    /// Returns `frame` adjusted to fit `visibleFrame` at no smaller than
    /// `minSize`. A frame already within bounds and at/above the minimum is
    /// returned unchanged.
    static func clamp(_ frame: CGRect, into visibleFrame: CGRect, minSize: CGSize) -> CGRect {
        var result = frame

        // Size: never below the minimum, never larger than the visible area.
        // The `max(minSize, visible)` guard keeps a screen smaller than the
        // minimum from inverting the bounds — the minimum wins there.
        let maxWidth = max(minSize.width, visibleFrame.width)
        let maxHeight = max(minSize.height, visibleFrame.height)
        result.size.width = min(max(result.width, minSize.width), maxWidth)
        result.size.height = min(max(result.height, minSize.height), maxHeight)

        // Origin: slide fully on-screen; center on the axis when too tight.
        result.origin.x = clampedOrigin(
            result.minX, span: result.width, lower: visibleFrame.minX, upper: visibleFrame.maxX
        )
        result.origin.y = clampedOrigin(
            result.minY, span: result.height, lower: visibleFrame.minY, upper: visibleFrame.maxY
        )
        return result
    }

    /// True when every component of `frame` is finite. A window frame replayed
    /// from a corrupted/hand-edited autosave can contain `NaN`/`±inf`, and
    /// `clamp` does NOT sanitize `NaN`: Swift's `max(x, y)` is `y >= x ? y : x`,
    /// so a `NaN` *first* argument (which is exactly how every frame component
    /// enters — `max(result.width, minSize.width)`, `max(origin, lower)`) makes
    /// the comparison false and returns the `NaN`. A fully-`NaN` frame therefore
    /// clamps to all-`NaN` (verified empirically), and `NaN != NaN` would then
    /// defeat the caller's "already fine" guard and forward a non-finite frame
    /// into `setFrame` — a launch crash that re-arms every relaunch. Callers
    /// reject non-finite frames with this before clamping. Matches the repo's
    /// `isFinite` boundary guard (e.g. `SidebarWidthPreferenceStore`).
    static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
    }

    /// Pick the `visibleFrame` to restore a saved window frame into: the screen
    /// it overlaps most (so a docked relaunch returns to the external monitor it
    /// lived on, not the primary). Falls back to `fallbackVisibleFrame` only when
    /// the saved frame overlaps NO current screen — the genuine "saved on a
    /// now-disconnected display" case. `screens` and `savedFrame` must share the
    /// same coordinate space (AppKit global). Pure so the multi-display selection
    /// is testable without a real screen arrangement.
    static func restoreVisibleFrame(
        forSavedFrame savedFrame: CGRect,
        screens: [(frame: CGRect, visibleFrame: CGRect)],
        fallbackVisibleFrame: CGRect?
    ) -> CGRect? {
        let best = screens.max { lhs, rhs in
            intersectionArea(lhs.frame, savedFrame) < intersectionArea(rhs.frame, savedFrame)
        }
        if let best, intersectionArea(best.frame, savedFrame) > 0 {
            return best.visibleFrame
        }
        return fallbackVisibleFrame
    }

    /// Area of the overlap of two rects, or 0 when they don't intersect.
    /// `CGRect.intersection` returns `.null` for non-overlapping rects (infinite
    /// width/height), so guard that before multiplying.
    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        guard !overlap.isNull, !overlap.isEmpty else { return 0 }
        return overlap.width * overlap.height
    }

    private static func clampedOrigin(
        _ origin: CGFloat, span: CGFloat, lower: CGFloat, upper: CGFloat
    ) -> CGFloat {
        let slack = (upper - lower) - span
        guard slack >= 0 else {
            // Span exceeds the axis (only reachable if minSize > visible);
            // center it so equal overflow spills off each edge.
            return lower + slack / 2
        }
        return min(max(origin, lower), upper - span)
    }
}
