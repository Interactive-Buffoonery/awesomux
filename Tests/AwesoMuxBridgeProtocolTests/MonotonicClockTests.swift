import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct MonotonicClockTests {

    @Test
    func nowIsFiniteAndNonDecreasingAcrossCalls() {
        let first = MonotonicClock.now()
        let second = MonotonicClock.now()
        #expect(first.timeIntervalSinceReferenceDate.isFinite)
        #expect(second.timeIntervalSinceReferenceDate.isFinite)
        #expect(second >= first)
    }

    @Test
    func addingTimeIntervalBuildsRelativeDeadlines() {
        let now = MonotonicClock.now()
        let deadline = now.addingTimeInterval(10)
        #expect(deadline.timeIntervalSince(now) == 10)
    }
}
