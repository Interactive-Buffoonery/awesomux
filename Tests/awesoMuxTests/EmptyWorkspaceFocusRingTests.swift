import AppKit
import Testing

@testable import awesoMux

/// Focus-ring shape for the empty state's primary action (#278).
///
/// The visible "New Workspace" button is a SwiftUI `.borderedProminent`
/// control; the `NSButton` under test is the invisible AppKit proxy layered
/// over it, which exists so the button has one stable keyboard and VoiceOver
/// identity. The proxy is exactly the size and position of the visible button,
/// so the ring went wrong purely in shape: a button cell masks its focus ring
/// with a plain rectangle, measured here at full width and inset 4pt top and
/// bottom, which an exterior ring turns into a hard square-cornered halo over
/// a rounded control.
///
/// The two halves of the assertion only hold together for a rounded rectangle
/// filling the bounds. Edge coverage alone would pass for the square mask that
/// shipped; corner emptiness alone would pass for the inset one, since its
/// corners were already outside the mask. Neither is worth asserting on its own.
///
/// The assertions read the mask AppKit would actually stroke, by drawing
/// `drawFocusRingMask()` into a bitmap and testing coverage. Coverage is a
/// binary property of the drawn path, so unlike a colour readback it is not
/// affected by the display profile.
@Suite("Empty workspace focus ring")
@MainActor
struct EmptyWorkspaceFocusRingTests {
    /// The proxy's laid-out size in the empty state at a typical window width,
    /// taken from the hosted view hierarchy. Nothing below depends on the exact
    /// numbers — the assertions are corner and edge coverage — but a realistic
    /// aspect ratio keeps the corner arcs the size they are on screen.
    private static let buttonSize = NSSize(width: 143.5, height: 24)

    @Test("the focus-ring mask is a rounded rect that fills the button")
    func focusRingMaskIsRounded() throws {
        let mask = try Self.renderMask()

        // Edge coverage: the mask has to reach the control's edges, or the ring
        // is stroked somewhere inside the bezel. This is also the positive
        // control — a mask that drew nothing would satisfy every corner
        // assertion below without the ring ever having been shaped.
        #expect(mask.isCovered(atFractionX: 0.5, y: 0.5), "the mask drew no interior coverage")
        #expect(mask.isCovered(atFractionX: 0.5, y: 0.02), "the mask stops short of the top edge")
        #expect(
            mask.isCovered(atFractionX: 0.5, y: 0.98),
            "the mask stops short of the bottom edge"
        )
        #expect(
            mask.isCovered(atFractionX: 0.02, y: 0.5),
            "the mask stops short of the leading edge"
        )

        for (name, x, y) in [
            ("top-leading", 0, 0),
            ("top-trailing", mask.width - 1, 0),
            ("bottom-leading", 0, mask.height - 1),
            ("bottom-trailing", mask.width - 1, mask.height - 1),
        ] {
            #expect(
                !mask.isCovered(x: x, y: y),
                """
                \(name) corner is inside the focus-ring mask, so AppKit strokes a \
                square halo around a rounded button
                """
            )
        }
    }

    /// The mask has to stay inside the proxy's own bounds. `focusRingMaskBounds`
    /// is what AppKit invalidates when the ring appears or moves, and NSView's
    /// default is `NSZeroRect` — a custom `drawFocusRingMask()` paired with the
    /// default bounds can leave the ring undrawn or its dirty rect wrong.
    @Test("the focus-ring mask bounds cover the button")
    func focusRingMaskBoundsCoverTheButton() {
        let button = EmptyWorkspacePrimaryActionFocusButton()
        button.setFrameSize(Self.buttonSize)
        #expect(button.focusRingMaskBounds == button.bounds)
    }

    private struct Mask {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        func isCovered(x: Int, y: Int) -> Bool {
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
        }

        func isCovered(atFractionX x: Double, y: Double) -> Bool {
            isCovered(
                x: min(width - 1, Int(Double(width) * x)),
                y: min(height - 1, Int(Double(height) * y))
            )
        }
    }

    private static func renderMask() throws -> Mask {
        let button = EmptyWorkspacePrimaryActionFocusButton()
        button.setFrameSize(buttonSize)
        let rep = try #require(
            button.bitmapImageRepForCachingDisplay(in: button.bounds),
            "could not allocate a bitmap for the mask"
        )
        let context = try #require(
            NSGraphicsContext(bitmapImageRep: rep),
            "could not bind a graphics context to the mask bitmap"
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        button.drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
        return Mask(rep: rep)
    }
}
