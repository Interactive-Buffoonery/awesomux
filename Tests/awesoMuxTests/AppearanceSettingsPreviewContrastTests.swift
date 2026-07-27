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
        let hex = label

        // The pane tints its foreground, but the readability decision is
        // black-vs-white; compare the undimmed choice it stands for.
        let chosenIsWhite = Self.resolvesToWhite(chosen)
        let blackRatio = Self.contrastRatio(.black, background)
        let whiteRatio = Self.contrastRatio(.white, background)
        let expectedIsWhite = whiteRatio > blackRatio

        #expect(
            chosenIsWhite == expectedIsWhite,
            """
            \(hex): chose \(chosenIsWhite ? "white" : "black") but \
            \(expectedIsWhite ? "white" : "black") has better contrast \
            (black \(String(format: "%.2f", blackRatio)):1 vs \
            white \(String(format: "%.2f", whiteRatio)):1)
            """
        )
    }

    private static func resolvesToWhite(_ color: Color) -> Bool {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        // Black-with-alpha and white-with-alpha are unambiguous at the extremes.
        return resolved.redComponent > 0.5
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
