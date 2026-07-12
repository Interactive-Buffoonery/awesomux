import Foundation
import Testing
@testable import awesoMux

@Suite("GhosttySurfaceAccessibilityPolicy")
struct GhosttySurfaceAccessibilityPolicyTests {
    // MARK: - lineIndex(forCharacterIndex:in:)

    @Test("index on the first line is line 0")
    func firstLineIsZero() {
        let content = "first\nsecond\nthird"
        let index = content.distance(from: content.startIndex, to: content.index(content.startIndex, offsetBy: 2))

        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: index, in: content) == 0)
    }

    @Test("index past a newline advances the line count")
    func indexPastNewlineAdvances() {
        let content = "first\nsecond\nthird"
        // "first\n" is 6 characters; index 6 is the start of "second".
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 6, in: content) == 1)
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 13, in: content) == 2)
    }

    @Test("index of zero is always line 0")
    func zeroIndexIsLineZero() {
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 0, in: "a\nb\nc") == 0)
    }

    @Test("index beyond the content length clamps to the last line")
    func indexBeyondContentClampsToLastLine() {
        let content = "one\ntwo"
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 999, in: content) == 1)
    }

    @Test("negative index is clamped to zero instead of trapping")
    func negativeIndexIsClamped() {
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: -5, in: "a\nb") == 0)
    }

    @Test("empty content is always line 0")
    func emptyContentIsLineZero() {
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 0, in: "") == 0)
    }

    @Test("UTF-16 offset past an emoji-containing line resolves to the correct line")
    func utf16OffsetPastEmojiLineIsCorrect() {
        // "🙂" is a single Swift Character/grapheme but 2 UTF-16 code units
        // (surrogate pair). A grapheme-count-based implementation would
        // treat "🙂ok\n" as 3 characters and desync from VoiceOver's UTF-16
        // offsets by 1 for every line after it.
        let content = "🙂ok\nsecond\nthird"
        let firstLineUTF16Length = ("🙂ok\n" as NSString).length // 5: 2 (emoji) + 2 ("ok") + 1 ("\n")

        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: firstLineUTF16Length, in: content) == 1)
    }

    @Test("UTF-16 offset landing inside the emoji-containing first line stays on line 0")
    func utf16OffsetInsideEmojiLineStaysOnFirstLine() {
        let content = "🙂ok\nsecond"

        // Offset 1 lands between the emoji's two UTF-16 surrogate code
        // units — not a valid boundary. This must fail safe (no trap)
        // rather than crash while still resolving to a sane line number.
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 1, in: content) == 0)
        #expect(GhosttySurfaceAccessibilityPolicy.lineIndex(forCharacterIndex: 3, in: content) == 0)
    }

    // MARK: - substring(for:in:)

    @Test("in-bounds range returns the matching substring")
    func inBoundsRangeReturnsSubstring() {
        let content = "hello world"
        let range = NSRange(location: 6, length: 5)

        #expect(GhosttySurfaceAccessibilityPolicy.substring(for: range, in: content) == "world")
    }

    @Test("zero-length range returns an empty string")
    func zeroLengthRangeReturnsEmptyString() {
        let content = "hello"
        let range = NSRange(location: 0, length: 0)

        #expect(GhosttySurfaceAccessibilityPolicy.substring(for: range, in: content) == "")
    }

    @Test("out-of-bounds range returns nil")
    func outOfBoundsRangeReturnsNil() {
        let content = "hello"
        let range = NSRange(location: 10, length: 5)

        #expect(GhosttySurfaceAccessibilityPolicy.substring(for: range, in: content) == nil)
    }

    @Test("range overrunning content length returns nil rather than truncating")
    func rangeOverrunningLengthReturnsNil() {
        let content = "hello"
        let range = NSRange(location: 3, length: 10)

        #expect(GhosttySurfaceAccessibilityPolicy.substring(for: range, in: content) == nil)
    }
}
