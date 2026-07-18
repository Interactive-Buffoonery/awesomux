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
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{0301}")) // combining acute
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{20DD}")) // enclosing circle
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{00A0}")) // NBSP
        #expect(!UnicodeHygiene.containsVisibleScalar("\u{200E}")) // LRM (format)
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
        for scalar in ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"] {
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
