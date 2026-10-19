import Testing
@testable import AwesoMuxCore

@Suite("FuzzyMatcher")
struct FuzzyMatchTests {
    @Test(arguments: [
        ("aab", "aaab", ["a", "a", "b"], [0, 1, 3]),
        ("cc", "Claude Code", ["C", "C"], [0, 7]),
        ("obs", "~/Obsidian/ProjectNotes", ["O", "b", "s"], [2, 3, 4]),
        ("cafe", "Café Project", ["C", "a", "f", "é"], [0, 1, 2, 3]),
        ("ce", "Café", ["C", "é"], [0, 3]),
        ("s", "ß", ["ß"], [0]),
        ("cod", "cxxxxxxxxx Code", ["C", "o", "d"], [11, 12, 13]),
    ])
    func highlights(query: String, haystack: String, expected: [String], positions: [Int]) throws {
        let result = try #require(FuzzyMatcher.match(query: query, in: haystack))
        #expect(result.ranges.map { String(haystack[$0]) } == expected)
        #expect(result.ranges.map { haystack.distance(from: haystack.startIndex, to: $0.lowerBound) } == positions)
    }

    @Test(arguments: [
        ("", "anything"), ("xyz", "Claude Code"), ("ba", "abc"), ("a", ""),
        ("abcdef", "ab"), (String(repeating: "a", count: FuzzyMatcher.maxQueryLength + 1), "anything"),
    ])
    func rejectedQueries(query: String, haystack: String) {
        #expect(FuzzyMatcher.match(query: query, in: haystack) == nil)
    }

}
