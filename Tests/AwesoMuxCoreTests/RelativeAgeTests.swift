import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct RelativeAgeTests {
    @Test
    func subMinuteRendersSeconds() {
        #expect(RelativeAge.string(sinceEpoch: 1_000, now: 1_005) == "5s")
        #expect(RelativeAge.string(sinceEpoch: 1_000, now: 1_059) == "59s")
    }

    @Test
    func minutesUnderAnHour() {
        #expect(RelativeAge.string(sinceEpoch: 0, now: 60) == "1m")
        #expect(RelativeAge.string(sinceEpoch: 0, now: 14 * 60 + 30) == "14m")
        #expect(RelativeAge.string(sinceEpoch: 0, now: 59 * 60) == "59m")
    }

    @Test
    func hoursUnderADay() {
        #expect(RelativeAge.string(sinceEpoch: 0, now: 3_600) == "1h")
        #expect(RelativeAge.string(sinceEpoch: 0, now: 2 * 3_600 + 1_800) == "2h")
        #expect(RelativeAge.string(sinceEpoch: 0, now: 23 * 3_600) == "23h")
    }

    @Test
    func daysBeyond() {
        #expect(RelativeAge.string(sinceEpoch: 0, now: 86_400) == "1d")
        #expect(RelativeAge.string(sinceEpoch: 0, now: 3 * 86_400 + 3_600) == "3d")
    }

    @Test
    func futureOrEqualClampsToZero() {
        #expect(RelativeAge.string(sinceEpoch: 1_000, now: 1_000) == "0s")
        #expect(RelativeAge.string(sinceEpoch: 2_000, now: 1_000) == "0s")
    }
}
