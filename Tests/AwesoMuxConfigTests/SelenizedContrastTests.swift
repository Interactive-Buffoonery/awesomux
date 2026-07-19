import Foundation
import Testing

@Suite("Selenized contrast")
struct SelenizedContrastTests {
    @Test("Selenized White ANSI slots meet their documented contrast tiers")
    func selenizedWhiteANSISlotsMeetDocumentedContrastTiers() {
        let background = "#ffffff"
        let slots: [(hex: String, role: String, minimum: Double?)] = [
            // Genuine background-tint neutrals in Selenized's own design (its
            // bg_0/dim_0 ramp, not part of the color/br_color hue set) — not
            // meant as text colors, so no minimum is enforced.
            ("#ebebeb", "black (background tint)", nil),
            ("#d6000c", "red", 4.5),
            ("#1d9700", "green", 3.0),
            // Real hue miss, not a background tint: upstream yellow is a
            // genuine ANSI text color (ls/git/syntax highlighting use it) but
            // measures ~2.70:1 against white — below even the 3:1 floor. Not
            // patched here per the maintainer decision to bundle Selenized
            // verbatim rather than re-tint individual colors; documented as a
            // known limitation instead of silently excused.
            ("#c49700", "yellow (documented contrast miss)", nil),
            ("#0064e4", "blue", 4.5),
            ("#dd0f9d", "magenta", 4.5),
            // Real hue miss, not a background tint: same as yellow above —
            // upstream cyan is a genuine text color, measures ~2.82:1.
            ("#00ad9c", "cyan (documented contrast miss)", nil),
            ("#878787", "white/dim", 3.0),
            ("#cdcdcd", "bright black (background tint)", nil),
            ("#bf0000", "bright red", 4.5),
            ("#008400", "bright green", 4.5),
            ("#af8500", "bright yellow", 3.0),
            ("#0054cf", "bright blue", 4.5),
            ("#c7008b", "bright magenta", 4.5),
            ("#009a8a", "bright cyan", 3.0),
            ("#282828", "bright white", 4.5),
        ]

        for slot in slots {
            if let minimum = slot.minimum {
                #expect(
                    contrastRatio(slot.hex, background) >= minimum,
                    "\(slot.role) (\(slot.hex)) must meet \(minimum):1"
                )
            }
        }

        #expect(contrastRatio("#474747", background) >= 7.0)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(trimmed, radix: 16) else { return 0 }
        let components = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        ].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }

    private func contrastRatio(_ a: String, _ b: String) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
