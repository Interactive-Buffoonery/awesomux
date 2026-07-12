import Foundation

public struct FuzzyMatchResult: Equatable, Sendable {
    public let score: Int
    /// Ranges anchored to the **original** haystack string passed to `match`.
    /// Safe to slice the original directly — no folded-index trap.
    public let ranges: [Range<String.Index>]

    public init(score: Int, ranges: [Range<String.Index>]) {
        self.score = score
        self.ranges = ranges
    }
}

public enum FuzzyMatcher {
    /// Returns a match if every character of `query` appears in `haystack` in
    /// order. Comparison is diacritic-insensitive and case-insensitive.
    /// Returns nil for an empty query — callers are responsible for the
    /// no-filter short-circuit.
    ///
    /// Scoring invariants (locked by FuzzyMatchTests):
    /// - Each matched character contributes `+1` base.
    /// - Matches at a word boundary contribute `+8` (after `/_ ~.-\`, at the
    ///   start of the haystack, or at a lowercase→uppercase camel transition).
    /// - Contiguous runs add `+2 × runLength` per *chained* character; the
    ///   first char of a contiguous segment never earns the chain bonus by
    ///   design (the boundary/base bonus already rewards the run anchor).
    /// - Non-contiguous matches subtract the gap to the prior match, clamped
    ///   at `maxGapPenalty` so a distant match can't drive scores so negative
    ///   that a weaker but boundary-anchored match in a different field would
    ///   spuriously win field-precedence.
    /// - Any unmatched query character causes the matcher to return nil.
    /// - Query length is capped to keep accidental paste-bombs harmless.
    public static let maxQueryLength = 1024
    public static let maxGapPenalty = 6

    public static func match(query: String, in haystack: String) -> FuzzyMatchResult? {
        guard !query.isEmpty, query.count <= Self.maxQueryLength else { return nil }

        // Fold the query the SAME way each haystack character is folded so
        // ß-style multi-char expansions can't desynchronize the two sides
        // and silently miss. The per-char fold is symmetric and lossy in the
        // same direction on both ends.
        let foldedQuery = Array(query).map { Self.fold($0) }
        guard !foldedQuery.isEmpty else { return nil }

        // Multi-start search: a single greedy pass would commit to the first
        // haystack character that folds to query[0], even when a later
        // start would yield a much higher score (e.g. `cod` in
        // `cxxxxxxxxx Code` — greedy locks onto the bare `c` and misses the
        // contiguous word-boundary `Cod` run). Try every viable starting
        // anchor and keep the best result. O(n²) worst case; sidebar
        // haystacks are short (titles, abbreviated paths) so this is well
        // within budget on every keystroke.
        var best: FuzzyMatchResult?
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex {
            if Self.fold(haystack[cursor]) == foldedQuery[0] {
                if let candidate = Self.scoreFrom(
                    haystack: haystack,
                    foldedQuery: foldedQuery,
                    startIndex: cursor
                ) {
                    if best == nil || candidate.score > best!.score {
                        best = candidate
                    }
                }
            }
            cursor = haystack.index(after: cursor)
        }
        return best
    }

    /// Greedy alignment starting at a specific haystack character that's
    /// already known to match `foldedQuery[0]`. `previousHaystackChar` is
    /// seeded from the character immediately before `startIndex` (if any)
    /// so the first match still earns its word-boundary bonus.
    private static func scoreFrom(
        haystack: String,
        foldedQuery: [Character],
        startIndex: String.Index
    ) -> FuzzyMatchResult? {
        var queryIndex = 0
        var ranges: [Range<String.Index>] = []
        var score = 0
        var previousMatchEnd: String.Index?
        var previousHaystackChar: Character? = startIndex > haystack.startIndex
            ? haystack[haystack.index(before: startIndex)]
            : nil
        var contiguousRun = 0

        var cursor = startIndex
        while cursor < haystack.endIndex && queryIndex < foldedQuery.count {
            let char = haystack[cursor]
            let nextIndex = haystack.index(after: cursor)
            let foldedChar = Self.fold(char)

            if foldedChar == foldedQuery[queryIndex] {
                ranges.append(cursor..<nextIndex)

                var bonus = 1
                if Self.isWordBoundary(previous: previousHaystackChar, current: char) {
                    bonus += 8
                }
                if let prevEnd = previousMatchEnd, prevEnd == cursor {
                    contiguousRun += 1
                    bonus += 2 * contiguousRun
                } else {
                    contiguousRun = 0
                    if let prevEnd = previousMatchEnd {
                        let gap = haystack.distance(from: prevEnd, to: cursor)
                        bonus -= min(gap, Self.maxGapPenalty)
                    }
                }
                score += bonus
                previousMatchEnd = nextIndex
                queryIndex += 1
            }

            previousHaystackChar = char
            cursor = nextIndex
        }

        guard queryIndex == foldedQuery.count else { return nil }
        return FuzzyMatchResult(score: score, ranges: ranges)
    }

    /// Single-character fold, symmetric across query and haystack so multi-
    /// character expansions (e.g. `ß` → `ss`) collapse the same way on both
    /// sides. ASCII fast-path keeps the hot per-keystroke loop cheap; the
    /// `String.folding` allocation is reserved for non-ASCII input.
    private static func fold(_ char: Character) -> Character {
        if char.isASCII {
            return Character(char.lowercased())
        }
        return String(char)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .first ?? char
    }

    private static let wordSeparators: Set<Character> = ["/", "_", " ", "~", ".", "-", "\\"]

    private static func isWordBoundary(previous: Character?, current: Character) -> Bool {
        guard let previous else { return true }
        if Self.wordSeparators.contains(previous) { return true }
        if previous.isLowercase && current.isUppercase { return true }
        return false
    }
}
