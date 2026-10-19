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

    @Test("a fresh tick invalidates an in-flight stale result")
    func freshTickInvalidatesInFlightResult() async {
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
        pendingAge = nil
        watchdog.recordTick()
        await faultSource.resume(returning: GhosttyEventLoopWatchdog.faultCountThreshold)

        #expect(await check.value == false)
        #expect(fired == false)

        pendingAge = Self.staleAge
        let nextCheck = Task { @MainActor in await watchdog.checkForWedge() }
        await faultSource.waitForPendingQuery()
        await faultSource.resume(returning: 0)
        #expect(await nextCheck.value == false)
    }

    @Test("a wakeup serviced without a tick does not fire an in-flight result")
    func servicedWakeupWithoutTickDoesNotFire() async {
        // tick() clears the coalescer latch before its `guard let app`
        // check, so a wakeup can be serviced without recordTick ever
        // running (app nil mid-reload). The generation proxy alone would
        // miss this; finishCheck must re-read the live staleness signal.
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
        pendingAge = nil
        await faultSource.resume(returning: GhosttyEventLoopWatchdog.faultCountThreshold)

        #expect(await check.value == false)
        #expect(fired == false)
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
