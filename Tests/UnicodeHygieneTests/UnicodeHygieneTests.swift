import Testing
@testable import UnicodeHygiene

@Suite("UnicodeHygiene.sanitize")
struct UnicodeHygieneSanitizeTests {
    @Test("clips to maxLength")
    func clipsToMaxLength() {
        let long = String(repeating: "a", count: 500)
        #expect(UnicodeHygiene.sanitize(long, maxLength: 80).count == 80)
    }

    @Test("bounds work on pathologically long input")
    func boundsPathologicalInput() {
        // A hostile OSC title can carry far more than rawScalarCap. Sanitization
        // must stay bounded and still return a clipped, visible result rather
        // than choke. (INT-471 hot-path concern.)
        let visiblePrefix = String(repeating: "x", count: 100)
        let junk = String(repeating: "\u{200B}", count: UnicodeHygiene.rawScalarCap * 4)
        let result = UnicodeHygiene.sanitize(visiblePrefix + junk, maxLength: 200)
        #expect(result == visiblePrefix)
    }

    @Test("strips tag characters")
    func stripsTagCharacters() {
        // U+E0000–U+E007F (the TAG block, used for invisible steganography) are
        // default-ignorable, so they fall to the strip path.
        #expect(UnicodeHygiene.sanitize("a\u{E0041}b", maxLength: 80) == "ab")
    }

    @Test("remaps non-ASCII spaces, strips invisibles, keeps base text")
    func remapsAndStrips() {
        #expect(UnicodeHygiene.sanitize("Field\u{00A0}Ops", maxLength: 80) == "Field Ops")
        #expect(UnicodeHygiene.sanitize("\u{200B}\u{FEFF}", maxLength: 80) == "")
    }

    @Test("passes mixed-script names through unchanged")
    func passesMixedScriptNamesThrough() {
        // Policy rejection lives at the call sites, not here: an empty return
        // from sanitize means "drop it" on restore paths, and a mixed-script
        // name must be quarantined there, never destroyed.
        let homoglyph = "\u{0421}l\u{0430}ud\u{0435}"
        #expect(UnicodeHygiene.sanitize(homoglyph, maxLength: 80) == homoglyph)
    }

    @Test("strips invisible routing scalars only when requested")
    func stripsInvisibleRoutingScalarsOnlyWhenRequested() {
        for hazard in ["\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{061C}"] {
            #expect(UnicodeHygiene.sanitize("scratch\(hazard)", maxLength: 80) == "scratch\(hazard)")
            #expect(
                UnicodeHygiene.sanitize(
                    "scratch\(hazard)",
                    maxLength: 80,
                    stripInvisibleRoutingScalars: true
                ) == "scratch"
            )
        }
    }

    @Test("a routing-hazard-only string strips to empty")
    func routingHazardOnlyStringStripsToEmpty() {
        #expect(
            UnicodeHygiene.sanitize(
                "\u{200C}\u{200D}\u{200E}\u{200F}\u{061C}",
                maxLength: 80,
                stripInvisibleRoutingScalars: true
            ) == ""
        )
    }
}

@Suite("UnicodeHygiene.hasSuspiciousScriptMixing")
struct UnicodeHygieneScriptMixingTests {
    @Test("flags Latin mixed with Cyrillic lookalikes")
    func flagsLatinMixedWithCyrillicLookalikes() {
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{0421}l\u{0430}ud\u{0435}"))
    }

    @Test("flags Greek mixed with Cyrillic (no Latin present)")
    func flagsGreekMixedWithCyrillic() {
        // Greek Alpha + Cyrillic a renders like Latin "Aa" — any pair of the
        // protected script families is suspicious, not just pairs with Latin.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{0391}\u{0430}"))
    }

    @Test("flags extended-Latin ranges mixed with Cyrillic")
    func flagsExtendedLatinMixedWithCyrillic() {
        // Latin Extended Additional (Vietnamese) beside Cyrillic — the base
        // ASCII-only Latin table would miss this and readmit the spoof class.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{0430}\u{1E01}"))
    }

    @Test("flags Latin Extended-D mixed with Cyrillic")
    func flagsLatinExtendedDMixedWithCyrillic() {
        // U+A7CA LATIN CAPITAL LETTER S WITH SHORT STROKE beside Cyrillic а —
        // a real, IDN-registrable homograph pair (Foundation accepts and
        // punycode-encodes "\u{A7CA}\u{0430}.com" as a valid host). Without
        // Latin Extended-C/D/E in the table, the Extended-D letter falls
        // through to no family and the mix goes undetected.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{A7CA}\u{0430}"))
    }

