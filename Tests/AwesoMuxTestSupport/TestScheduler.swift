import Foundation

@MainActor
public final class TestScheduler {
    private let gate = AsyncGate()

    public var sleeperCount: Int { gate.waiterCount }
    public var sleepCallCount: Int { gate.waitCallCount }

    public init() {}

    public func wait(for _: Duration) async {
        await gate.wait()
    }

    public func advance() {
        gate.open()
    }
}
