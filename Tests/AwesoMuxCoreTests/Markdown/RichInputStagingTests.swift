import Testing
@testable import AwesoMuxCore

@Suite("RichInputStaging")
struct RichInputStagingTests {
    // MARK: - stagedPayload

    @Test("multi-line text keeps its newlines and tabs")
    func preservesNewlinesAndTabs() {
        let payload = RichInputStaging.stagedPayload("line one\n\tindented\nline three")
        #expect(payload == "line one\n\tindented\nline three")
    }

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

    @Test("CRLF and lone CR normalize to LF")
    func normalizesCarriageReturns() {
        #expect(RichInputStaging.stagedPayload("a\r\nb") == "a\nb")
        #expect(RichInputStaging.stagedPayload("a\rb") == "a\nb")
    }

    @Test("trailing newlines are trimmed so staging leaves no stray blank line")
    func trimsTrailingNewlines() {
        #expect(RichInputStaging.stagedPayload("prompt\n\n") == "prompt")
        #expect(RichInputStaging.stagedPayload("prompt\r\n") == "prompt")
    }

    @Test("a payload of only control characters collapses to empty")
    func controlOnlyIsEmpty() {
        #expect(RichInputStaging.stagedPayload("\u{1B}\u{00}\u{07}").isEmpty)
    }

    @Test("ZWJ emoji sequences survive (format chars other than bidi overrides are kept)")
    func preservesZWJEmoji() {
        let developer = "\u{1F9D1}\u{200D}\u{1F4BB}"  // 🧑‍💻
        #expect(RichInputStaging.stagedPayload("hi \(developer)") == "hi \(developer)")
    }

    @Test("bidi override/isolate formatting is stripped (terminal line-spoofing)")
    func stripsBidiOverrides() {
        // U+202E RIGHT-TO-LEFT OVERRIDE would visually reverse the rest of the line.
        #expect(RichInputStaging.stagedPayload("run\u{202E}elif.txt") == "runelif.txt")
        #expect(RichInputStaging.stagedPayload("a\u{2066}b\u{2069}c") == "abc")
    }

    // MARK: - returnKeyOutcome

    @Test("plain Return sends")
    func plainReturnSends() {
        #expect(RichInputStaging.returnKeyOutcome(shift: false, option: false) == .send)
    }

    @Test("Shift- or Option-Return inserts a newline")
    func modifiedReturnInsertsNewline() {
        #expect(RichInputStaging.returnKeyOutcome(shift: true, option: false) == .insertNewline)
        #expect(RichInputStaging.returnKeyOutcome(shift: false, option: true) == .insertNewline)
        #expect(RichInputStaging.returnKeyOutcome(shift: true, option: true) == .insertNewline)
    }
}
