@MainActor
public final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var waitCallCount = 0
    public var waiterCount: Int { waiters.count }

    public init() {}

    public func wait() async {
        waitCallCount += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
