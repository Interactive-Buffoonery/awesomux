import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Surface search state")
struct SurfaceSearchStateTests {
    @Test("scrollback dump moves from loading to loaded for the active request")
    func scrollbackDumpLoadsForActiveRequest() throws {
        let state = SurfaceSearchState()
        let request = try #require(state.beginScrollbackDump())

        #expect(state.scrollbackDump == .loading)

        state.finishScrollbackDump(.loaded(text: "history"), request: request)

        #expect(state.scrollbackDump == .loaded(text: "history"))
        #expect(state.scrollbackDump?.copyPayload == "history")
    }

    @Test("scrollback dump distinguishes an empty result from a failed read")
    func scrollbackDumpDistinguishesEmptyAndFailure() throws {
        let state = SurfaceSearchState()
        let emptyRequest = try #require(state.beginScrollbackDump())
        state.finishScrollbackDump(.loaded(text: ""), request: emptyRequest)

        #expect(state.scrollbackDump == .loaded(text: ""))

        state.dismissScrollbackDump()
        let failedRequest = try #require(state.beginScrollbackDump())
        state.finishScrollbackDump(.failed, request: failedRequest)

        #expect(state.scrollbackDump == .failed)
    }

    @Test("dismissing scrollback invalidates work that finishes later")
    func dismissingScrollbackInvalidatesStaleWork() throws {
        let state = SurfaceSearchState()
        let request = try #require(state.beginScrollbackDump())

        state.dismissScrollbackDump()
        state.finishScrollbackDump(.loaded(text: "stale"), request: request)

        #expect(state.scrollbackDump == nil)
    }

    @Test("a blocked scrollback cannot copy")
    func blockedScrollbackCannotCopy() throws {
        let state = SurfaceSearchState()
        let request = try #require(state.beginScrollbackDump())
        state.finishScrollbackDump(
            .blocked(reason: .tooLarge),
            request: request
        )

        #expect(state.scrollbackDump?.copyPayload == nil)
        #expect(state.scrollbackDump?.copyButtonTitle == "Copy")
    }

    @Test("repeated scrollback commands do not create duplicate requests")
    func repeatedScrollbackCommandsDoNotDuplicate() throws {
        let state = SurfaceSearchState()
        _ = try #require(state.beginScrollbackDump())

        #expect(state.beginScrollbackDump() == nil)
        #expect(state.scrollbackDump == .loading)
    }

    @Test("matches with no selection display a dash, not zero")
    func matchesWithoutSelectionDisplayDash() {
        let state = SurfaceSearchState()
        state.present(needle: "42")
        state.updateTotal(1)

        #expect(state.selected == nil)
        #expect(state.matchCountText == "– / 1")
    }

    @Test("selecting the only match reads one of one")
    func selectingOnlyMatchReadsOneOfOne() {
        let state = SurfaceSearchState()
        state.present(needle: "42")
        state.updateTotal(1)
        state.updateSelected(0)

        #expect(state.matchCountText == "1 / 1")
        #expect(state.spokenSummary == "Match 1 of 1")
    }

    @Test("auto-select fires exactly once, on fresh results with no selection")
    func autoSelectDecisionTruthTable() {
        typealias Decide = (Int?, Int?, Bool) -> Bool
        let decide: Decide = GhosttySurfaceNSView.shouldAutoSelectFirstMatch

        #expect(decide(1, nil, false))
        #expect(decide(14, nil, false))
        // Already selected: the user (or a prior auto-select) owns position.
        #expect(!decide(14, 0, false))
        // One-shot spent: a second total before SEARCH_SELECTED returns must
        // not navigate again and land on match 2.
        #expect(!decide(14, nil, true))
        // No results, unknown results, or hidden bar (total nil when the bar
        // is closed): nothing to select.
        #expect(!decide(0, nil, false))
        #expect(!decide(nil, nil, false))
    }

    @Test("zero-total summaries wait longer before being announced")
    func zeroTotalSummariesWaitLongerBeforeAnnouncement() {
        #expect(SurfaceSearchMatchSummary(selected: nil, total: 0).announcementDelay == 1.0)
        #expect(SurfaceSearchMatchSummary(selected: nil, total: nil).announcementDelay == 1.0)
        #expect(SurfaceSearchMatchSummary(selected: nil, total: 3).announcementDelay == 0.2)
        #expect(SurfaceSearchMatchSummary(selected: 0, total: 3).announcementDelay == 0.2)
    }

    @Test("negative selection with matches displays a dash")
    func negativeSelectionWithMatchesDisplaysDash() {
        #expect(SurfaceSearchMatchSummary(selected: -1, total: 7).currentDisplayText == "–")
        #expect(SurfaceSearchMatchSummary(selected: nil, total: nil).currentDisplayText == "0")
    }

    @Test("spoken summary announces the match count before a selection exists")
    func spokenSummaryAnnouncesCountBeforeSelection() {
        let state = SurfaceSearchState()
        state.present(needle: "42")
        state.updateTotal(3)

        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(state.spokenSummary == "3 matches")
        }

        state.updateTotal(1)
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(state.spokenSummary == "1 match")
        }
    }

    private static var resourcesBundle: Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
        return Bundle(url: url) ?? .main
    }

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
