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
                widestObservedColumns: 10
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
                widestObservedColumns: 10
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
                widestObservedColumns: 10
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
                widestObservedColumns: 1
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
                widestObservedColumns: 20
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
                    widestObservedColumns: 10
                ),
                limits: limits
            ) == .block(.unknownSize)
        )
        #expect(
            ScrollbackDumpPolicy.decision(
                for: .init(
                    totalRows: 10,
                    currentColumns: 0,
                    widestObservedColumns: 0
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
                widestObservedColumns: 10
            ),
            limits: limits
        )

        #expect(decision == .allow)
    }

    @Test("fresh row counts accept growing small histories and reject oversized ones")
    func growingHistoryUsesCurrentSize() {
        for rows in [UInt64(1), 5, 9, 10] {
            #expect(
                ScrollbackDumpPolicy.decision(
                    for: .init(totalRows: rows, currentColumns: 10, widestObservedColumns: 10),
                    limits: limits
                ) == .allow)
        }
        #expect(
            ScrollbackDumpPolicy.decision(
                for: .init(totalRows: 11, currentColumns: 10, widestObservedColumns: 10),
                limits: limits
            ) == .block(.tooLarge))
    }

    @Test("overflow fails closed instead of trapping")
    func overflowFailsClosed() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: .max,
                currentColumns: .max,
                widestObservedColumns: .max
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

    @Test("estimated-byte overflow fails closed independently of cell count")
    func estimatedBytesOverflowFailsClosed() {
        let decision = ScrollbackDumpPolicy.decision(
            for: .init(
                totalRows: UInt64.max / 2,
                currentColumns: 1,
                widestObservedColumns: 1
            ),
            limits: .init(
                maximumEstimatedBytes: .max,
                maximumRows: .max,
                estimatedBytesPerCell: 4,
                maximumNativeTextBytes: .max
            )
        )

        #expect(decision == .block(.tooLarge))
    }
}
