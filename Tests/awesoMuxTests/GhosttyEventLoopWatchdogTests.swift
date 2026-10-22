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

    private static let staleAge = GhosttyEventLoopWatchdog.staleWakeupThreshold + 1

    @Test(arguments: ["idle", "fresh", "faulting", "quiet"])
    func wedgeDetection(scenario: String) async {
        let age: TimeInterval? = scenario == "idle" ? nil : scenario == "fresh" ? 2 : Self.staleAge
        let faults = scenario == "quiet" ? 0 : scenario == "faulting" ? GhosttyEventLoopWatchdog.faultCountThreshold : 10
        let expected = scenario == "faulting"
        let queries = scenario == "faulting" || scenario == "quiet"
        let source = FakeFaultSource()
        source.countToReturn = faults
        var fired = false
        let watchdog = GhosttyEventLoopWatchdog(faultSource: source, pendingWakeupAge: { age }, onWedgeDetected: { fired = true })
        #expect(await watchdog.checkForWedge() == expected)
        #expect(fired == expected)
        #expect((source.capturedSince != nil) == queries)
    }

    @Test("fires again for a new stall after a recovery tick")
    func refiresAfterRecoveryAndNewStall() async {
        let faultSource = FakeFaultSource()
        faultSource.countToReturn = GhosttyEventLoopWatchdog.faultCountThreshold
        var fireCount = 0
        var pendingAge: TimeInterval? = Self.staleAge
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            pendingWakeupAge: { pendingAge },
            onWedgeDetected: { fireCount += 1 }
        )

        #expect(await watchdog.checkForWedge())

        #expect(await watchdog.checkForWedge() == false)
        #expect(fireCount == 1)

        // Recovery: the wakeup is serviced and a tick lands.
        pendingAge = nil
        watchdog.recordTick()
        #expect(await watchdog.checkForWedge() == false)

        // A later, independent stall must fire again.
        pendingAge = Self.staleAge
        #expect(await watchdog.checkForWedge())
        #expect(fireCount == 2)
    }

    @Test("servicing a wakeup invalidates an in-flight stale result", arguments: [false, true])
    func freshTickInvalidatesInFlightResult(recordTick: Bool) async {
        let faultSource = SuspendedFaultSource()
        var fired = false
        var pendingAge: TimeInterval? = Self.staleAge
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            pendingWakeupAge: { pendingAge },
            onWedgeDetected: { fired = true }
        )

        let check = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        // Each row clears exactly one staleness signal, so either check alone
        // must stop the in-flight result from firing.
        if recordTick { watchdog.recordTick() } else { pendingAge = nil }
        await faultSource.resume(returning: GhosttyEventLoopWatchdog.faultCountThreshold)

        #expect(await check.value == false)
        #expect(fired == false)

        pendingAge = Self.staleAge
        let nextCheck = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        await faultSource.resume(returning: 0)
        #expect(await nextCheck.value == false)
    }

    @Test("a second check is skipped while a fault query is in flight")
    func overlappingCheckIsSkipped() async {
        let faultSource = SuspendedFaultSource()
        let watchdog = GhosttyEventLoopWatchdog(
            faultSource: faultSource,
            pendingWakeupAge: { Self.staleAge },
            onWedgeDetected: {}
        )

        let firstCheck = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        #expect(await watchdog.checkForWedge() == false)
        #expect(await faultSource.queryCount == 1)

        await faultSource.resume(returning: 0)
        _ = await firstCheck.value
    }
}

private actor SuspendedFaultSource: GhosttyFaultLogSource {
    private var continuation: ValueResumer<Int>?
    private var pendingQueryWaiters: [SignalResumer] = []
    private(set) var queryCount = 0

    func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int {
        queryCount += 1
        let waiters = pendingQueryWaiters
        pendingQueryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await awaitValue(fallback: 0) { continuation = $0 }
    }

    func waitForPendingQuery() async {
        guard continuation == nil else { return }
        await awaitSignal { pendingQueryWaiters.append($0) }
    }

    func resume(returning count: Int) {
        continuation?.resume(returning: count)
        continuation = nil
    }
}
