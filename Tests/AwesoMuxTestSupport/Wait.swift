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

@MainActor
public func drainMainQueue(rounds: Int = 20) async {
    for _ in 0..<rounds {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
