import Testing
import AppKit
@testable import awesoMux

// MARK: - HighlightContrast tests

/// TDD gate for Task 6 (INT-562): dark terminal bg → higher-luminance highlight
/// than light terminal bg, confirming the contrast logic branches correctly.
///
/// Luminance is computed independently here (same WCAG formula) so the tests act
/// as an oracle rather than tautologically calling the production helper.
@Suite("HighlightContrast")
struct HighlightContrastTests {

    // MARK: - Luminance helper (independent oracle)

    /// WCAG 2.1 relative luminance — independent copy so tests don't share
    /// implementation with production code (mirrors AwColor.swift's rationale).
    private func relativeLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            Issue.record("Could not convert color \(color) to sRGB")
            return 0
        }
        func lin(_ v: CGFloat) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(srgb.redComponent)
             + 0.7152 * lin(srgb.greenComponent)
             + 0.0722 * lin(srgb.blueComponent)
    }

    // Approximate luminance of the FULLY composited result: highlight alpha-blended
    // over the terminal background. This mirrors how the eye perceives it.
    private func compositedLuminance(highlight: NSColor, over bg: NSColor) -> Double {
        // Pre-multiply highlight onto bg (standard alpha-blend, sRGB linear approx).
        guard let h = highlight.usingColorSpace(.sRGB),
              let b = bg.usingColorSpace(.sRGB) else {
            Issue.record("Could not convert highlight or bg to sRGB")
            return 0
        }
        let alpha = Double(h.alphaComponent)
        func blend(_ hc: CGFloat, _ bc: CGFloat) -> CGFloat {
            CGFloat(alpha * Double(hc) + (1 - alpha) * Double(bc))
        }
        let composited = NSColor(
            srgbRed: blend(h.redComponent, b.redComponent),
            green: blend(h.greenComponent, b.greenComponent),
            blue: blend(h.blueComponent, b.blueComponent),
            alpha: 1
        )
        return relativeLuminance(composited)
    }

    // MARK: - Red → green

    /// Core TDD assertion: the highlight chosen for a dark terminal background must
    /// increase the apparent luminance of the terminal surface by MORE than the
    /// highlight chosen for a light terminal. On a dark surface a bright warm-yellow
    /// at higher alpha lifts luminance dramatically; on a light surface the
    /// lower-alpha deeper amber barely nudges an already-bright surface.
    ///
    /// We measure delta-luminance (composited − background) rather than absolute
    /// composited luminance because absolute luminance is dominated by the bg itself
    /// (dark bg stays dark overall, light bg stays light) — the delta isolates how
    /// much the highlight "punches".
    @Test("dark bg yields higher-luminance highlight than light bg")
    func darkBgYieldsHigherLuminanceHighlight() {
        // A typical dark terminal (Mocha base).
        let darkBg = NSColor(srgbRed: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x2e / 255.0, alpha: 1)
        // A typical light terminal (Latte base / near-white).
        let lightBg = NSColor(srgbRed: 0xef / 255.0, green: 0xef / 255.0, blue: 0xf4 / 255.0, alpha: 1)

        let darkHighlight = HighlightContrast.color(forTerminalBackground: darkBg)
        let lightHighlight = HighlightContrast.color(forTerminalBackground: lightBg)

        let darkBgLum = relativeLuminance(darkBg)
        let lightBgLum = relativeLuminance(lightBg)

        let darkDelta = compositedLuminance(highlight: darkHighlight, over: darkBg) - darkBgLum
        let lightDelta = compositedLuminance(highlight: lightHighlight, over: lightBg) - lightBgLum

        // The dark-terminal highlight must lift luminance more than the light-terminal
        // highlight: that's the "brighter, more opaque tint on dark" guarantee.
        #expect(darkDelta > lightDelta,
                "dark-bg highlight delta (\(darkDelta)) should exceed light-bg highlight delta (\(lightDelta))")
    }

    /// The highlight returned for a dark background must itself have a raw (non-
    /// composited) luminance higher than the highlight returned for a light bg.
    /// This pins the implementation to choosing the brighter hue variant on dark.
    @Test("dark-bg highlight color is intrinsically higher luminance than light-bg variant")
    func darkBgHighlightColorIsIntrinsicallyBrighter() {
        let darkBg = NSColor(srgbRed: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x2e / 255.0, alpha: 1)
        let lightBg = NSColor(srgbRed: 0xef / 255.0, green: 0xef / 255.0, blue: 0xf4 / 255.0, alpha: 1)

        let darkHighlight = HighlightContrast.color(forTerminalBackground: darkBg)
        let lightHighlight = HighlightContrast.color(forTerminalBackground: lightBg)

        let darkHL = relativeLuminance(darkHighlight.withAlphaComponent(1))
        let lightHL = relativeLuminance(lightHighlight.withAlphaComponent(1))

        #expect(darkHL >= lightHL,
                "dark-bg variant luminance (\(darkHL)) should be >= light-bg variant (\(lightHL))")
    }

    /// Legibility FLOOR: the composited highlight must differ from the plain terminal
    /// background by a WCAG contrast ratio ≥ 1.3:1, for BOTH a near-black AND a
    /// near-white terminal. This ensures the highlight is visible, not washed out.
    ///
    /// Threshold derivation: WCAG contrast = (Lbg + 0.05) / (Lcomp + 0.05) (or
    /// the inverse when the composited result is lighter). A ratio below 1.3:1 renders
    /// the highlight effectively invisible to typical users, per INT-562 analysis.
    ///
    /// Historical note: the original light-branch amber (1.0, 0.75, 0.0) at alpha 0.28
    /// composited to ~1.12:1 over #efeff4, which failed this floor. The current
    /// golden-orange (1.0, 0.60, 0.0) at alpha 0.45 yields ~1.39:1.
    @Test("composited highlight meets legibility floor (WCAG ≥ 1.3:1) on both dark and light bgs")
    func compositedHighlightMeetsLegibilityFloor() {
        // Near-black terminal (Mocha base #1e1e2e).
        let darkBg = NSColor(srgbRed: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x2e / 255.0, alpha: 1)
        // Near-white terminal (Latte base / #efeff4).
        let lightBg = NSColor(srgbRed: 0xef / 255.0, green: 0xef / 255.0, blue: 0xf4 / 255.0, alpha: 1)

        for bg in [darkBg, lightBg] {
            let highlight = HighlightContrast.color(forTerminalBackground: bg)
            let bgLum = relativeLuminance(bg)
            let compLum = compositedLuminance(highlight: highlight, over: bg)

            // WCAG contrast between composited surface and plain background.
            let lighter = max(bgLum, compLum)
            let darker  = min(bgLum, compLum)
            let ratio = (lighter + 0.05) / (darker + 0.05)

            #expect(ratio >= 1.3,
                    "highlight over bg \(bg) must meet WCAG 1.3:1 floor; got \(ratio):1 (bgLum=\(bgLum), compLum=\(compLum))")
        }
    }

    /// Sanity: neither variant is transparent (alpha 0) or fully opaque (alpha 1),
    /// confirming the tint approach (partial alpha blended over the terminal surface).
    @Test("highlight alpha is between 0 and 1 (exclusive) for both dark and light terminals")
    func alphaIsPartial() {
        let darkBg = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 1)
        let lightBg = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)

        for bg in [darkBg, lightBg] {
            let h = HighlightContrast.color(forTerminalBackground: bg)
            guard let srgb = h.usingColorSpace(.sRGB) else {
                Issue.record("Could not convert highlight to sRGB for bg \(bg)")
                continue
            }
            let alpha = Double(srgb.alphaComponent)
            #expect(alpha > 0 && alpha < 1,
                    "highlight alpha must be partial (0<α<1); got \(alpha) for bg \(bg)")
        }
    }

    /// Mid-tone terminal (luminance near 0.18 crossover): both branches must return
    /// a non-nil, non-clear color without crashing.
    @Test("mid-tone terminal returns a valid color without crashing")
    func midToneTerminal() {
        // sRGB (0.40, 0.40, 0.40) ≈ luminance 0.13, just inside the dark branch.
        let midDark = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.40, alpha: 1)
        // sRGB (0.50, 0.50, 0.50) ≈ luminance 0.21, just inside the light branch.
        let midLight = NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1)

        for bg in [midDark, midLight] {
            let h = HighlightContrast.color(forTerminalBackground: bg)
            let srgb = h.usingColorSpace(.sRGB)
            #expect(srgb != nil, "color must be representable in sRGB for bg \(bg)")
        }
    }
}
