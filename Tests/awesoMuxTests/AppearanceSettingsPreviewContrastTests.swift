import AppKit
import DesignSystem
import SwiftUI
import Testing

@testable import awesoMux

/// The theme preview's whole job is to show whether a chosen terminal
/// background is readable, so its own foreground choice has to be the more
/// readable of black and white — not "whichever side of an arbitrary cut the
/// background falls on".
///
/// Two distinct ways to get this wrong, and the pane originally had both:
/// applying the Rec. 709 coefficients to raw sRGB without gamma-expanding each
/// channel, and comparing against `0.5` rather than the WCAG black-vs-white
/// crossover at relative luminance ≈ 0.179 (the `0.18` cut named in
/// `AwColor.backgroundIsDark`). They partly cancel, which is why the bug is
/// narrow rather than obvious: raw luminance runs high, so a too-high threshold
/// still lands correctly for most greys.
///
/// This asserts the outcome that actually matters — the chosen foreground wins
/// on contrast ratio — rather than pinning either the formula or the constant,
/// so any correct implementation passes.
@Suite("Appearance settings preview contrast")
@MainActor
struct AppearanceSettingsPreviewContrastTests {
    /// Greys either side of the real crossover plus both shipped extremes.
    /// `#7A7A7A` is the one the original implementation got wrong; `#808080`
    /// and the lighter greys are cases it got *right* and a naive
    /// "just gamma-expand, keep 0.5" fix would have broken.
    @Test(
        "preview foreground is the higher-contrast choice",
        arguments: [
            (label: "#EFF1F5 Latte base", rgb: (239, 241, 245)),
            (label: "#B0B0B0", rgb: (176, 176, 176)),
            (label: "#999999", rgb: (153, 153, 153)),
            (label: "#808080 mid grey", rgb: (128, 128, 128)),
            (label: "#7A7A7A below crossover", rgb: (122, 122, 122)),
            (label: "#757575 alpha-flip case", rgb: (117, 117, 117)),
            (label: "#1E1E2E Mocha base", rgb: (30, 30, 46)),
        ])
    func previewForegroundMaximisesContrast(label: String, rgb: (Int, Int, Int)) {
        let background = NSColor(
            srgbRed: CGFloat(rgb.0) / 255,
            green: CGFloat(rgb.1) / 255,
            blue: CGFloat(rgb.2) / 255,
            alpha: 1
        )
        let chosen = TerminalBackgroundPreviewForeground.color(for: background)

        // Measure what is actually RENDERED — the returned colour composited
        // over the background — not an idealised black/white flag. A choice
        // made on opaque contrast but drawn with alpha can invert the winner,
        // and a test that strips the alpha cannot see that.
        let rendered = Self.composite(NSColor(chosen), over: background)
        let chosenRatio = Self.contrastRatio(rendered, background)
        let bestRatio = max(
            Self.contrastRatio(.black, background),
            Self.contrastRatio(.white, background)
        )

        #expect(
            chosenRatio >= bestRatio - 0.001,
            """
            \(label): rendered foreground scores \
            \(String(format: "%.2f", chosenRatio)):1, but the better of \
            black/white reaches \(String(format: "%.2f", bestRatio)):1
            """
        )
    }

    /// The rendered foreground must stay opaque. `backgroundIsDark` decides by
    /// comparing *opaque* black and white, so introducing alpha would choose on
    /// one colour and draw another — at `#757575` that inversion is real
    /// (composited white 3.99:1 vs black 4.08:1, against 4.61/4.56 opaque).
    /// If soft text is ever wanted, the choice must move to comparing the
    /// composited candidates and this guard should go with it.
    @Test("preview foreground is opaque, so the choice matches what is drawn")
    func previewForegroundIsOpaque() {
        for value in stride(from: 0, through: 255, by: 5) {
            let background = NSColor(
                srgbRed: CGFloat(value) / 255,
                green: CGFloat(value) / 255,
                blue: CGFloat(value) / 255,
                alpha: 1
            )
            let chosen = NSColor(TerminalBackgroundPreviewForeground.color(for: background))
            #expect(
                abs(chosen.alphaComponent - 1) < 0.001,
                "grey \(value): foreground alpha \(chosen.alphaComponent) — see note above"
            )
        }
    }

    private static func composite(_ overlay: NSColor, over background: NSColor) -> NSColor {
        let fg = overlay.usingColorSpace(.sRGB) ?? overlay
        let bg = background.usingColorSpace(.sRGB) ?? background
        let alpha = fg.alphaComponent
        return NSColor(
            srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
            green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
            blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> Double {
        let lhs = relativeLuminance(foreground)
        let rhs = relativeLuminance(background)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    /// Deliberately re-derived here rather than reaching into DesignSystem's
    /// private helper: an oracle that shares an implementation with the code
    /// under test cannot falsify it.
    private static func relativeLuminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linearize(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(srgb.redComponent)
            + 0.7152 * linearize(srgb.greenComponent)
            + 0.0722 * linearize(srgb.blueComponent)
    }
}
