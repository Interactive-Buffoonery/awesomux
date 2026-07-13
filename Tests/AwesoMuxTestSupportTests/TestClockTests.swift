import Foundation
import Testing
@testable import AwesoMuxTestSupport

@Suite("Test clock")
struct TestClockTests {
    @Test("starts at the supplied date and advances explicitly")
    func advancesExplicitly() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)

        #expect(clock.now == start)
        clock.advance(by: 2.5)
        #expect(clock.now == start.addingTimeInterval(2.5))
        clock.set(start.addingTimeInterval(10))
        #expect(clock.now == start.addingTimeInterval(10))
    }
}
