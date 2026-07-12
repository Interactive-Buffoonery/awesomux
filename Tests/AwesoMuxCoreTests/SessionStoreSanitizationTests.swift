import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore.sanitizedGroupName")
struct SessionStoreSanitizationTests {
    @Test("empty input round-trips to empty")
    func empty() {
        #expect(SessionStore.sanitizedGroupName("") == "")
    }

    @Test("whitespace-only collapses to empty")
    func whitespaceOnly() {
        #expect(SessionStore.sanitizedGroupName("   \n\t  ") == "")
    }

    @Test("preserves interior whitespace")
    func interiorWhitespace() {
        #expect(SessionStore.sanitizedGroupName("staging team") == "staging team")
        #expect(SessionStore.sanitizedTitle("shell active") == "shell active")
    }

    @Test("trims leading and trailing whitespace")
    func trimsEdges() {
        #expect(SessionStore.sanitizedGroupName("  hello  ") == "hello")
    }

    @Test("clips at maxGroupNameLength")
    func clipsLength() {
        let long = String(repeating: "a", count: 200)
        #expect(SessionStore.sanitizedGroupName(long).count == SessionStore.maxGroupNameLength)
    }

    @Test("strips control characters")
    func stripsControlChars() {
        #expect(SessionStore.sanitizedGroupName("foo\u{0007}bar") == "foobar")
    }

    @Test("strips bidi override scalars")
    func stripsBidiOverrides() {
        // U+202E (RIGHT-TO-LEFT OVERRIDE) is a known spoofing primitive.
        #expect(SessionStore.sanitizedGroupName("foo\u{202E}bar") == "foobar")
        // Same guarantee on the title path — VoiceOver announcements
        // (TerminalAccessibilityAnnouncer) rely on this ingress strip.
        #expect(SessionStore.sanitizedTitle("foo\u{202E}bar") == "foobar")
    }

    @Test("strips bidi isolate scalars")
    func stripsBidiIsolates() {
        // U+2066 (LRI), U+2067 (RLI), U+2068 (FSI), U+2069 (PDI) —
        // isolates can be paired with override sequences for the same
        // visual-reorder spoof as RLO/LRO. INT-93 keeps these stripped.
        #expect(SessionStore.sanitizedGroupName("foo\u{2066}bar") == "foobar")
        #expect(SessionStore.sanitizedGroupName("foo\u{2067}bar") == "foobar")
        #expect(SessionStore.sanitizedGroupName("foo\u{2068}bar") == "foobar")
        #expect(SessionStore.sanitizedGroupName("foo\u{2069}bar") == "foobar")
    }

    @Test("remaps interior non-ASCII space separators to a plain space")
    func remapsNonASCIISpaceSeparators() {
        // Interior exotic spaces are mapped to U+0020 (not deleted) so word
        // boundaries survive — `shell active` instead of `shellactive` — while
        // the confusable/padding aspect is neutralized. Leading/trailing runs
        // still trim away (see `trimsNonASCIISpaceEdges`).
        let spaces = [
            "\u{00A0}",
            "\u{1680}",
            "\u{2000}",
            "\u{2001}",
            "\u{2002}",
            "\u{2003}",
            "\u{2004}",
            "\u{2005}",
            "\u{2006}",
            "\u{2007}",
            "\u{2008}",
            "\u{2009}",
            "\u{200A}",
            "\u{202F}",
            "\u{205F}",
            "\u{3000}"
        ]

        for space in spaces {
            #expect(SessionStore.sanitizedTitle("shell\(space)active") == "shell active")
            #expect(SessionStore.sanitizedGroupName("field\(space)ops") == "field ops")
        }
    }

    @Test("trims edge non-ASCII space separators")
    func trimsNonASCIISpaceEdges() {
        // NBSP padding used to align/spoof must not survive at the edges.
        #expect(SessionStore.sanitizedTitle("\u{00A0}\u{00A0}shell\u{00A0}") == "shell")
        #expect(SessionStore.sanitizedGroupName("\u{3000}ops\u{3000}") == "ops")
    }

    @Test("strips Hangul filler scalars")
    func stripsHangulFillers() {
        let dirty = "alpha\u{115F}\u{1160}\u{3164}\u{FFA0}beta"

        #expect(SessionStore.sanitizedTitle(dirty) == "alphabeta")
        #expect(SessionStore.sanitizedGroupName(dirty) == "alphabeta")
    }

    @Test("strips variation selectors")
    func stripsVariationSelectors() {
        let dirty = "icon\u{FE00}\u{FE0F}\u{E0100}label"

        #expect(SessionStore.sanitizedTitle(dirty) == "iconlabel")
        #expect(SessionStore.sanitizedGroupName(dirty) == "iconlabel")
    }

