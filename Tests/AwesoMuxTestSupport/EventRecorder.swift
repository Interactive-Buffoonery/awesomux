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
}