    @Test("flags Latin Extended-F mixed with Cyrillic")
    func flagsLatinExtendedFMixedWithCyrillic() {
        // U+10780 (Latin Extended-F, supplementary plane) beside Cyrillic а
        // — Foundation accepts and punycode-encodes "\u{10780}\u{0430}.com"
        // as a valid host.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{10780}\u{0430}"))
    }

    @Test("flags remaining expanded Latin ranges mixed with Cyrillic")
    func flagsRemainingExpandedLatinRangesMixedWithCyrillic() {
        // U+2C60 (Extended-C), U+AB30 (Extended-E), and U+1DF00
        // (Extended-G) beside Cyrillic а — the same false-open class as the
        // Extended-D/F tests above, rounding out the rest of the table's
        // added ranges. Foundation accepts and punycode-encodes each of
        // "\u{2C60}\u{0430}.com", "\u{AB30}\u{0430}.com", and
        // "\u{1DF00}\u{0430}.com" as a valid host.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{2C60}\u{0430}"))
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{AB30}\u{0430}"))
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{1DF00}\u{0430}"))
    }

    @Test("flags Phonetic Extensions ranges mixed with Cyrillic")
    func flagsPhoneticExtensionsMixedWithCyrillic() {
        // U+1D00 LATIN LETTER SMALL CAPITAL A (Phonetic Extensions) and
        // U+1D80 LATIN SMALL LETTER B WITH PALATAL HOOK (Phonetic
        // Extensions Supplement) beside Cyrillic а — a real, IDN-reachable
        // homograph pair (Greptile flagged this gap: Foundation accepts and
        // punycode-encodes "\u{1D00}\u{0430}.com" as a valid host). Without
        // these two blocks in the table, either letter falls through to no
        // family and the mix goes undetected.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{1D00}\u{0430}"))
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{1D80}\u{0430}"))
    }

