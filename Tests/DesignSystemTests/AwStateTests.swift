import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("AwState")
struct AwStateTests {
    @Test("sorts by design priority")
    func sortsByPriority() {
        let states: [AwState] = [.idle, .running, .waiting, .output, .done, .thinking, .error, .needs]

        #expect(states.sorted() == [.needs, .error, .thinking, .done, .output, .waiting, .running, .idle])
    }

    @Test("treats needs and error as loud")
    func loudState() {
        #expect(AwState.needs.isLoud)
        #expect(AwState.error.isLoud)
        #expect(!AwState.thinking.isLoud)
        #expect(!AwState.done.isLoud)
        #expect(!AwState.output.isLoud)
        #expect(!AwState.waiting.isLoud)
        #expect(!AwState.running.isLoud)
        #expect(!AwState.idle.isLoud)
    }

    @Test("uses handoff labels")
    func labels() {
        #expect(AwState.needs.label == "Needs input")
        #expect(AwState.error.label == "Error")
        #expect(AwState.thinking.label == "Thinking")
        #expect(AwState.done.label == "Done")
        #expect(AwState.output.label == "Output")
        #expect(AwState.waiting.label == "Waiting")
        #expect(AwState.running.label == "Running")
        #expect(AwState.idle.label == "Idle")
    }

    @Test("resolves full badge glyphs")
    func fullBadgeGlyphs() {
        // `.pause` renders as the `pause.fill` SF Symbol, so it carries no
        // text glyph — like `.outputDot`/`.spinner`/`.play`. Two vertical bars
        // stay distinct from `.play`'s triangle for the tritanopia-adjacent
        // waiting/running pair (INT-599 replaced the old block-cursor bar).
        #expect(AwStateGlyph.resolve(for: .waiting) == .pause)
        #expect(AwStateGlyph.resolve(for: .waiting).text == nil)
        #expect(AwStateGlyph.resolve(for: .needs) == .attention)
        #expect(AwStateGlyph.resolve(for: .needs).text == "!")
        #expect(AwStateGlyph.resolve(for: .error) == .error)
        #expect(AwStateGlyph.resolve(for: .error).text == "x")
        #expect(AwStateGlyph.resolve(for: .running) == .play)
        // `output` and `idle` are distinct glyphs (filled vs faint dot); the
        // split lives in the enum, not a `where state == .output` clause.
        #expect(AwStateGlyph.resolve(for: .output) == .outputDot)
        #expect(AwStateGlyph.resolve(for: .output).text == nil)
        #expect(AwStateGlyph.resolve(for: .idle) == .dot)
        #expect(AwStateGlyph.resolve(for: .idle).text == nil)
    }

    @Test("waiting resolves to a distinct accessible palette token")
    func waitingPaletteTokenDiffersAndPassesContrast() {
        // `sky` reads well in mocha but fails the 3:1 non-text target against
        // latte sidebar/elevated/chrome backgrounds. `blue` is the quiet
        // existing token that passes both themes and stays distinct from
        // idle/running/output.
        let mocha = AwColors().mocha
        let latte = AwColors().latte
        #expect(mocha.blue != mocha.overlay0)
        #expect(mocha.blue != mocha.sapphire)
        #expect(mocha.blue != mocha.green)
        #expect(latte.blue != latte.overlay0)
        #expect(latte.blue != latte.sapphire)
        #expect(latte.blue != latte.green)
        #expect(mocha.sapphire != mocha.overlay0)
        #expect(latte.sapphire != latte.overlay0)
        #expect(minStatusContrast(mocha.sky, backgrounds: [mocha.mantle, mocha.surface0, mocha.crust]) >= 3)
        #expect(minStatusContrast(latte.sky, backgrounds: [latte.mantle, latte.surface0, latte.crust]) < 3)
        #expect(minStatusContrast(mocha.blue, backgrounds: [mocha.mantle, mocha.surface0, mocha.crust]) >= 3)
        #expect(minStatusContrast(latte.blue, backgrounds: [latte.mantle, latte.surface0, latte.crust]) >= 3)
    }

    // Resolves through the real production tokens (`AwState.color`,
    // `AwStateGlyph.badgeForeground`) so a regression in either wiring —
    // e.g. `.play` reverting to `onQuiet`, or a state's fill token losing
    // its Latte override — fails here, instead of a hardcoded hex table that
    // can pass while the actual view code has drifted. See INT-361 /
    // Codex plan-adversarial finding #2.
    @Test("solid-fill badge states clear the WCAG 1.4.11 non-text floor, all four palette variants")
    func solidFillBadgeStatesClearContrastFloor() {
        // thinking/idle are intentionally excluded — their AgentStatusBadge
        // backgrounds are surface tokens (chrome2/elevated), not their own
        // Status.* fill, and idle is a documented, deliberate low-contrast
        // exception (see AwColors.Status.idle).
        let solidFillStates: [(AwState, AwStateGlyph)] = [
            (.needs, .attention),
            (.error, .error),
            (.done, .checkmark),
            (.output, .outputDot),
            (.waiting, .pause),
            (.running, .play),
        ]

        for (state, glyph) in solidFillStates {
            #expect(AwStateGlyph.resolve(for: state) == glyph)
            for (appearance, label) in paletteAppearances {
                guard let fillHex = resolvedHex(state.color, appearance: appearance),
                      let foregroundHex = resolvedHex(glyph.badgeForeground, appearance: appearance) else {
                    Issue.record("\(state) \(label): could not resolve appearance")
                    continue
                }
                let ratio = contrastRatio(fillHex, foregroundHex)
                #expect(ratio >= 3, "\(state) fill vs \(glyph) foreground, \(label): \(ratio) < 3")
            }
        }
    }

