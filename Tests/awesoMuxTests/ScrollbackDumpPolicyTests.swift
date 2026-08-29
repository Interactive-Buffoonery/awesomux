import Testing
@testable import awesoMux

@Suite("Scrollback dump safety policy")
struct ScrollbackDumpPolicyTests {
    private let limits = ScrollbackDumpPolicy.Limits(
        maximumEstimatedBytes: 1_000,
        maximumRows: 100,
        estimatedBytesPerCell: 10,
        maximumNativeTextBytes: 250
    )

    @Test("allows a stable history below both safety limits")
    func allowsStableHistoryBelowLimits() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 9,
                currentColumns: 10,
                widestObservedColumns: 10,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .allow)
    }

    @Test("allows an estimate exactly at the byte limit")
    func allowsEstimateAtByteLimit() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 10,
                currentColumns: 10,
                widestObservedColumns: 10,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .allow)
    }

    @Test("blocks estimates above the byte limit")
    func blocksEstimateAboveByteLimit() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 11,
                currentColumns: 10,
                widestObservedColumns: 10,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .block(.tooLarge))
    }

    @Test("blocks histories above the independent row limit")
    func blocksHistoryAboveRowLimit() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 101,
                currentColumns: 1,
                widestObservedColumns: 1,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .block(.tooLarge))
    }

    @Test("uses the widest observed terminal width after narrowing")
    func usesWidestObservedWidth() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 6,
                currentColumns: 10,
                widestObservedColumns: 20,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .block(.tooLarge))
    }

    @Test("blocks missing rows and invalid columns")
    func blocksMissingOrInvalidSize() {
        #expect(
            ScrollbackDumpPolicy.decision(
                for: .init(
                    totalRows: nil,
                    currentColumns: 10,
                    widestObservedColumns: 10,
                    isGrowing: false
                ),
                limits: limits
            ) == .block(.unknownSize)
        )
        #expect(
            ScrollbackDumpPolicy.decision(
                for: .init(
                    totalRows: 10,
                    currentColumns: 0,
                    widestObservedColumns: 0,
                    isGrowing: false
                ),
                limits: limits
            ) == .block(.unknownSize)
        )
    }

    @Test("zero rows is a valid empty history")
    func zeroRowsIsAllowed() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 0,
                currentColumns: 10,
                widestObservedColumns: 10,
                isGrowing: false
            ),
            limits: limits
        )

        #expect(decision == .allow)
    }

    @Test("blocks a pane whose history is actively growing")
    func blocksGrowingHistory() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: 5,
                currentColumns: 10,
                widestObservedColumns: 10,
                isGrowing: true
            ),
            limits: limits
        )

        #expect(decision == .block(.growing))
    }

    @Test("overflow fails closed instead of trapping")
    func overflowFailsClosed() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: .max,
                currentColumns: .max,
                widestObservedColumns: .max,
                isGrowing: false
            ),
            limits: .init(
                maximumEstimatedBytes: .max,
                maximumRows: .max,
                estimatedBytesPerCell: .max,
                maximumNativeTextBytes: .max
            )
        )

        #expect(decision == .block(.tooLarge))
    }

    @Test("native text is rejected before Swift and TextKit when it overruns")
    func rejectsNativeTextOverrun() {
        #expect(ScrollbackDumpPolicy.acceptsNativeText(byteCount: 250, limits: limits))
        #expect(!ScrollbackDumpPolicy.acceptsNativeText(byteCount: 251, limits: limits))
    }
}