    @Test("does not misclassify Greek/Cyrillic letters embedded in the Phonetic Extensions blocks as Latin")
    func phoneticExtensionsGreekCyrillicLettersStayTheirOwnFamily() {
        // A first pass at closing the Phonetic Extensions gap listed the
        // WHOLE block as Latin — but both Phonetic Extensions blocks embed
        // real Greek/Cyrillic-lookalike letters for IPA-style phonetic
        // notation. Multi-reviewer + cross-model review caught this before
        // merge (confirmed live against a compiled build, not just by
        // codepoint name): each of these, paired with a plain Latin "A",
        // must flag as suspicious on its own — if any of these silently
        // read as `.latin` again, this is the exact regression that shipped
        // once already in this same PR. Deliberately excludes 1D45/1D9B/
        // 1DA5/1DB2/1DB7 — a SECOND review round found those 5 are actually
        // Script=Latin IPA letters (they NFKC-decompose to U+0251/0252/
        // 0269/0278/028A, all "LATIN SMALL LETTER..."), not Greek, despite
        // visually-Greek-derived names; see `phoneticExtensionsIPALatinLettersStayLatin`.
        let greekLookalikes: [Unicode.Scalar] = [
            "\u{1D26}", "\u{1D27}", "\u{1D28}", "\u{1D29}", "\u{1D2A}",  // small-capital gamma/lamda/pi/rho/psi
            "\u{1D5D}", "\u{1D5E}", "\u{1D5F}", "\u{1D60}", "\u{1D61}",  // modifier beta/gamma/delta/phi/chi
            "\u{1D66}", "\u{1D67}", "\u{1D68}", "\u{1D69}", "\u{1D6A}",  // subscript beta/gamma/rho/phi/chi
            "\u{1DBF}",  // modifier small theta
        ]
        for scalar in greekLookalikes {
            #expect(
                UnicodeHygiene.hasSuspiciousScriptMixing("A\(Character(scalar))"),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) must not read as Latin")
        }
        let cyrillicLookalikes: [Unicode.Scalar] = [
            "\u{1D2B}",  // small-capital el
            "\u{1D78}",  // modifier Cyrillic en
        ]
        for scalar in cyrillicLookalikes {
            #expect(
                UnicodeHygiene.hasSuspiciousScriptMixing("A\(Character(scalar))"),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) must not read as Latin")
        }
    }

    @Test("does not misclassify Phonetic Extensions IPA letters that are actually Script=Latin as Greek")
    func phoneticExtensionsIPALatinLettersStayLatin() {
        // A first CORRECTED pass folded these into .greek based on their
        // visually-Greek-derived names ("MODIFIER LETTER SMALL ALPHA" etc.)
        // — cross-model review caught that this was itself wrong: each
        // NFKC-decomposes to a Script=Latin IPA letter (U+0251 LATIN SMALL
        // LETTER ALPHA, U+0252 ...TURNED ALPHA, U+0269 ...IOTA, U+0278
        // ...PHI, U+028A ...UPSILON), so classifying them as Greek would
        // have created NEW false positives for legitimate Latin/IPA names.
        // This table has now been wrong in both directions on this exact
        // block — this test locks in the verified-correct answer.
        let ipaLatinLetters: [Unicode.Scalar] = [
            "\u{1D45}",  // modifier small alpha -> NFKC U+0251
            "\u{1D9B}",  // modifier small turned alpha -> NFKC U+0252
            "\u{1DA5}",  // modifier small iota -> NFKC U+0269
            "\u{1DB2}",  // modifier small phi -> NFKC U+0278
            "\u{1DB7}",  // modifier small upsilon -> NFKC U+028A
        ]
        for scalar in ipaLatinLetters {
            #expect(
                !UnicodeHygiene.hasSuspiciousScriptMixing("A\(Character(scalar))"),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) is Script=Latin and must not flag beside plain Latin")
            #expect(
                UnicodeHygiene.hasSuspiciousScriptMixing("\u{0430}\(Character(scalar))"),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) must still flag beside genuine Cyrillic")
        }
    }

    @Test("flags Mathematical Alphanumeric Symbols mixed with Cyrillic")
    func flagsMathematicalAlphanumericSymbolsMixedWithCyrillic() {
        // U+1D400 MATHEMATICAL BOLD CAPITAL A beside Cyrillic а — NFKC folds
        // U+1D400 to plain ASCII "A" (Unicode's own admission it's
        // Latin-compatible), and this is the textbook "bold text" homograph
        // vector cited in phishing literature — a much higher-reach block
        // than the historic-linguistics ranges already in this table.
        // Foundation accepts and punycode-encodes "\u{1D400}\u{0430}.com".
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{1D400}\u{0430}"))
    }

    @Test("does not misclassify the Greek portion of Mathematical Alphanumeric Symbols as Latin")
    func mathematicalAlphanumericGreekPortionStaysGreek() {
        // The block interleaves Latin and Greek mathematical letter
        // variants (bold, italic, script, fraktur, etc. of BOTH alphabets)
        // — U+1D6A8 MATHEMATICAL BOLD CAPITAL ALPHA is the first of 282
        // Greek-alphabet codepoints inside U+1D400...0x1D7FF. Pairing it
        // with plain Latin "A" must flag (Latin+Greek); pairing it with a
        // genuine Greek letter must NOT flag (both read as the same
        // .greek family — this is the check that would have failed if
        // this codepoint were wrongly left in .latin instead).
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("A\u{1D6A8}"))
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("\u{03B1}\u{1D6A8}"))
    }

    @Test("does not misclassify U+AB65 (embedded in Latin Extended-E) as Latin")
    func latinExtendedEEmbeddedGreekLetterStaysGreek() {
        // U+AB65 GREEK LETTER SMALL CAPITAL OMEGA sits inside the Latin
        // Extended-E block (U+AB30...AB6F) already in this table from an
        // earlier PR — a pre-existing gap of the identical bug class,
        // fixed here since it was cheap to close while already in this
        // exact code.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("A\u{AB65}"))
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("\u{03B1}\u{AB65}"))
    }

    @Test("flags Fullwidth Latin mixed with Cyrillic")
    func flagsFullwidthLatinMixedWithCyrillic() {
        // U+FF21 FULLWIDTH LATIN CAPITAL LETTER A beside Cyrillic а — same
        // NFKC-folds-to-ASCII signal, a documented real-world phishing
        // pattern (fullwidth characters render distinctly but decompose to
        // plain ASCII).
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{FF21}\u{0430}"))
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{FF41}\u{0430}"))
    }

    @Test("flags remaining Foundation-reachable Latin letters mixed with Cyrillic")
    func flagsRemainingLatinLookalikesMixedWithCyrillic() {
        // U+214E TURNED SMALL F (Letterlike Symbols) and U+2184 LATIN SMALL
        // LETTER REVERSED C (Number Forms) — both Foundation-reachable
        // Latin letters outside every range block above.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{214E}\u{0430}"))
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("\u{2184}\u{0430}"))
    }

    @Test("flags Latin mixed with Cyrillic Extended-B")
    func flagsLatinMixedWithCyrillicExtendedB() {
        // U+A641 CYRILLIC SMALL LETTER ROUND OMEGA (Extended-B) beside Latin
        // "a" — Foundation accepts and punycode-encodes "a\u{A641}.com" as a
        // valid host. Same false-open class as the Latin Extended gaps,
        // mirrored on the Cyrillic side of the table.
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing("a\u{A641}"))
    }

    @Test("allows pure Latin names")
    func allowsPureLatinNames() {
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("Claude"))
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("scratch"))
    }

    @Test("allows compatibility characters NFKC would fold into Greek")
    func allowsCompatibilityGreekFolds() {
        // µ (U+00B5) folds to Greek mu and Ω (U+2126) to Greek omega under
        // NFKC. The check runs on raw pre-NFKC input precisely so these
        // plain-English names stay accepted.
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("\u{00B5}bench"))
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("\u{2126} lab"))
    }

    @Test("allows names entirely in one non-Latin script")
    func allowsPureNonLatinNames() {
        #expect(!UnicodeHygiene.hasSuspiciousScriptMixing("\u{041A}\u{043B}\u{0430}\u{0443}\u{0434}\u{0435}"))
    }
}

