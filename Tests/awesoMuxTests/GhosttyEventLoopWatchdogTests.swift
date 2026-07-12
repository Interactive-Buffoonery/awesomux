import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty event loop watchdog")
struct GhosttyEventLoopWatchdogTests {
    final class FakeFaultSource: GhosttyFaultLogSource {
        var countToReturn = 0
        var capturedSince: Date?
        func recentFaultCount(subsystem: String, category: String, since: Date) -> Int {
            capturedSince = since
            return countToReturn
        }
    }

    @Test("does not fire when the tick is fresh even with a high fault count")
    func doesNotFireWhenTickFresh() {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = 10
        var fired = false
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fired = true }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(2)

        #expect(watchdog.checkForWedge() == false)
        #expect(fired == false)
    }

    @Test("fires when the tick is stale and the fault count crosses the threshold")
    func firesWhenStaleAndFaulty() {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = GhosttyEventLoopWatchdog.faultCountThreshold
        var fired = false
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fired = true }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        #expect(watchdog.checkForWedge() == true)
        #expect(fired == true)
    }

    @Test("does not fire when the tick is stale but no faults were observed")
    func doesNotFireWhenStaleButNoFaults() {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = 0
        var fired = false
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fired = true }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 5)

        #expect(watchdog.checkForWedge() == false)
        #expect(fired == false)
    }

    @Test("only fires once per wedge until the next recordTick")
    func firesOnlyOncePerWedge() {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = GhosttyEventLoopWatchdog.faultCountThreshold
        var fireCount = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fireCount += 1 }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        _ = watchdog.checkForWedge()
        _ = watchdog.checkForWedge()

        #expect(fireCount == 1)
    }

    @Test("queries the fault source with a since bound of current minus faultWindow")
    func queriesFaultSourceWithCorrectSinceBound() {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = GhosttyEventLoopWatchdog.faultCountThreshold
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: {}
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        _ = watchdog.checkForWedge()

        #expect(faultSource.capturedSince == clock.addingTimeInterval(-GhosttyEventLoopWatchdog.faultWindow))
    }
}