    // StatusDot/AwState.color render these tokens directly as a dot fill or
    // stroke over sidebar/chrome surfaces (SidebarStatusFooter, the
    // collapsed group dot) — a separate contrast relationship from the
    // fill+foreground pairing above. `needs`/`output` are LIVE
    // (`SidebarStatusFooter.visibleStates`); `done`/`running` aren't
    // currently reachable via StatusDot but are explicitly in INT-361's
    // audited scope and cheap to close with the same pattern.
    // `error`/`waiting`/`thinking` already clear this floor unmodified —
    // included so a future regression on any of the three (e.g. `waiting`
    // reverting toward `sky`) fails here instead of passing the badge
    // foreground test above while silently failing chrome contrast.
    // `idle` is a documented, deliberate exception (AwColors.Status.idle) —
    // the only state excluded here.
    @Test("solid-fill status tokens clear the WCAG 1.4.11 non-text floor against chrome surfaces")
    func solidFillStatusTokensClearChromeContrastFloor() {
        let states: [AwState] = [.needs, .output, .done, .running, .error, .waiting, .thinking]
        let backgrounds: [(String, Color)] = [
            ("chrome (mantle)", Color.aw.surface.chrome),
            ("elevated (surface0)", Color.aw.surface.elevated),
            ("chrome2 (crust)", Color.aw.surface.chrome2),
        ]

        for state in states {
            for (appearance, appearanceLabel) in paletteAppearances {
                guard let fillHex = resolvedHex(state.color, appearance: appearance) else {
                    Issue.record("\(state) \(appearanceLabel): could not resolve appearance")
                    continue
                }
                for (backgroundLabel, background) in backgrounds {
                    guard let backgroundHex = resolvedHex(background, appearance: appearance) else {
                        Issue.record("\(backgroundLabel) \(appearanceLabel): could not resolve appearance")
                        continue
                    }
                    let ratio = contrastRatio(fillHex, backgroundHex)
                    #expect(ratio >= 3, "\(state) on \(backgroundLabel), \(appearanceLabel): \(ratio) < 3")
                }
            }
        }
    }

    private var paletteAppearances: [(NSAppearance.Name, String)] {
        [
            (.darkAqua, "mocha"),
            (.aqua, "latte"),
            (.accessibilityHighContrastDarkAqua, "mochaHC"),
            (.accessibilityHighContrastAqua, "latteHC"),
        ]
    }

    // Resolves a SwiftUI `Color` to its actual rendered hex under a given
    // `NSAppearance`, mirroring the dynamic-color resolution `AwColorTests`
    // already uses — necessary because `Color.aw.status.*` tokens are
    // `NSColor.awDynamic` providers, not static per-theme literals; reading
    // `AwPalette` fields directly (as `waitingPaletteTokenDiffersAndPasses
    // Contrast` above does) would silently decouple from a token's real
    // per-theme override, like the Latte darkening added in INT-361.
    private func resolvedHex(_ color: Color, appearance appearanceName: NSAppearance.Name) -> String? {
        guard let appearance = NSAppearance(named: appearanceName) else { return nil }
        let nsColor = NSColor(color)
        var resolvedCGColor: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedCGColor = nsColor.cgColor
        }
        guard let cgColor = resolvedCGColor,
              let converted = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return nil
        }
        let r = Int((converted.redComponent * 255).rounded())
        let g = Int((converted.greenComponent * 255).rounded())
        let b = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private func minStatusContrast(_ foreground: String, backgrounds: [String]) -> Double {
        backgrounds
            .map { contrastRatio(foreground, $0) }
            .min() ?? 0
    }

    private func contrastRatio(_ first: String, _ second: String) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        // This file's sRGB linearization cutoff (0.03928) differs from
        // `AwColor.swift`'s production `awRelativeLuminance` and
        // `AwColorTests`' independent copy (both 0.04045, the WCAG-errata
        // value). Both cutoffs land on the same 8-bit hex results in
        // practice, so this is a documented, not-worth-unifying divergence
        // rather than a bug — noted per INT-361 Codex plan-adversarial nit.
        let components = rgbComponents(hex).map { component in
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }

    private func rgbComponents(_ hex: String) -> [Double] {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(trimmed, radix: 16) else {
            return [0, 0, 0]
        }
        return [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        ]
    }
}
