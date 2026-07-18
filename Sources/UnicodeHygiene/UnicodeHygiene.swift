import Foundation

/// Single source of truth for sanitizing user- and agent-supplied display
/// strings — workspace titles, session-group names, and the config
/// `default_group`. `AwesoMuxCore` and `AwesoMuxConfig` both route through here
/// so the spoofing-scalar policy can't drift between the two (it used to live as
/// hand-mirrored copies in each module). See INT-92 / INT-93 / INT-434.
public enum UnicodeHygiene {

    // MARK: - Public API

    /// Sanitize a raw display string, in order:
    ///
    /// 1. **Bound the work.** A chatty or hostile OSC title can carry megabytes,
    ///    but we only ever keep `maxLength`. Capping raw scalars first keeps the
    ///    hot path `O(rawScalarCap)` instead of `O(input)` — the same beachball
    ///    class as INT-471, just in our Swift rather than libghostty.
    /// 2. **NFKC-fold** compatibility look-alikes so fullwidth `Ａ` and
    ///    math-bold `𝐚` collapse to canonical ASCII and can't masquerade as a
    ///    trusted name. NFKC does not fold cross-script homoglyphs like
    ///    Cyrillic `а` U+0430 — group-name call sites reject those separately
    ///    via `hasSuspiciousScriptMixing` on the *raw* input, never inside this
    ///    function: an empty return here means "drop it" to restore paths, and
    ///    a policy rejection must not destroy persisted sessions.
    /// 3. **Remap exotic spaces** (any space separator other than U+0020) to a
    ///    plain space, so word boundaries survive — `Field\u{00A0}Ops` becomes
    ///    `Field Ops`, not `FieldOps` — while neutralizing the confusable and
    ///    edge-padding aspects (leading/trailing runs trim away below).
    /// 4. **Strip** disallowed scalars (controls, bidi overrides/isolates,
    ///    zero-width, line/paragraph separators, default-ignorables). Pass
    ///    `stripInvisibleRoutingScalars: true` for group names and other
    ///    routing keys: they are compared, not rendered, so the invisible
    ///    scalars titles legitimately keep (ZWNJ/ZWJ joiners, LRM/RLM/ALM
    ///    directional hints) must not survive there.
    /// 5. **Trim** edges and **clip** to `maxLength`.
    /// 6. **Return `""`** when nothing visible survives, so downstream
    ///    `!isEmpty` guards refuse it.
    public static func sanitize(
        _ raw: String,
        maxLength: Int,
        stripInvisibleRoutingScalars: Bool = false
    ) -> String {
        let bounded = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(rawScalarCap)))
        let folded = bounded.precomposedStringWithCompatibilityMapping

        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if scalar.properties.generalCategory == .spaceSeparator, scalar.value != 0x20 {
                kept.append(" ")
            } else if stripInvisibleRoutingScalars, isRoutingKeyHazardScalar(scalar) {
                continue
            } else if !isDisallowedScalar(scalar) {
                kept.append(scalar)
            }
        }

        let trimmed = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(maxLength))
        return containsVisibleScalar(clipped) ? clipped : ""
    }

    /// `true` when a label mixes letters from more than one of the Latin,
    /// Cyrillic, and Greek script families — the confusable pairs behind the
    /// classic homograph spoof (`Сlаudе`, `Αа` for `Aa`).
    ///
    /// Call this with the *raw*, pre-NFKC input. NFKC folds innocent
    /// compatibility characters into Greek (µ U+00B5 → μ, Ω U+2126 → Ω), so
    /// checking the folded output would flag plain-English names like
    /// "µbench" or "Ω lab".
    ///
    /// This is intentionally not a general script-mixing detector or UTS-#39
    /// confusable-skeleton implementation. It covers the cheap local-terminal
    /// policy needed for common Latin-lookalike spoofs across Latin, Cyrillic,
    /// and Greek; a full TR39 engine can be added later if this narrow check is
    /// too weak in practice.
    public static func hasSuspiciousScriptMixing(_ string: String) -> Bool {
        var seenFamilies: Set<ScriptFamily> = []

        for scalar in string.unicodeScalars {
            switch scriptFamily(for: scalar) {
            case let family?:
                seenFamilies.insert(family)
            case nil:
                break
            }

            if seenFamilies.count > 1 {
                return true
            }
        }

        return false
    }

    /// `true` when the string has at least one *base* (ink-producing) scalar —
    /// a Letter, Number, Punctuation, or Symbol.
    ///
    /// Marks (combining/enclosing), separators, and control/format scalars do
    /// **not** count: on their own they render as a blank or dotted-circle (◌́)
    /// row and defeat the downstream `!isEmpty` guards. INT-434 first caught the
    /// format-only (Cf) case; the old `!= .format` gate let combining-mark-only
    /// and Hangul-filler strings through, so INT-92 widens "invisible" to the
    /// full set of non-graphic categories.
    ///
    /// U+2800 BRAILLE PATTERN BLANK is category `.otherSymbol`, but it is
    /// excluded because it renders blank in many fonts and can spoof an empty
    /// row.
    public static func containsVisibleScalar(_ string: String) -> Bool {
        string.unicodeScalars.contains(where: isVisibleScalar)
    }

    /// `true` for scalars removed entirely from display strings.
    public static func isDisallowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isRoutingKeyHazardScalar(scalar) {
            // ZWNJ/ZWJ joiners (Devanagari, Persian, emoji ZWJ sequences) and
            // LRM/RLM/ALM directional hints (INT-93) are legitimate in rendered
            // titles. Kept here; routing keys strip them via
            // `stripInvisibleRoutingScalars` instead.
            return false
        }

        if disallowedScalars.contains(scalar) {
            return true
        }

        switch scalar.properties.generalCategory {
        case .spaceSeparator:
            // `sanitize` remaps non-ASCII spaces to U+0020 before reaching
            // this check; a caller invoking the predicate directly still
            // treats them as disallowed.
            return scalar.value != 0x20
        case .lineSeparator, .paragraphSeparator:
            return true
        default:
            return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// `true` when `string` contains a codepoint that has no business in a
    /// filesystem path shown to a user: C0/C1 controls (NUL, DEL, etc.), bidi
    /// formatting/isolate overrides, zero-width joiners/spaces/BOM, and
    /// invisible math operators. Any of these can make a path render as
    /// something other than what it resolves to (RTL override, joiner-hidden
    /// traversal segments), so this is the one fence for path safety —
    /// callers route through here instead of each hand-rolling a slightly
    /// different "plausible path" check that could drift out of sync.
    public static func containsUnsafePathScalars(_ string: String) -> Bool {
        string.unicodeScalars.contains(where: isUnsafePathScalar)
    }

    // MARK: - Internals

    private static func isUnsafePathScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F, 0x0080...0x009F:
            return true // C0, DEL, C1 controls
        case 0x2028, 0x2029:
            return true // LINE SEPARATOR / PARAGRAPH SEPARATOR
        case 0x202A...0x202E:
            return true // Bidi formatting controls (LRE/RLE/PDF/LRO/RLO)
        case 0x2066...0x2069:
            return true // Bidi isolates (LRI/RLI/FSI/PDI)
        case 0x200E, 0x200F, 0x061C:
            return true // LRM / RLM / Arabic letter mark
        case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060:
            return true // Zero-width space / ZWNJ / ZWJ / BOM / word joiner
        case 0x2061...0x2064:
            return true // Invisible math operators
        default:
            return false
        }
    }

    /// Hard ceiling on raw scalars processed per call. Anything past this is
    /// junk we would clip away regardless; capping keeps the OSC-title hot path
    /// bounded no matter what a misbehaving PTY emits.
    static let rawScalarCap = 4096

    /// Invisible scalars that titles keep for correct rendering but that must
    /// not distinguish two routing keys: ZWNJ/ZWJ joiners and LRM/RLM/ALM
    /// directional hints.
    private static func isRoutingKeyHazardScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x200D, 0x200E, 0x200F, 0x061C:
            return true
        default:
            return false
        }
    }

    private enum ScriptFamily {
        case latin
        case cyrillic
        case greek
    }

    private static func isVisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value != 0x2800 else {
            return false
        }

        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private static func scriptFamily(for scalar: Unicode.Scalar) -> ScriptFamily? {
        guard isLetterScalar(scalar) else {
            return nil
        }

        // ponytail: this range table is maintained by report, not generated
        // from Unicode's Script=Latin property (no public Foundation/ICU
        // accessor exists — see URLClassifier.swift's file header for the
        // `swift -e` proof). Every Latin block found reachable through a
        // real IDN host so far is listed below; an as-yet-unlisted block
        // (there are dozens in total, most vanishingly obscure) would read
        // as single-script when paired with Cyrillic/Greek. Extend this
        // switch, don't redesign the algorithm, when the next one surfaces.
        switch scalar.value {
        case 0x0041 ... 0x005A,
             0x0061 ... 0x007A,
             0x00C0 ... 0x00FF,
             0x0100 ... 0x024F,
             // IPA Extensions and Latin Extended Additional: without these a
             // spoofer readmits the mixed-script class via e.g. Vietnamese
             // letters (U+1E01) beside Cyrillic.
             0x0250 ... 0x02AF,
             0x1E00 ... 0x1EFF,
             // Latin Extended-C/D/E/F/G: without these, a Latin-lookalike
             // letter from one of these blocks (e.g. U+A7CA LATIN CAPITAL
             // LETTER S WITH SHORT STROKE) returns nil from this switch —
             // contributing NO family — so pairing it with a real
             // Cyrillic/Greek letter reads as single-script and slips past
             // the mixing check. Confirmed reachable through a real IDN
             // host: Foundation accepts and punycode-encodes
             // "\u{A7CA}\u{0430}.com".
             0x2C60 ... 0x2C7F,
             0xA720 ... 0xA7FF,
             0xAB30 ... 0xAB6F,
             0x10780 ... 0x107BF,
             0x1DF00 ... 0x1DFFF:
            return .latin
        case 0x0370 ... 0x03FF,
             0x1F00 ... 0x1FFF:
            return .greek
        case 0x0400 ... 0x052F:
            return .cyrillic
        default:
            return nil
        }
    }

    private static func isLetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static let disallowedScalars: CharacterSet = {
        var set = CharacterSet.controlCharacters
        // Bidi overrides and isolates — spoofing primitives that reverse the
        // visual order of text to disguise it. Already Cf (and thus in
        // `controlCharacters`); listed explicitly for documentation.
        set.insert(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}")
        set.insert(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}")
        // Line/paragraph separators break single-line rendering.
        set.insert(charactersIn: "\u{2028}\u{2029}")
        // Zero-width / invisible characters with no legitimate use in a label.
        set.insert(charactersIn: "\u{200B}\u{FEFF}\u{2060}")
        return set
    }()
}
