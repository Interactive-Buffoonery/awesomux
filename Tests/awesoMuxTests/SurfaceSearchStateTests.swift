import Testing
@testable import awesoMux

@MainActor
@Suite("Surface search state")
struct SurfaceSearchStateTests {
    @Test("match count displays selected result as one-based")
    func matchCountDisplaysOneBasedSelection() {
        let summary = SurfaceSearchMatchSummary(selected: 1, total: 14)

        #expect(summary.currentDisplay == 2)
        #expect(summary.totalDisplay == 14)
    }

    @Test("match count clamps missing or negative results to zero")
    func matchCountClampsMissingResults() {
        #expect(SurfaceSearchMatchSummary(selected: nil, total: nil).currentDisplay == 0)
        #expect(SurfaceSearchMatchSummary(selected: -1, total: 7).currentDisplay == 0)
        #expect(SurfaceSearchMatchSummary(selected: 9, total: 3).currentDisplay == 3)
    }

    @Test("empty search clears candidate counts without hiding the bar")
    func emptySearchClearsCountsWithoutHiding() {
        let state = SurfaceSearchState()
        state.present(needle: "libghostty")
        state.updateTotal(14)
        state.updateSelected(1)

        state.clearMatches()

        #expect(state.isPresented)
        #expect(state.needle == "libghostty")
        #expect(state.selected == nil)
        #expect(state.total == 0)
        #expect(state.matchCountText == "0 / 0")
    }

    @Test("hide resets the transient search state")
    func hideResetsTransientState() {
        let state = SurfaceSearchState()
        state.present(needle: "mux")
        state.updateTotal(4)
        state.updateSelected(2)

        state.hide()

        #expect(!state.isPresented)
        #expect(state.needle.isEmpty)
        #expect(state.selected == nil)
        #expect(state.total == nil)
    }

    @Test("closed search ignores stale match count updates")
    func closedSearchIgnoresStaleMatchCountUpdates() {
        let state = SurfaceSearchState()

        state.updateTotal(14)
        state.updateSelected(1)

        #expect(!state.isPresented)
        #expect(state.selected == nil)
        #expect(state.total == nil)
    }

    @Test("match count has a natural spoken summary")
    func matchCountHasNaturalSpokenSummary() {
        let state = SurfaceSearchState()
        state.present(needle: "libghostty")
        state.updateTotal(14)
        state.updateSelected(1)

        #expect(state.matchCountText == "2 / 14")
        #expect(state.spokenSummary == "Match 2 of 14")

        state.updateTotal(0)

        #expect(state.matchCountText == "0 / 0")
        #expect(state.spokenSummary == "No matches")
    }

    @Test("present without a needle refocuses without replacing the query")
    func presentWithoutNeedleKeepsExistingQuery() {
        let state = SurfaceSearchState()
        state.present(needle: "needle")
        let focusRequestSerial = state.focusRequestSerial

        state.present()

        #expect(state.isPresented)
        #expect(state.needle == "needle")
        #expect(state.focusRequestSerial == focusRequestSerial + 1)
    }
}
