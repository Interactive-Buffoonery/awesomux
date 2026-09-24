import Testing
@testable import AwesoMuxCore

@Suite("RichInputStaging")
struct RichInputStagingTests {

    @Test("an embedded bracketed-paste end marker cannot break out of the paste")
    func stripsBracketedPasteEndMarker() {
        // ESC[201~ would close libghostty's bracketed paste early and let the rest
        // run as commands; the ESC must be stripped so it lands as inert text.
        let payload = RichInputStaging.stagedPayload("safe\u{1B}[201~rm -rf ~")
        #expect(!payload.contains("\u{1B}"))
        #expect(payload == "safe[201~rm -rf ~")
    }

    @Test("terminal escape / control bytes are stripped, newlines survive")
    func stripsControlBytes() {
        let payload = RichInputStaging.stagedPayload("a\u{1B}b\u{07}c\u{00}d\ne")
        #expect(payload == "abcd\ne")
    }

    @Test("a payload of only control characters collapses to empty")
    func controlOnlyIsEmpty() {
        #expect(RichInputStaging.stagedPayload("\u{1B}\u{00}\u{07}").isEmpty)
    }

    @Test("bidi override/isolate formatting is stripped (terminal line-spoofing)")
    func stripsBidiOverrides() {
        // U+202E RIGHT-TO-LEFT OVERRIDE would visually reverse the rest of the line.
        #expect(RichInputStaging.stagedPayload("run\u{202E}elif.txt") == "runelif.txt")
        #expect(RichInputStaging.stagedPayload("a\u{2066}b\u{2069}c") == "abc")
    }
}
