import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite struct DocumentRevisionIndicatorStateTests {
    @Test func recordingARevisionExpandsItsRecoverableCounts() {
        var state = DocumentRevisionIndicatorState()
        let tab = makeTab(path: "/tmp/plan.md")
        let revision = LineDiffCount(added: 3, removed: 1)

        state.record(revision, for: tab)

        #expect(state.indicator(for: tab)?.revision == revision)
        #expect(state.indicator(for: tab)?.presentation == .expanded)
    }

    @Test func compactIndicatorCanRevealCountsAgainOrBeDismissed() throws {
        var state = DocumentRevisionIndicatorState()
        let tab = makeTab(path: "/tmp/plan.md")
        let revision = LineDiffCount(added: 2, removed: 4)
        state.record(revision, for: tab)
        let generation = try #require(state.indicator(for: tab)?.generation)
        state.recordActiveViewingTime(.seconds(9), for: tab, generation: generation)

        state.collapse(for: tab)
        #expect(state.indicator(for: tab)?.revision == revision)
        #expect(state.indicator(for: tab)?.presentation == .compact)

        state.expand(for: tab)
        #expect(state.indicator(for: tab)?.presentation == .expanded)
        #expect(state.remainingExpandedTime(of: .seconds(9), for: tab) == .seconds(9))

        state.dismiss(for: tab)
        #expect(state.indicator(for: tab) == nil)
    }

    @Test func pruningDropsClosedTabsAndInPlaceFileReplacements() {
        var state = DocumentRevisionIndicatorState()
        let kept = makeTab(path: "/tmp/kept.md")
        let closed = makeTab(path: "/tmp/closed.md")
        let replacedOriginal = makeTab(path: "/tmp/old.md")
        state.record(LineDiffCount(added: 1, removed: 0), for: kept)
        state.record(LineDiffCount(added: 2, removed: 0), for: closed)
        state.record(LineDiffCount(added: 3, removed: 0), for: replacedOriginal)

        var replaced = replacedOriginal
        replaced.fileURL = URL(fileURLWithPath: "/tmp/new.md")
        state.prune(keeping: [kept, replaced])

        #expect(state.indicator(for: kept) != nil)
        #expect(state.indicator(for: closed) == nil)
        #expect(state.indicator(for: replacedOriginal) == nil)
    }

    @Test func everyRevisionGetsAFreshGenerationEvenWhenCountsMatch() {
        var state = DocumentRevisionIndicatorState()
        let tab = makeTab(path: "/tmp/plan.md")
        let revision = LineDiffCount(added: 1, removed: 1)
        state.record(revision, for: tab)
        let firstGeneration = state.indicator(for: tab)?.generation

        state.record(revision, for: tab)

        #expect(state.indicator(for: tab)?.generation != firstGeneration)
        #expect(state.indicator(for: tab)?.presentation == .expanded)
    }

    @Test func activeViewingTimePausesAndResetsForANewGeneration() throws {
        var state = DocumentRevisionIndicatorState()
        let tab = makeTab(path: "/tmp/plan.md")
        let revision = LineDiffCount(added: 1, removed: 1)
        state.record(revision, for: tab)
        let firstGeneration = try #require(state.indicator(for: tab)?.generation)

        state.recordActiveViewingTime(.seconds(4), for: tab, generation: firstGeneration)
        #expect(state.remainingExpandedTime(of: .seconds(9), for: tab) == .seconds(5))

        state.record(revision, for: tab)
        state.recordActiveViewingTime(.seconds(4), for: tab, generation: firstGeneration)
        #expect(state.remainingExpandedTime(of: .seconds(9), for: tab) == .seconds(9))
    }

    private func makeTab(path: String) -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: path),
            title: (path as NSString).lastPathComponent
        )
    }
}
