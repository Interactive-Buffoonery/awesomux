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
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column),
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

/// Carries a value through a bounded signal without double-resuming on late replies.
public final class ValueResumer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let signal: SignalResumer
    private var result: Value?
    private var finished = false

    fileprivate init(signal: SignalResumer) { self.signal = signal }

    public func resume(returning value: Value) {
        let accepted = lock.withLock {
            guard !finished else { return false }
            finished = true
            result = value
            return true
        }
        if accepted { signal.resume() }
    }

    fileprivate func value(or fallback: Value) -> Value {
        lock.withLock {
            finished = true
            return result ?? fallback
        }
    }
}

public func awaitValue<Value: Sendable>(
    fallback: Value,
    deadline: Duration = signalDeadline,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column),
    _ register: (ValueResumer<Value>) -> Void
) async -> Value {
    var resumer: ValueResumer<Value>!
    await awaitSignal(deadline: deadline, isolation: isolation, sourceLocation: sourceLocation) { signal in
        let valueResumer = ValueResumer<Value>(signal: signal)
        resumer = valueResumer
        register(valueResumer)
    }
    return resumer.value(or: fallback)
}
