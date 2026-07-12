import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("CommandExitCache")
struct CommandExitCacheTests {
    @Test("records and clears cached exit code with timestamp")
    func recordsAndClearsExitCode() {
        var cache = CommandExitCache()

        cache.record(exitCode: 7, at: 10)
        #expect(cache.exitCode == 7)
        #expect(cache.recordedAt == 10)

        cache.clear()
        #expect(cache.exitCode == nil)
        #expect(cache.recordedAt == nil)
    }

    @Test("fresh non-zero exit code is eligible for process-exit attribution")
    func freshNonZeroExitCodeIsEligible() {
        let recordedAt: TimeInterval = 10
        let cache = CommandExitCache(exitCode: 7, recordedAt: recordedAt)
        let freshnessWindow = CommandExitCache.defaultFreshnessWindow

        #expect(cache.hasFreshNonZeroExitCode(now: recordedAt + freshnessWindow))
        #expect(cache.shouldSignalSiblingPaneExit(now: recordedAt + freshnessWindow, paneCount: 2))
    }

    @Test("stale, future, clean, and single-pane exits do not signal")
    func rejectsIneligibleExitCodes() {
        let recordedAt: TimeInterval = 10
        let freshnessWindow = CommandExitCache.defaultFreshnessWindow

        #expect(
            !CommandExitCache(exitCode: 7, recordedAt: recordedAt)
                .hasFreshNonZeroExitCode(now: recordedAt + freshnessWindow + 0.001)
        )
        #expect(
            !CommandExitCache(exitCode: 7, recordedAt: recordedAt)
                .hasFreshNonZeroExitCode(now: recordedAt - 0.001)
        )
        #expect(
            !CommandExitCache(exitCode: 0, recordedAt: recordedAt)
                .hasFreshNonZeroExitCode(now: recordedAt)
        )
        #expect(
            !CommandExitCache(exitCode: 7, recordedAt: recordedAt)
                .shouldSignalSiblingPaneExit(now: recordedAt, paneCount: 1)
        )
    }
}
