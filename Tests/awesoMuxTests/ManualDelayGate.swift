import Dispatch
import Testing

/// Test-controlled stand-in for the injected sleep seams (INT-557): `wait()`
/// suspends until `release()`, so a test decides exactly when a debounce or
/// grace timer "elapses" instead of racing real wall-clock sleeps under
/// parallel test scheduling. Once released the gate stays open — later waits
/// return immediately.
///
/// Cancellation deliberately does NOT resume waiters: tests must always
/// release the gate, and a cancelled timer task is expected to no-op via its
/// own post-sleep `Task.isCancelled` guard once resumed. Keeping a single
/// resume path (release drains the waiter list before resuming) makes a
/// double resume structurally impossible.
@MainActor
final class ManualDelayGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Number of tasks currently suspended in `wait()`. Tests poll this to
    /// prove a timer task really reached its delay point before cancelling it,
    /// so the test exercises cancel-of-a-pending-timer, not cancel-before-start.
    var waiterCount: Int { waiters.count }

    /// Total `wait()` entries, released or not. Negative assertions check this
    /// stayed flat to prove "nothing was scheduled" without any drain-timing
    /// dependence, and positive phases check it rose to prove the seam is
    /// actually wired — a regression back to a real sleep fails loudly here
    /// instead of false-passing a drain-bounded negative window.
    private(set) var waitCallCount = 0

    func wait() async {
        waitCallCount += 1
        if isReleased { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Drain pending main-queue/main-actor jobs so any wrongly-still-live timer
/// task would have fired before a negative assertion. Each round enqueues
/// behind everything already queued (same shape as the drainMainQueue helper
/// in SurfaceRemountOnSplitCollapseTests), so a pending job chain of depth N
/// completes within N rounds. The deepest chain these tests can produce is
/// notification block -> Task hop -> mark (3 jobs); 20 rounds is deliberate
/// headroom over that, with zero wall-clock dependence either way.
@MainActor
func drainMainQueue(rounds: Int = 20) async {
    for _ in 0..<rounds {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
@Suite("ManualDelayGate")
struct ManualDelayGateTests {
    @Test("release before wait is a passthrough")
    func releaseBeforeWaitPassesThrough() async {
        let gate = ManualDelayGate()
        gate.release()
        // Must return immediately; the test would hang (and time out) otherwise.
        await gate.wait()
        #expect(gate.waiterCount == 0)
    }

    @Test("wait suspends until release; a second release cannot double-resume")
    func waitSuspendsUntilRelease() async {
        let gate = ManualDelayGate()
        let waiter = Task { @MainActor in
            await gate.wait()
            return true
        }
        // Bounded, so a gate regression fails the test instead of wedging the
        // run; release below is unconditional, so `waiter` always terminates.
        #expect(await yieldUntil { gate.waiterCount == 1 })
        gate.release()
        #expect(await waiter.value)
        // Second release must be a no-op, not a CheckedContinuation crash.
        gate.release()
        #expect(gate.waiterCount == 0)
    }

    @Test("release resumes every pending waiter")
    func releaseResumesAllWaiters() async {
        let gate = ManualDelayGate()
        let first = Task { @MainActor in
            await gate.wait()
            return true
        }
        let second = Task { @MainActor in
            await gate.wait()
            return true
        }
        #expect(await yieldUntil { gate.waiterCount == 2 })
        gate.release()
        #expect(await first.value)
        #expect(await second.value)
    }

    /// Yield-poll with a bound: deterministic (no wall clock), and a condition
    /// that never comes reports a failure rather than hanging the suite.
    private func yieldUntil(attempts: Int = 10_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
