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
}
