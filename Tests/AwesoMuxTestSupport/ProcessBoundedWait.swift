import Foundation

/// Thrown when a bounded process wait reaches its deadline.
///
/// This means Foundation never reported the child as exited — **not** that the
/// child is still alive. After a dropped termination event the child is
/// typically long gone and already reaped.
public struct ProcessWaitTimeout: Error, CustomStringConvertible {
    public let deadline: Duration

    public init(deadline: Duration) {
        self.deadline = deadline
    }

    public var description: String {
        "Foundation did not report process exit within \(deadline);"
            + " its termination state is unknown (awesomux#207)"
    }
}

extension Process {
    /// Bounded stand-in for Foundation's `waitUntilExit()`.
    ///
    /// `waitUntilExit()` returns only once Foundation observes the child's
    /// termination event. macOS can drop that event under heavy fork/load
    /// pressure, which leaves `isRunning` stuck `true` with no recovery: a real
    /// run blocked here for 15+ hours, pinning a core and holding the `.build`
    /// lock so every later `swift test` on the checkout queued behind it. A
    /// missed event is indistinguishable from "still running", so nothing short
    /// of a wall-clock deadline bounds it — in particular the suite's
    /// `terminationHandler`-driven signals cannot, since they ride the very
    /// notification that goes missing.
    ///
    /// Deliberately does **not** `terminate()` on timeout. The whole premise of
    /// the failure is that Foundation's view of the child is stale, so the PID
    /// may already have been recycled onto an unrelated process; signalling it
    /// would be worse than leaking. Tests that need a child killed terminate it
    /// explicitly, which they already do.
    ///
    /// Throws rather than returning a flag because callers almost always read
    /// `terminationStatus` on the next line, and reading it while Foundation
    /// still believes the process runs raises an Objective-C exception that
    /// Swift cannot catch — an abort that would take down the whole test
    /// process, not just the test.
    ///
    /// Blocks the calling thread. That is safe inside `async` tests because it
    /// waits only on a child process, which needs no Swift cooperative thread;
    /// do not repurpose it to await Swift-side work.
    ///
    /// The 30s default is deliberately looser than `waitUntilEventually`'s 10s:
    /// this waits on process spawn plus exec plus teardown rather than an
    /// in-process condition. Every child in the suite exits promptly once
    /// released, and the test job's own timeout is 120 minutes, so the deadline
    /// has room above the slowest legitimate child and far below CI's ceiling.
    public func waitUntilExit(deadline: Duration = .seconds(30)) throws {
        try waitForExit(deadline: deadline) { self.isRunning }
    }
}

/// Deadline loop behind ``Process/waitUntilExit(deadline:)``, split out so the
/// stuck-forever case (`isRunning` permanently `true`) is directly testable —
/// a dropped termination event cannot be provoked on demand.
///
/// Polls a monotonic clock so CPU contention cannot expire the wait early.
public func waitForExit(
    deadline: Duration,
    pollEvery: TimeInterval = 0.01,
    isRunning: () -> Bool
) throws {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while isRunning() {
        guard clock.now < end else { throw ProcessWaitTimeout(deadline: deadline) }
        Thread.sleep(forTimeInterval: pollEvery)
    }
}