@Suite("UnicodeHygiene.containsVisibleScalar")
struct UnicodeHygieneVisibilityTests {
    @Test("letters, numbers, punctuation, symbols are visible")
    func graphicScalarsAreVisible() {
        #expect(UnicodeHygiene.containsVisibleScalar("a"))
        #expect(UnicodeHygiene.containsVisibleScalar("7"))
        #expect(UnicodeHygiene.containsVisibleScalar("!"))
        #expect(UnicodeHygiene.containsVisibleScalar("€"))
        #expect(UnicodeHygiene.containsVisibleScalar("😀"))
    }

    @Test("marks, separators, and format scalars are not visible")
    func nonGraphicScalarsAreNotVisible() {
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{0301}"))  // combining acute
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{20DD}"))  // enclosing circle
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{00A0}"))  // NBSP
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{200E}"))  // LRM (format)
    }

    @Test("U+2800 Braille blank does not count as visible")
    func brailleBlankIsNotConsideredVisible() {
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{2800}"))
    }
}

@Suite("UnicodeHygiene.containsUnsafePathScalars")
struct UnicodeHygieneUnsafePathScalarsTests {
    @Test("rejects C0 and DEL controls")
    func rejectsC0AndDelControls() {
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{0000}b"))
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{001F}b"))
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{007F}b"))
    }

    @Test("rejects C1 controls")
    func rejectsC1Controls() {
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{0080}b"))
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{009F}b"))
    }

    @Test("rejects line and paragraph separators")
    func rejectsLineAndParagraphSeparators() {
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{2028}b"))
        #expect(UnicodeHygiene.containsUnsafePathScalars("a\u{2029}b"))
    }

    @Test("rejects bidi overrides and isolates")
    func rejectsBidiOverridesAndIsolates() {
        for scalar in [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        ] {
            #expect(UnicodeHygiene.containsUnsafePathScalars("a\(scalar)b"))
        }
    }

    @Test("rejects directional marks")
    func rejectsDirectionalMarks() {
        for scalar in ["\u{200E}", "\u{200F}", "\u{061C}"] {
            #expect(UnicodeHygiene.containsUnsafePathScalars("a\(scalar)b"))
        }
    }

    @Test("rejects zero-width joiners, spaces, and BOM")
    func rejectsZeroWidthAndBOM() {
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] {
            #expect(UnicodeHygiene.containsUnsafePathScalars("a\(scalar)b"))
        }
    }

    @Test("rejects invisible math operators")
    func rejectsInvisibleMathOperators() {
        for scalar in ["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}"] {
            #expect(UnicodeHygiene.containsUnsafePathScalars("a\(scalar)b"))
        }
    }

    @Test("accepts normal ASCII paths")
    func acceptsNormalASCIIPaths() {
        #expect(!UnicodeHygiene.containsUnsafePathScalars("/Users/example/docs/notes.md"))
    }

    @Test("accepts unicode letters in paths and titles")
    func acceptsUnicodeLettersInPathsAndTitles() {
        #expect(!UnicodeHygiene.containsUnsafePathScalars("docs/café-notes.md"))
        #expect(!UnicodeHygiene.containsUnsafePathScalars("笔记/说明.md"))
    }
}
