import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("INT-611 idle badges and attention pills")
struct INT611ContrastTests {
    @Test("idle omits the status badge in full and collapsed agent tiles")
    func idleOmitsStatusBadge() {
        #expect(!AgentTile.showsStatusBadge(for: .idle, style: .full))
        #expect(!AgentTile.showsStatusBadge(for: .idle, style: .collapsed))

        for state in AwState.allCases where state != .idle {
            #expect(AgentTile.showsStatusBadge(for: state, style: .full))
        }
        #expect(AgentTile.showsStatusBadge(for: .needs, style: .collapsed))
        #expect(AgentTile.showsStatusBadge(for: .error, style: .collapsed))
    }

    @Test("attention pill text and glyph foreground clears AA on live base surfaces")
    func attentionPillForegroundClearsAA() throws {
        for (appearanceName, appearanceLabel) in Self.appearances {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for state in [AwState.needs, .error] {
                for baseCase in BaseCase.allCases {
                    var textRatio: Double?
                    var glyphRatio: Double?
                    appearance.performAsCurrentDrawingAppearance {
                        guard let elevated = Self.resolve(Color.aw.surface.elevated),
                              let hover = Self.resolve(Color.aw.surface.hover),
                              let tint = Self.resolve(state.color) else {
                            return
                        }
                        let base = baseCase == .elevated
                            ? elevated
                            : hover.composited(over: elevated)
                        guard let textForeground = Self.resolve(
                            AwPill.loudTintForeground(
                                for: state,
                                over: Color(nsColor: base)
                            )
                        ), let glyphForeground = AwPill.statusDotForeground(
                            for: state,
                            over: Color(nsColor: base)
                        ).flatMap({ Self.resolve($0) }) else { return }
                        let compositedTint = tint
                            .withAlphaComponent(CGFloat(AwColors.Status.tintOpacity))
                            .composited(over: base)
                        textRatio = Self.contrastRatio(textForeground, compositedTint)
                        glyphRatio = Self.contrastRatio(glyphForeground, compositedTint)
                    }

                    let measuredText = try #require(textRatio)
                    let measuredGlyph = try #require(glyphRatio)
                    #expect(
                        measuredText >= 4.5,
                        "\(state) pill text on \(baseCase), \(appearanceLabel): \(measuredText) < 4.5"
                    )
                    #expect(
                        measuredGlyph >= 4.5,
                        "\(state) pill glyph on \(baseCase), \(appearanceLabel): \(measuredGlyph) < 4.5"
                    )
                }
            }
        }
    }

    @Test("reduced-transparency attention fill matches the translucent composite")
    func reducedTransparencyFillMatchesComposite() throws {
        for (appearanceName, _) in Self.appearances {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for state in [AwState.needs, .error] {
                for baseCase in BaseCase.allCases {
                    var expected: NSColor?
                    var actual: NSColor?
                    appearance.performAsCurrentDrawingAppearance {
                        guard let elevated = Self.resolve(Color.aw.surface.elevated),
                              let hover = Self.resolve(Color.aw.surface.hover),
                              let tint = Self.resolve(state.color) else { return }
                        let base = baseCase == .elevated
                            ? elevated
                            : hover.composited(over: elevated)
                        expected = tint
                            .withAlphaComponent(CGFloat(AwColors.Status.tintOpacity))
                            .composited(over: base)
                        actual = Self.resolve(Color.aw.status.tintBackground(
                            for: state,
                            over: Color(nsColor: base)
                        ))
                    }

                    let expectedColor = try #require(expected)
                    let actualColor = try #require(actual)
                    #expect(abs(actualColor.redComponent - expectedColor.redComponent) < 0.001)
                    #expect(abs(actualColor.greenComponent - expectedColor.greenComponent) < 0.001)
                    #expect(abs(actualColor.blueComponent - expectedColor.blueComponent) < 0.001)
                    #expect(actualColor.alphaComponent == 1)
                }
            }
        }
    }

    private enum BaseCase: String, CaseIterable, CustomStringConvertible {
        case elevated
        case selectedHover

        var description: String { rawValue }
    }

    private static let appearances: [(NSAppearance.Name, String)] = [
        (.darkAqua, "mocha"),
        (.aqua, "latte"),
        (.accessibilityHighContrastDarkAqua, "mochaHC"),
        (.accessibilityHighContrastAqua, "latteHC"),
    ]

    private static func resolve(_ color: Color) -> NSColor? {
        NSColor(color).usingColorSpace(.sRGB)
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        func linearize(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(color.redComponent)
            + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }
}

private extension NSColor {
    func composited(over background: NSColor) -> NSColor {
        let backgroundAlpha = background.alphaComponent
        let outputAlpha = alphaComponent + backgroundAlpha * (1 - alphaComponent)
        guard outputAlpha > 0 else { return .clear }

        func blend(_ foreground: CGFloat, _ background: CGFloat) -> CGFloat {
            (foreground * alphaComponent
                + background * backgroundAlpha * (1 - alphaComponent)) / outputAlpha
        }

        return NSColor(
            srgbRed: blend(redComponent, background.redComponent),
            green: blend(greenComponent, background.greenComponent),
            blue: blend(blueComponent, background.blueComponent),
            alpha: outputAlpha
        )
    }
}
