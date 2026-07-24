import Foundation

/// Thrown when a bounded process wait reaches its deadline.
///
/// This means Foundation never reported the child as exited — **not** that the
/// child is still alive. After a dropped termination event the child is
/// typically long gone and already reaped.
public struct ProcessWaitTimeout: Error, CustomStringConvertible {
    public let deadline: Duration
    /// The child's command, for attributing a CI timeout to the process that
    /// caused it. Nil when the process exposes no executable URL.
    public let command: String?

    public init(deadline: Duration, command: String? = nil) {
        self.deadline = deadline
        self.command = command
    }

    /// States the observation, not a diagnosis. A dropped termination event is
    /// only one way to get here: a child blocked writing to a pipe nobody has
    /// drained yet produces exactly the same symptom, and naming #207 outright
    /// would send the next investigator after a phantom OS bug.
    public var description: String {
        let subject = command.map { "`\($0)`" } ?? "child process"
        return "\(subject) did not report exit within \(deadline). Either its"
            + " termination event was dropped (awesomux#207) or it is blocked"
            + " writing to an undrained pipe."
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
    /// Blocks the calling thread, including inside `async` tests. That is no
    /// worse than the `waitUntilExit()` it replaces, which blocked the same
    /// thread without a bound — but it is not free: Swift's cooperative pool is
    /// fixed-width and does not spawn a replacement thread for a blocked one,
    /// so enough concurrent waits can starve it regardless of what they wait on.
    /// ponytail: acceptable while these are a few dozen short child waits; if
    /// they multiply or lengthen, add an async variant polling `clock.sleep`
    /// the way `waitUntilEventually` does.
    ///
    /// The 30s default is deliberately looser than `waitUntilEventually`'s 10s:
    /// this waits on process spawn plus exec plus teardown rather than an
    /// in-process condition. Every child in the suite exits promptly once
    /// released, and the test job's own timeout is 120 minutes, so the deadline
    /// has room above the slowest legitimate child and far below CI's ceiling.
    public func waitUntilExitEventually(deadline: Duration = .seconds(30)) throws {
        try Process.waitForExit(
            deadline: deadline,
            command: executableURL?.lastPathComponent
        ) { self.isRunning }
    }

    /// Deadline loop behind ``waitUntilExitEventually(deadline:)``, split out so
    /// the stuck-forever case (`isRunning` permanently `true`) is directly
    /// testable — a dropped termination event cannot be provoked on demand.
    ///
    /// Polls a monotonic clock so CPU contention cannot expire the wait early.
    public static func waitForExit(
        deadline: Duration,
        pollEvery: Duration = .milliseconds(10),
        command: String? = nil,
        isRunning: () -> Bool
    ) throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while isRunning() {
            guard clock.now < end else {
                // One last read before giving up: the child can exit in the
                // window between the check above and the deadline expiring.
                guard isRunning() else { return }
                throw ProcessWaitTimeout(deadline: deadline, command: command)
            }
            Thread.sleep(forTimeInterval: pollEvery.seconds)
        }
    }
}

extension Duration {
    /// `Thread.sleep` wants a `TimeInterval`; the surrounding API speaks
    /// `Duration` to match `Wait.swift`'s vocabulary.
    fileprivate var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) * 1e-18
    }
}
