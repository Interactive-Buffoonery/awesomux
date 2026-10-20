import Foundation
import Testing

/// Ceiling for a test wait on a signal that should arrive almost at once. It is
/// generous so slow hosted runners still pass, and finite so a missed signal
/// fails one named test instead of parking its shard until the CI job timeout.
public let signalDeadline: Duration = .seconds(30)

/// One-shot handle that ends an `awaitSignal` wait. Calling it more than once,
/// or after the deadline, does nothing, so it can sit in waiter lists and be
/// fired from any thread.
public final class SignalResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    fileprivate init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    public func resume() {
        finish(returning: true)?.cancel()
    }

    fileprivate func arm(_ deadline: Duration) {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            _ = self?.finish(returning: false)
        }
        // The signal can fire inside `register`, before the timer exists.
        let alreadyFinished = lock.withLock {
            guard continuation != nil else { return true }
            self.timer = timer
            return false
        }
        if alreadyFinished { timer.cancel() }
    }

    private func finish(returning value: Bool) -> Task<Void, Never>? {
        let (continuation, timer) = lock.withLock {
            defer { self.continuation = nil; self.timer = nil }
            return (self.continuation, self.timer)
        }
        continuation?.resume(returning: value)
        return timer
    }
}

/// Suspends until the resumer handed to `register` fires, or `deadline` passes.
/// On timeout it records an issue at the caller and returns `false`, so the
/// caller should stop rather than assert against state that never arrived.
@discardableResult
public func awaitSignal(
    deadline: Duration = signalDeadline,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ register: (SignalResumer) -> Void
) async -> Bool {
    let signalled = await withCheckedContinuation(isolation: isolation) { continuation in
        let resumer = SignalResumer(continuation)
        register(resumer)
        resumer.arm(deadline)
    }
    if !signalled {
        Issue.record("Signal did not arrive within \(deadline)", sourceLocation: sourceLocation)
    }
    return signalled
}
