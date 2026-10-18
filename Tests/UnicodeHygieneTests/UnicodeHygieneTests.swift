import Testing
@testable import UnicodeHygiene

@Suite
struct UnicodeHygieneTests {
    @Test(arguments: [
        (String(repeating: "a", count: 500), 80, String(repeating: "a", count: 80)),
        ("a\u{E0041}b", 80, "ab"),
        ("Field\u{00A0}Ops", 80, "Field Ops"),
        ("\u{200B}\u{FEFF}", 80, ""),
        ("\u{0421}l\u{0430}ud\u{0435}", 80, "\u{0421}l\u{0430}ud\u{0435}"),
    ])
    func sanitize(input: String, limit: Int, expected: String) {
        #expect(UnicodeHygiene.sanitize(input, maxLength: limit) == expected)
    }

    @Test
    func boundsPathologicalInput() {
        let prefix = String(repeating: "x", count: 100)
        let junk = String(repeating: "\u{200B}", count: UnicodeHygiene.rawScalarCap * 4)
        #expect(UnicodeHygiene.sanitize(prefix + junk, maxLength: 200) == prefix)
    }

    @Test(arguments: ["\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{061C}"])
    func routingScalarsAreRemovedOnlyOnRequest(hazard: String) {
        #expect(UnicodeHygiene.sanitize("scratch\(hazard)", maxLength: 80) == "scratch\(hazard)")
        #expect(UnicodeHygiene.sanitize("scratch\(hazard)", maxLength: 80, stripInvisibleRoutingScalars: true) == "scratch")
        #expect(
            UnicodeHygiene.sanitize("\u{200C}\u{200D}\u{200E}\u{200F}\u{061C}", maxLength: 80, stripInvisibleRoutingScalars: true) == "")
    }

    private static let scriptCases: [(String, Bool)] =
        [
            ("\u{0421}l\u{0430}ud\u{0435}", true), ("\u{0391}\u{0430}", true),
            ("\u{0430}\u{1E01}", true), ("\u{A7CA}\u{0430}", true),
            ("\u{10780}\u{0430}", true), ("\u{2C60}\u{0430}", true),
            ("\u{AB30}\u{0430}", true), ("\u{1DF00}\u{0430}", true),
            ("\u{1D00}\u{0430}", true), ("\u{1D80}\u{0430}", true),
            ("\u{1D400}\u{0430}", true), ("A\u{1D6A8}", true),
            ("\u{03B1}\u{1D6A8}", false), ("A\u{AB65}", true),
            ("\u{03B1}\u{AB65}", false), ("\u{FF21}\u{0430}", true),
            ("\u{FF41}\u{0430}", true), ("\u{214E}\u{0430}", true),
            ("\u{2184}\u{0430}", true), ("a\u{A641}", true),
            ("Claude", false), ("scratch", false), ("\u{00B5}bench", false),
            ("\u{2126} lab", false), ("\u{041A}\u{043B}\u{0430}\u{0443}\u{0434}\u{0435}", false),
        ]
        + [
            // Greek and Cyrillic letters embedded in the Phonetic Extensions blocks.
            "\u{1D26}", "\u{1D27}", "\u{1D28}", "\u{1D29}", "\u{1D2A}",
            "\u{1D5D}", "\u{1D5E}", "\u{1D5F}", "\u{1D60}", "\u{1D61}",
            "\u{1D66}", "\u{1D67}", "\u{1D68}", "\u{1D69}", "\u{1D6A}",
            "\u{1DBF}", "\u{1D2B}", "\u{1D78}",
        ].map { ("A" + $0, true) }
        + [
            // These visually Greek IPA letters are Script=Latin.
            "\u{1D45}", "\u{1D9B}", "\u{1DA5}", "\u{1DB2}", "\u{1DB7}",
        ].flatMap { [("A" + $0, false), ("\u{0430}" + $0, true)] }

    @Test(arguments: scriptCases)
    func suspiciousScriptMixing(input: String, expected: Bool) {
        #expect(UnicodeHygiene.hasSuspiciousScriptMixing(input) == expected)
    }

    private static let scalarCases: [(String, Bool?, Bool?)] =
        [
            ("a", true, nil), ("7", true, nil), ("!", true, nil), ("€", true, nil),
            ("\u{1F600}", true, nil), ("\u{0301}", false, nil), ("\u{20DD}", false, nil),
            ("\u{00A0}", false, nil), ("\u{200E}", false, nil), ("\u{2800}", false, nil),
            ("/Users/example/docs/notes.md", nil, false), ("docs/café-notes.md", nil, false),
            ("笔记/说明.md", nil, false),
        ]
        + [
            "\u{0000}", "\u{001F}", "\u{007F}", "\u{0080}", "\u{009F}",
            "\u{2028}", "\u{2029}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{061C}",
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}",
            "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}",
        ].map { ("a" + $0 + "b", nil, true) }

    @Test(arguments: scalarCases)
    func scalarAdmission(input: String, visible: Bool?, unsafe: Bool?) {
        if let visible { #expect(UnicodeHygiene.containsVisibleScalar(input) == visible) }
        if let unsafe { #expect(UnicodeHygiene.containsUnsafePathScalars(input) == unsafe) }
    }
}
