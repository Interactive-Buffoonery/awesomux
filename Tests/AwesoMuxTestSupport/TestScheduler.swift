import Foundation

@MainActor
public final class TestScheduler {
    private var gate = AsyncGate()

    public var sleeperCount: Int { gate.waiterCount }
    public private(set) var sleepCallCount = 0
    public private(set) var requestedDurations: [Duration] = []

    public init() {}

    public func wait(for duration: Duration) async {
        sleepCallCount += 1
        requestedDurations.append(duration)
        await gate.wait()
    }

    public func advance() {
        gate.open()
    }

    public func advanceOneCycle() {
        gate.open()
        gate = AsyncGate()
    }
}
