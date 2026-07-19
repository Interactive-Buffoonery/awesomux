import Dispatch

@MainActor
public func waitUntil(
    attempts: Int = 10_000,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

public func waitUntilAsync(
    attempts: Int = 10_000,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// The sanctioned bounded wait for tests that observe real I/O or operating-system events.
///
/// Unlike `waitUntil`, this helper advances on elapsed monotonic time instead of a number
/// of scheduler yields, so CPU contention cannot exhaust the wait before an external event
/// has had a chance to arrive. Keep pure unit tests on controlled clocks or explicit gates.
@MainActor
public func waitUntilEventually(
    deadline: Duration = .seconds(10),
    pollEvery: Duration = .milliseconds(20),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)

    while clock.now < end {
        if condition() { return true }
        guard !Task.isCancelled else { return condition() }
        try? await clock.sleep(for: pollEvery)
    }
    return condition()
}

@MainActor
public func drainMainQueue(rounds: Int = 20) async {
    for _ in 0..<rounds {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