    @Test("rejects strings consisting only of Cf format scalars (INT-434)")
    func rejectsOnlyFormatScalars() {
        // Pure directional hints — no visible glyph, must collapse to
        // empty so existing `!isEmpty` guards downstream refuse them.
        #expect(SessionStore.sanitizedTitle("\u{200E}") == "")
        #expect(SessionStore.sanitizedTitle("\u{200F}") == "")
        #expect(SessionStore.sanitizedTitle("\u{061C}") == "")
        // Mixed hint-only sequence
        #expect(SessionStore.sanitizedTitle("\u{200E}\u{200F}\u{061C}") == "")
        // Standalone joiners are invisible too — same trap, same fix.
        #expect(SessionStore.sanitizedTitle("\u{200C}") == "")
        #expect(SessionStore.sanitizedTitle("\u{200D}") == "")
        // Same expectation on the group sanitizer.
        #expect(SessionStore.sanitizedGroupName("\u{200E}") == "")
        #expect(SessionStore.sanitizedGroupName("\u{200C}\u{200D}") == "")

        let int92InvisibleScalars = "\u{115F}\u{FE0F}\u{E0100}"
        #expect(SessionStore.sanitizedTitle(int92InvisibleScalars) == "")
        #expect(SessionStore.sanitizedGroupName(int92InvisibleScalars) == "")
    }

    @Test("preserves emoji ZWJ sequences (regression coverage for INT-434)")
    func preservesEmojiZWJSequences() {
        // 👩‍💻 = U+1F469 + ZWJ + U+1F4BB. The ZWJ is Cf but the two
        // emoji scalars on either side are category So (Symbol-Other),
        // so the new visible-scalar gate must let the sequence through.
        #expect(SessionStore.sanitizedTitle("👩‍💻") == "👩‍💻")
        // Family ZWJ sequence: man + ZWJ + woman + ZWJ + girl
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(SessionStore.sanitizedTitle(family) == family)
    }

    @Test("preserves bidi directional hints for RTL users (INT-93)")
    func preservesBidiHints() {
        // U+200E (LRM), U+200F (RLM), U+061C (ALM) are directional
        // *hints*, not overrides (INT-93). RTL users insert them to keep
        // mixed-direction titles rendering correctly, so titles keep them.
        // Group names are routing keys compared for dedup, where the same
        // invisible hints would let visually identical names coexist, so
        // the group sanitizer strips them (INT-381 follow-up).
        let lrm = "src/main.rs\u{200E}(latin)"
        let rlm = "src/main.rs\u{200F}(عربي)"
        let alm = "src/main.rs\u{061C}(عربي)"
        #expect(SessionStore.sanitizedTitle(lrm) == lrm)
        #expect(SessionStore.sanitizedTitle(rlm) == rlm)
        #expect(SessionStore.sanitizedTitle(alm) == alm)
        #expect(SessionStore.sanitizedGroupName(lrm) == "src/main.rs(latin)")
        #expect(SessionStore.sanitizedGroupName(rlm) == "src/main.rs(عربي)")
        #expect(SessionStore.sanitizedGroupName(alm) == "src/main.rs(عربي)")
    }

    @Test("rejects combining-mark-only strings (no visible base)")
    func rejectsCombiningMarkOnly() {
        // Combining marks (Mn/Me) are NOT default-ignorable, so they survive
        // stripping — but alone they render as a blank or dotted-circle row.
        // The old `!= .format` gate let them through (Mn ≠ Cf); the visible-base
        // gate must reject them.
        #expect(SessionStore.sanitizedTitle("\u{0301}\u{0301}\u{0301}") == "")
        #expect(SessionStore.sanitizedGroupName("\u{20DD}") == "") // enclosing circle
        // A combining mark on a real base still survives, attached to its base.
        let accented = "e\u{0301}"
        #expect(SessionStore.sanitizedTitle(accented) == accented)
    }

    @Test("NFKC-folds compatibility look-alikes to canonical form")
    func foldsCompatibilityLookAlikes() {
        // Fullwidth Latin and mathematical-bold Latin are the cheap homoglyph
        // spoof against a trusted ASCII name. NFKC collapses them to ASCII.
        #expect(SessionStore.sanitizedTitle("\u{FF41}\u{FF42}\u{FF43}") == "abc") // ａｂｃ
        #expect(SessionStore.sanitizedGroupName("\u{1D41A}\u{1D41B}\u{1D41C}") == "abc") // 𝐚𝐛𝐜
    }

    @Test("is idempotent")
    func idempotent() {
        let dirty = "  weird\u{0007}name  "
        let once = SessionStore.sanitizedGroupName(dirty)
        let twice = SessionStore.sanitizedGroupName(once)
        #expect(once == twice)
    }
}
