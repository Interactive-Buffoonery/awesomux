import Testing
@testable import AwesoMuxCore

@Suite("FuzzyMatcher")
struct FuzzyMatchTests {

    @Test("Empty query returns nil")
    func emptyQueryReturnsNil() {
        #expect(FuzzyMatcher.match(query: "", in: "anything") == nil)
    }

    @Test("Single missing character returns nil")
    func missingCharReturnsNil() {
        #expect(FuzzyMatcher.match(query: "xyz", in: "Claude Code") == nil)
    }

    @Test("Initials match word boundaries — cc in Claude Code")
    func initialsMatch() throws {
        let result = try #require(FuzzyMatcher.match(query: "cc", in: "Claude Code"))
        #expect(result.ranges.count == 2)
        let matched = result.ranges.map { "Claude Code"[$0] }
        #expect(matched == ["C", "C"])
    }

    @Test("Path-segment prefix matches — obs in ~/Obsidian/ProjectNotes")
    func pathSegmentPrefix() throws {
        let haystack = "~/Obsidian/ProjectNotes"
        let result = try #require(FuzzyMatcher.match(query: "obs", in: haystack))
        let matched = result.ranges.map { haystack[$0] }
        #expect(matched == ["O", "b", "s"])
    }

    @Test("Case-insensitive")
    func caseInsensitive() throws {
        let result = try #require(FuzzyMatcher.match(query: "CLAUDE", in: "claude code"))
        #expect(result.ranges.count == 6)
    }

    @Test("Diacritic-insensitive — cafe matches Café")
    func diacriticInsensitive() throws {
        let haystack = "Café Project"
        let result = try #require(FuzzyMatcher.match(query: "cafe", in: haystack))
        let matched = result.ranges.map { String(haystack[$0]) }
        #expect(matched == ["C", "a", "f", "é"])
    }

    @Test("Ranges anchor to the ORIGINAL haystack — slicing works")
    func rangesAnchorToOriginal() throws {
        let haystack = "Café"
        let result = try #require(FuzzyMatcher.match(query: "ce", in: haystack))
        for range in result.ranges {
            _ = haystack[range]  // must not crash; ranges are valid for haystack
        }
        let combined = result.ranges.map { String(haystack[$0]) }.joined()
        #expect(combined == "Cé")
    }

    @Test("Word-boundary match outscores mid-word at same char count")
    func wordBoundaryOutscoresMidWord() throws {
        let boundary = try #require(FuzzyMatcher.match(query: "p", in: "Foo Project"))
        let midword = try #require(FuzzyMatcher.match(query: "p", in: "Floppy"))
        #expect(boundary.score > midword.score)
    }

    @Test("Contiguous run scores higher than scattered mid-word match")
    func contiguousScoresHigher() throws {
        // Scattered must avoid word separators (`-` `_` ` ` etc.) or each
        // post-separator match would itself earn the word-boundary bonus and
        // dominate the contiguous case. This is intended scoring behavior —
        // multiple word-start matches DO beat a single contiguous run.
        let contiguous = try #require(FuzzyMatcher.match(query: "obs", in: "Obsidian"))
        let scattered = try #require(FuzzyMatcher.match(query: "obs", in: "OxxbxxxsXX"))
        #expect(contiguous.score > scattered.score)
    }

    @Test("Camel-boundary counts as word boundary")
    func camelBoundary() throws {
        let result = try #require(FuzzyMatcher.match(query: "fb", in: "fooBar"))
        // 'f' at start (boundary) + 'B' at camel boundary
        let plain = try #require(FuzzyMatcher.match(query: "fb", in: "fbloomb"))
        #expect(result.score > plain.score)
    }

    @Test("Sequential subsequence is required — order matters")
    func ordered() {
        #expect(FuzzyMatcher.match(query: "ba", in: "abc") == nil)
    }

    @Test("Empty haystack returns nil")
    func emptyHaystack() {
        #expect(FuzzyMatcher.match(query: "a", in: "") == nil)
    }

    @Test("Query longer than haystack returns nil")
    func queryLongerThanHaystack() {
        #expect(FuzzyMatcher.match(query: "abcdef", in: "ab") == nil)
    }

    @Test("Query length is capped — pathological input returns nil")
    func queryLengthCap() {
        let huge = String(repeating: "a", count: FuzzyMatcher.maxQueryLength + 1)
        #expect(FuzzyMatcher.match(query: huge, in: "anything") == nil)
    }

    @Test("Whitespace in query matches whitespace in haystack")
    func whitespaceInQuery() throws {
        // 'o', ' ', 'd' → matches the o in Foo, the space, then d in dog.
        let result = try #require(FuzzyMatcher.match(query: "o d", in: "Foo dog"))
        #expect(result.ranges.count == 3)
    }

    @Test("Long gap still matches but cannot outrank a word-boundary anchored match")
    func longGapClampedSoBoundaryWins() throws {
        // Pathological: "a" + 50 garbage + "b" — gap penalty must NOT drive
        // score so negative that this beats a cleaner word-boundary match.
        let scattered = try #require(
            FuzzyMatcher.match(
                query: "ab",
                in: "a" + String(repeating: "x", count: 50) + "b"
            )
        )
        let boundary = try #require(FuzzyMatcher.match(query: "ab", in: "a b"))
        #expect(boundary.score > scattered.score)
    }

    @Test("Symmetric folding — ß in haystack matches s in query (per-char fold)")
    func multiCharExpansionSymmetric() throws {
        // ß folds to 's' on both sides (per-char fold is symmetric); a
        // single-s query should locate the ß in the haystack as the matched
        // character. Pre-fix this returned nil because the query was
        // whole-string-folded to "ss" while the haystack was per-char-folded
        // to "s", silently desynchronizing the two sides.
        let result = try #require(FuzzyMatcher.match(query: "s", in: "ß"))
        #expect(result.ranges.count == 1)
    }

    @Test("Multi-start: best alignment wins over earlier weaker greedy match")
    func multiStartFindsBetterLaterAlignment() throws {
        // Pre-fix the matcher locked onto the bare leading `c`, then forced
        // `o` and `d` into the gap (low score, highlights wrong characters).
        // Post-fix it tries every viable start and keeps the highest score —
        // the contiguous word-boundary `Cod` in `Code` should win.
        let haystack = "cxxxxxxxxx Code"
        let result = try #require(FuzzyMatcher.match(query: "cod", in: haystack))
        let matched = result.ranges.map { String(haystack[$0]) }.joined()
        #expect(matched == "Cod", "Highlighted chars should be the C-o-d of Code, not the leading c")
    }
}
