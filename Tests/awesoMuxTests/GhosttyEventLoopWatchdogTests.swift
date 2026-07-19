import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty event loop watchdog")
struct GhosttyEventLoopWatchdogTests {
    @MainActor
    final class FakeFaultSource: GhosttyFaultLogSource {
        var countToReturn = 0
        var capturedSince: Date?

        func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int {
            capturedSince = since
            return countToReturn
        }
    }

    @Test("does not query when the tick is fresh")
    func doesNotFireWhenTickFresh() async {
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

        #expect(await watchdog.checkForWedge() == false)
        #expect(fired == false)
        #expect(faultSource.capturedSince == nil)
    }

    @Test("fires when the tick is stale and the fault count crosses the threshold")
    func firesWhenStaleAndFaulty() async {
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

        #expect(await watchdog.checkForWedge())
        #expect(fired)
    }

    @Test("does not fire when the tick is stale but no faults were observed")
    func doesNotFireWhenStaleButNoFaults() async {
        let faultSource = FakeFaultSource()
        var fired = false
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fired = true }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 5)

        #expect(await watchdog.checkForWedge() == false)
        #expect(fired == false)
    }

    @Test("only fires once per wedge until the next recordTick")
    func firesOnlyOncePerWedge() async {
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

        #expect(await watchdog.checkForWedge())
        #expect(await watchdog.checkForWedge() == false)
        #expect(fireCount == 1)
    }

    @Test("queries the fault source with a bounded time window")
    func queriesFaultSourceWithCorrectSinceBound() async {
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

        _ = await watchdog.checkForWedge()

        #expect(faultSource.capturedSince == clock.addingTimeInterval(-GhosttyEventLoopWatchdog.faultWindow))
    }

    @Test("a suspended fault query does not block main-actor work")
    func suspendedQueryDoesNotBlockMainActor() async {
        let faultSource = SuspendedFaultSource()
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: {}
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        let check = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()

        var mainActorWorkRan = false
        Task { @MainActor in mainActorWorkRan = true }
        #expect(await waitUntil { mainActorWorkRan })

        await faultSource.resume(returning: 0)
        #expect(await check.value == false)
    }

    @Test("a fresh tick invalidates an in-flight stale result")
    func freshTickInvalidatesInFlightResult() async {
        let faultSource = SuspendedFaultSource()
        var fired = false
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: { fired = true }
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        let check = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        watchdog.recordTick()
        await faultSource.resume(returning: GhosttyEventLoopWatchdog.faultCountThreshold)

        #expect(await check.value == false)
        #expect(fired == false)

        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)
        let nextCheck = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        await faultSource.resume(returning: 0)
        #expect(await nextCheck.value == false)
    }

    @Test("a second check is skipped while a fault query is in flight")
    func overlappingCheckIsSkipped() async {
        let faultSource = SuspendedFaultSource()
        var clock = Date(timeIntervalSince1970: 1_000)
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            now: { clock },
            onWedgeDetected: {}
        )
        watchdog.recordTick()
        clock = clock.addingTimeInterval(GhosttyEventLoopWatchdog.staleTickThreshold + 1)

        let firstCheck = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        #expect(await watchdog.checkForWedge() == false)
        #expect(await faultSource.queryCount == 1)

        await faultSource.resume(returning: 0)
        _ = await firstCheck.value
    }
}

private actor SuspendedFaultSource: GhosttyFaultLogSource {
    private var continuation: CheckedContinuation<Int, Never>?
    private var pendingQueryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var queryCount = 0

    func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int {
        queryCount += 1
        let waiters = pendingQueryWaiters
        pendingQueryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForPendingQuery() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { pendingQueryWaiters.append($0) }
    }

    func resume(returning count: Int) {
        continuation?.resume(returning: count)
        continuation = nil
    }
}
