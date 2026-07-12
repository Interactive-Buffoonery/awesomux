import AwesoMuxCore
import CoreGraphics
import Testing
@testable import awesoMux

@Suite("PaneDropZoneResolver geometry")
struct PaneDropZoneResolverTests {
    // A 100x100 pane: edgeInset 0.25 => strips at x/y < 25 or > 75, center is the
    // inner 25...75 square.
    private let square = CGSize(width: 100, height: 100)

    // MARK: - Strip boundaries

    @Test("dead center resolves to the swap zone")
    func deadCenterIsCenter() {
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 50), in: square) == .center)
    }

    @Test("just inside each strip boundary is center, just outside is the edge")
    func stripBoundaries() {
        // left strip ends at x == 25. x = 26 (clear of every strip) is center;
        // x = 24 is inside the left strip.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 26, y: 50), in: square) == .center)
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 24, y: 50), in: square) == .edge(.left))
        // right strip begins at x == 75.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 74, y: 50), in: square) == .center)
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 76, y: 50), in: square) == .edge(.right))
        // top strip ends at y == 25.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 24), in: square) == .edge(.up))
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 26), in: square) == .center)
        // bottom strip begins at y == 75.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 76), in: square) == .edge(.down))
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 74), in: square) == .center)
    }

    // MARK: - Pure edges (clear of corners)

    @Test("mid-height left and right strips resolve horizontally")
    func midHeightLeftRight() {
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 5, y: 50), in: square) == .edge(.left))
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 95, y: 50), in: square) == .edge(.right))
    }

    @Test("mid-width top and bottom strips resolve vertically")
    func midWidthTopBottom() {
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 5), in: square) == .edge(.up))
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 50, y: 95), in: square) == .edge(.down))
    }

    // MARK: - Corners of a wide-short pane (normalized-depth tiebreak)

    @Test("wide-short pane corners resolve by normalized penetration depth")
    func wideShortCorners() {
        // 200 wide x 50 tall. Horizontal strips: x < 50 / x > 150. Vertical
        // strips: y < 12.5 / y > 37.5. Without normalizing by pane size, the
        // wider horizontal strips would dominate every corner; normalization by
        // width/height makes the tiebreak fair.
        let wide = CGSize(width: 200, height: 50)

        // Top-left corner point (5, 2): horizontalDepth = (50-5)/200 = 0.225,
        // verticalDepth = (12.5-2)/50 = 0.21 -> horizontal wins (left).
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 5, y: 2), in: wide) == .edge(.left))
        // Deep into the vertical strip near the top edge but centered: (100, 1)
        // -> vertical only -> up.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 100, y: 1), in: wide) == .edge(.up))
        // Top-right corner (198, 1): horizontalDepth = (198-150)/200 = 0.24,
        // verticalDepth = (12.5-1)/50 = 0.23 -> horizontal wins (right).
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 198, y: 1), in: wide) == .edge(.right))
        // Bottom-left corner deep in vertical: (10, 49): horizontalDepth
        // = (50-10)/200 = 0.20, verticalDepth = (49-37.5)/50 = 0.23 -> vertical
        // wins (down).
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 10, y: 49), in: wide) == .edge(.down))
    }

    // MARK: - Equal-depth tie

    @Test("equal normalized depth tie breaks toward the horizontal edge")
    func equalDepthTieGoesHorizontal() {
        // On a square, the exact diagonal corner has equal horizontal and
        // vertical penetration; `horizontalDepth >= verticalDepth` resolves the
        // tie horizontally. At (10, 10): both depths = (25-10)/100 = 0.15.
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 10, y: 10), in: square) == .edge(.left))
    }

    // MARK: - Degenerate sizes

    @Test("zero size resolves to center (no strips to enter)")
    func zeroSizeIsCenter() {
        #expect(PaneDropZoneResolver.zone(at: .zero, in: .zero) == .center)
        #expect(PaneDropZoneResolver.zone(at: CGPoint(x: 5, y: 5), in: .zero) == .center)
    }

    @Test("zero width or height alone resolves to center")
    func zeroDimensionIsCenter() {
        #expect(
            PaneDropZoneResolver.zone(at: CGPoint(x: 0, y: 10), in: CGSize(width: 0, height: 100))
                == .center
        )
        #expect(
            PaneDropZoneResolver.zone(at: CGPoint(x: 10, y: 0), in: CGSize(width: 100, height: 0))
                == .center
        )
    }
}
