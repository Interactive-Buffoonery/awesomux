import Testing
@testable import AwesoMuxCore

@Suite("CommentResolutionTracker")
struct CommentResolutionTrackerTests {
    @Test(
        arguments: [
            ([0, nil], [false, false]), ([3, nil], [false, false]),
            ([2, 0, nil], [false, true, true]),
            ([2, 0, 2, nil], [false, true, false, false]),
            ([1, 0, nil, nil], [false, true, true, false]),
            ([1, 0, nil, 0, nil], [false, true, true, false, false]),
            ([2, 0, 0, nil], [false, true, false, true]),
            ([3, 1, nil], [false, false, false]),
            ([2, 0, nil, 1, 0, nil], [false, true, true, false, true, true]),
            ([0, 2, nil], [false, false, false]),
        ] as [([Int?], [Bool])])
    func resolutionSequence(counts: [Int?], expected: [Bool]) {
        var tracker = CommentResolutionTracker()
        let results = counts.map { count in
            count.map { tracker.observe(commentCount: $0) } ?? tracker.confirmResolve()
        }
        #expect(results == expected)
    }

}
