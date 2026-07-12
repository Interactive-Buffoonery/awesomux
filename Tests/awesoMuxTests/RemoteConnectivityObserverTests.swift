import AppKit
import Foundation
import Network
import Testing
@testable import awesoMux

@MainActor
@Suite("RemoteConnectivityObserver")
struct RemoteConnectivityObserverTests {
    @Test("connectivity churn debounces to one stale mark")
    func connectivityChurnDebouncesToOneStaleMark() async throws {
        // Gate stays closed until all three debounce tasks are parked at their
        // delay point (the two superseded ones still run their bodies), so the
        // release proves EXACTLY one mark survives the churn — including that
        // the cancelled tasks no-op after resuming, not merely that one mark
        // showed up first.
        let gate = ManualDelayGate()
        var markCount = 0
        let observer = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            sleep: { _ in await gate.wait() },
            markRemotePanesPossiblyStale: {
                markCount += 1
            }
        )

        observer.recordConnectivitySignal()
        observer.recordConnectivitySignal()
        observer.recordConnectivitySignal()

        #expect(await eventually { gate.waiterCount == 3 })
        gate.release()
        await drainMainQueue()
        #expect(markCount == 1)
        observer.stop()
    }

    @Test("start creates and starts one path monitor")
    func startIsIdempotent() {
        var monitors: [SpyPathMonitor] = []
        let observer = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: {
                let monitor = SpyPathMonitor()
                monitors.append(monitor)
                return monitor
            },
            markRemotePanesPossiblyStale: {}
        )

        observer.start()
        observer.start()

        #expect(monitors.count == 1)
        #expect(monitors.first?.startCount == 1)
        observer.stop()
    }

    @Test("initial path monitor update is treated as baseline")
    func initialPathMonitorUpdateIsTreatedAsBaseline() async throws {
        // Pre-released gate: no debounce coalescing under test, so the timer may
        // elapse instantly. If a regression wrongly scheduled a signal for the
        // baseline update, it would fire during the drain below.
        let gate = ManualDelayGate()
        gate.release()
        var markCount = 0
        let observer = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: { SpyPathMonitor() },
            sleep: { _ in await gate.wait() },
            markRemotePanesPossiblyStale: {
                markCount += 1
            }
        )

        observer.start()
        observer.recordPathMonitorUpdate()
        await drainMainQueue()
        // waitCallCount == 0 proves no injected wait was entered for the
        // baseline update; the positive assertion below proves the seam is
        // actually wired, so a bypass regression can't false-pass both.
        #expect(markCount == 0)
        #expect(gate.waitCallCount == 0)

        observer.recordPathMonitorUpdate()
        #expect(await eventually { markCount == 1 })
        #expect(gate.waitCallCount == 1)
        observer.stop()
    }

    @Test("stop cancels the active monitor and allows restart")
    func stopCancelsMonitorAndAllowsRestart() {
        var monitors: [SpyPathMonitor] = []
        let observer = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: {
                let monitor = SpyPathMonitor()
                monitors.append(monitor)
                return monitor
            },
            markRemotePanesPossiblyStale: {}
        )

        observer.start()
        observer.stop()
        observer.start()

        #expect(monitors.count == 2)
        #expect(monitors[0].startCount == 1)
        #expect(monitors[0].cancelCount == 1)
        #expect(monitors[1].startCount == 1)
        #expect(monitors[1].cancelCount == 0)
        observer.stop()
    }

    @Test("restart treats the next path monitor update as a new baseline")
    func restartTreatsNextPathMonitorUpdateAsNewBaseline() async throws {
        // Pre-released gate: no debounce coalescing under test — the negative
        // assertion relies on the post-restart baseline-eat scheduling nothing,
        // not on a timing window; a wrongly scheduled signal would fire during
        // the drain below.
        let gate = ManualDelayGate()
        gate.release()
        var markCount = 0
        let observer = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: { SpyPathMonitor() },
            sleep: { _ in await gate.wait() },
            markRemotePanesPossiblyStale: {
                markCount += 1
            }
        )

        observer.start()
        observer.recordPathMonitorUpdate()
        observer.recordPathMonitorUpdate()
        #expect(await eventually { markCount == 1 })

        observer.stop()
        observer.start()
        observer.recordPathMonitorUpdate()
        await drainMainQueue()
        // Flat waitCallCount proves no injected wait was entered for the
        // post-restart baseline update; the earlier and later positive
        // assertions prove the seam is wired, so a bypass can't false-pass.
        #expect(markCount == 1)
        #expect(gate.waitCallCount == 1)

        observer.recordPathMonitorUpdate()
        #expect(await eventually { markCount == 2 })
        #expect(gate.waitCallCount == 2)
        observer.stop()
    }

    @Test("wake notification is observed only while running")
    func wakeNotificationIsObservedOnlyWhileRunning() async throws {
        // Pre-released gate: no debounce coalescing under test — determinism
        // comes from stop() unregistering the wake observer before the second
        // post. If a regression left it registered, its notification-block ->
        // Task -> mark chain would complete during the drain below.
        let gate = ManualDelayGate()
        gate.release()
        let notificationCenter = NotificationCenter()
        var markCount = 0
        let observer = RemoteConnectivityObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: { SpyPathMonitor() },
            sleep: { _ in await gate.wait() },
            markRemotePanesPossiblyStale: {
                markCount += 1
            }
        )

        observer.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { markCount == 1 })

        observer.stop()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainQueue()
        // Flat waitCallCount proves no injected wait was entered for the
        // post-stop wake; the earlier positive assertion proves the seam is
        // wired, so a bypass regression can't false-pass both.
        #expect(markCount == 1)
        #expect(gate.waitCallCount == 1)
    }

    @Test("deinit stops observer and cancels pending debounce")
    func deinitStopsObserverAndCancelsPendingDebounce() async throws {
        // Gate stays closed until after deinit: the debounce task must be
        // suspended at its delay point when deinit cancels it, so releasing
        // afterwards proves the resumed task no-ops via its cancellation guard
        // (markCount stays 0) rather than proving it merely never woke up.
        let gate = ManualDelayGate()
        var monitors: [SpyPathMonitor] = []
        var markCount = 0
        var observer: RemoteConnectivityObserver? = RemoteConnectivityObserver(
            notificationCenter: NotificationCenter(),
            debounceNanoseconds: 20_000_000,
            pathMonitorFactory: {
                let monitor = SpyPathMonitor()
                monitors.append(monitor)
                return monitor
            },
            sleep: { _ in await gate.wait() },
            markRemotePanesPossiblyStale: {
                markCount += 1
            }
        )

        observer?.start()
        observer?.recordConnectivitySignal()
        #expect(await eventually { gate.waiterCount == 1 })

        observer = nil
        // Path monitor cancel proves isolated deinit ran stop().
        #expect(await eventually { monitors.first?.cancelCount == 1 })

        gate.release()
        await drainMainQueue()
        #expect(monitors.count == 1)
        #expect(markCount == 0)
    }
}

/// Yield-poll with a bound: deterministic (no wall clock — pending main-actor
/// jobs run whenever this suspends), and a condition that never comes reports
/// a failure rather than hanging the suite under real time pressure. Mirrors
/// the established `waitUntil`/`yieldUntil` pattern already used by
/// `SidebarPeekModelTests` and `ManualDelayGateTests` — this file was the last
/// holdout still polling `Date()` against a fixed wall-clock timeout, which
/// under CPU contention from a full parallel suite run could starve past the
/// deadline and report false failures (INT-590).
@MainActor
private func eventually(
    attempts: Int = 10_000,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

@MainActor
private final class SpyPathMonitor: ConnectivityPathMonitoring {
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var startQueueLabel: String?

    func start(queue: DispatchQueue) {
        startCount += 1
        startQueueLabel = queue.label
    }

    func cancel() {
        cancelCount += 1
    }
}
