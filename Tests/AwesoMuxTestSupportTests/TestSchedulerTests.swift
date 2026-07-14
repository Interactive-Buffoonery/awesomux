import Foundation
import Testing
@testable import AwesoMuxTestSupport

@MainActor
@Suite("Test scheduler")
struct TestSchedulerTests {
    @Test("advance releases scheduled delays")
    func advanceReleasesDelays() async {
        let scheduler = TestScheduler()
        let delayed = Task { @MainActor in
            await scheduler.wait(for: .seconds(30))
            return true
        }

        #expect(await waitUntil { scheduler.sleeperCount == 1 })
        scheduler.advance()
        #expect(await delayed.value)
    }

    @Test("each cycle advance releases only the current scheduled delay")
    func repeatedAdvancesReleaseOneDelayEach() async {
        let scheduler = TestScheduler()
        var completed = false
        let delayed = Task { @MainActor in
            await scheduler.wait(for: .seconds(30))
            await scheduler.wait(for: .seconds(30))
            completed = true
            return true
        }

        #expect(await waitUntil { scheduler.sleepCallCount == 1 })
        scheduler.advanceOneCycle()
        #expect(await waitUntil { scheduler.sleepCallCount == 2 })
        #expect(scheduler.requestedDurations == [.seconds(30), .seconds(30)])
        await Task.yield()
        #expect(!completed)
        scheduler.advanceOneCycle()
        #expect(await delayed.value)
    }
}
