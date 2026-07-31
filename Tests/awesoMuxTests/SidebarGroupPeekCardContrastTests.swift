import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import awesoMux

/// WCAG 1.4.3 AA coverage for the collapsed-rail group peek card (#287).
///
/// Ratios are taken from the design-token values, not from sampled pixels.
/// `bitmapImageRepForCachingDisplay` hands back colors in the display's own
/// profile — `surface.elevated` (#ccd0da) reads back as #d6d9e0 on a wide-gamut
/// display — so a rendered sample measures the monitor, while WCAG is defined
/// on the specified sRGB colors. The composite below is the same source-over
/// the card's `.overlay` performs, evaluated on those specified colors.
@Suite("Sidebar group peek card contrast")
@MainActor
struct SidebarGroupPeekCardContrastTests {
    private static let aaFloor = 4.5

    /// Both halves of the card's contrast budget in one assertion: the wash
    /// alpha, and the foreground token every label on the card draws in.
    ///
    /// Latte is the tight side — `surface.elevated` is `surface0` (#ccd0da),
    /// which leaves `text` (the darkest token in the palette) barely above the
    /// floor before any wash at all. Mocha has more room but is not exempt:
    /// `text2` fell to 4.32:1 on the yellow tint there, so this was never the
    /// Latte-only failure the report described.
    @Test("every group tint leaves the card's label token above the AA floor")
    func everyTintKeepsLabelTokenAboveAAFloor() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for accent in AwTintAccent.allCases {
                guard
                    let (foreground, surface) = Self.resolve(appearance: appearance, accent: accent)
                else {
                    Issue.record("could not resolve \(appearance.rawValue)/\(accent)")
                    continue
                }
                let ratio = Self.contrastRatio(foreground, surface)
                #expect(
                    ratio >= Self.aaFloor,
                    """
                    peek card label on \(accent) tint, \(appearance.rawValue): \
                    \(ratio) < \(Self.aaFloor)
                    """
                )
            }
        }
    }

    /// The card's own doc comment says to reach for `text`; this is what makes
    /// that binding rather than advisory. Every dimmer token was measured on
    /// this surface and misses the floor — at the worst tint `text2` is 2.84:1
    /// and `railText`, which exists for exactly this class of problem, is
    /// 3.59:1 because it was tuned for mantle and this card is not mantle.
    ///
    /// A ratio assertion cannot cover this: SwiftUI exposes no readback for a
    /// view's resolved foreground, and sampled glyph pixels are antialiased
    /// blends of ink and background — the header count's darkest pixel measures
    /// 3.73:1 against its own background even drawn in `text`, whose specified
    /// ratio is 4.58:1 — so no rendered measurement can stand in for the token
    /// identity.
    @Test("the peek card draws no text token that misses AA on its own surface")
    func peekCardUsesNoSubAAForegroundToken() throws {
        let source = try String(contentsOf: Self.cardSource, encoding: .utf8)
        let codeLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        try #require(
            codeLines.contains { $0.contains("Color.aw.text") },
            "source scan found no color tokens in \(Self.cardSource.path)"
        )

        for token in ["Color.aw.text2", "Color.aw.text3", "Color.aw.textFaint", "Color.aw.railText"] {
            let offenders = codeLines.filter { $0.contains(token) }
            #expect(
                offenders.isEmpty,
                """
                \(token) misses \(Self.aaFloor):1 on the peek card's washed surface; \
                use Color.aw.text. Offending lines: \(offenders.map { $0.trimmingCharacters(in: .whitespaces) })
                """
            )
        }
    }

    private static let cardSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // awesoMuxTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/awesoMux/Views/SidebarGroupPeekCard.swift")

    /// The label foreground and the card's painted surface, both resolved for
    /// one appearance. Resolution has to happen inside the drawing appearance —
    /// every `Color.aw` token is a dynamic `NSColor`, and reading its
    /// components outside the block silently yields the default variant.
    private static func resolve(
        appearance: NSAppearance.Name,
        accent: AwTintAccent
    ) -> (foreground: NSColor, surface: NSColor)? {
        guard let appearance = NSAppearance(named: appearance) else { return nil }
        var resolved: (NSColor, NSColor)?
        appearance.performAsCurrentDrawingAppearance {
            let surface = Color.aw.composited(
                Color.aw.tint(accent).opacity(SidebarGroupPeekCard.tintWashOpacity),
                over: Color.aw.surface.elevated
            )
            guard
                let foreground = NSColor(Color.aw.text).usingColorSpace(.sRGB),
                let background = NSColor(surface).usingColorSpace(.sRGB)
            else { return }
            resolved = (foreground, background)
        }
        return resolved
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        func linearize(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.redComponent)
            + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }
}
