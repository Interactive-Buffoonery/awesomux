import AppKit

// MARK: - HighlightContrast

/// Picks a warm-yellow highlight color whose alpha/luminance keeps marked text
/// legible against the terminal surface background (INT-285 lesson: contrast must
/// be measured against the terminal, not the app chrome).
///
/// Strategy — mirrors the focus-stripe logic in `AwColor.focusAccent`:
///   • compute the relative luminance of the terminal background (WCAG 2.1 §1.4.3)
///   • dark terminal (luminance < 0.18): use a more-opaque, slightly lighter
///     warm-yellow so the highlight reads as a tint without washing out dark text
///   • light terminal (luminance ≥ 0.18): use a lower-alpha, deeper golden yellow
///     so the composited result doesn't bleach into the light surface
///
/// The 0.18 luminance threshold is the WCAG black-vs-white crossover used by
/// `AwColor.backgroundIsDark`; we reuse it here for consistency.
enum HighlightContrast {

    // MARK: - Public API

    /// Returns a highlight tint for `<mark>` runs that stays legible over `bg`.
    ///
    /// - Parameter bg: The terminal's painted background color. Pass the value
    ///   from `GhosttyRuntime.terminalBackgroundColor` (already resolved through
    ///   `ghostty_config_get("background")` in `GhosttyConfigManager`) or the
    ///   `\.terminalBackgroundColor` SwiftUI environment value converted via
    ///   `NSColor(swiftUIColor)`.
    /// - Returns: A warm-yellow `NSColor` suitable as `.backgroundColor` on the
    ///   attributed string. Alpha is pre-multiplied into the choice rather than
    ///   composited separately so the caller needn't worry about transparency math.
    static func color(forTerminalBackground bg: NSColor) -> NSColor {
        // Normalize to sRGB — parity with AwColor's awRelativeLuminance so a
        // pattern/catalog color doesn't throw on component access.
        let srgb = bg.usingColorSpace(.sRGB) ?? NSColor(
            srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1
        )
        let luminance = relativeLuminance(srgb)

        if luminance < 0.18 {
            // Dark terminal: a bright warm-yellow at 0.40 alpha so the tint is
            // visible without clobbering the text contrast. The sRGB values are
            // a gold hue (255, 210, 80) that reads as "warm highlight" on Mocha,
            // Dracula, and similar dark palettes.
            return NSColor(srgbRed: 1.0, green: 0.82, blue: 0.31, alpha: 0.40)
        } else {
            // Light terminal: a deeper golden-orange at 0.45 alpha. The hue
            // (255, 153, 0) sits lower in luminance than the near-white surface, so
            // compositing at 0.45 alpha produces a WCAG contrast ratio ≥ 1.3:1 over
            // typical light bgs (#efeff4, pure white, etc.). The previous amber
            // (255, 191, 0) at 0.28 alpha composited to only ~1.12:1 — effectively
            // invisible on light surfaces (INT-562).
            return NSColor(srgbRed: 1.0, green: 0.60, blue: 0.00, alpha: 0.45)
        }
    }

    // MARK: - Luminance helper (private, independent of DesignSystem)

    /// WCAG 2.1 relative luminance. Kept private and independent from DesignSystem's
    /// `awRelativeLuminance` so `awesoMux` doesn't need a cross-target dependency for
    /// a three-line formula. The implementations must stay in sync — see the comment
    /// in `AwColor.swift` ("math rather than importing these — an independent oracle").
    private static func relativeLuminance(_ color: NSColor) -> Double {
        func linearize(_ v: CGFloat) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.redComponent)
             + 0.7152 * linearize(color.greenComponent)
             + 0.0722 * linearize(color.blueComponent)
    }
}
