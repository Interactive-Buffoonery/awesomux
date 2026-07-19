public actor EventRecorder<Event: Sendable> {
    public private(set) var values: [Event] = []

    public init() {}

    public func record(_ event: Event) {
        values.append(event)
    }

    public func waitForCount(_ expected: Int, attempts: Int = 10_000) async -> Bool {
        for _ in 0..<attempts {
            if values.count >= expected { return true }
            await Task.yield()
        }
        return values.count >= expected
    }

    public func waitForCount(
        _ expected: Int,
        deadline: Duration,
        pollEvery: Duration = .milliseconds(20)
    ) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)

        while clock.now < end {
            if values.count >= expected { return true }
            guard !Task.isCancelled else { return values.count >= expected }
            try? await clock.sleep(for: pollEvery)
        }
        return values.count >= expected
    }
}
