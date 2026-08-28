import AwesoMuxCore
import Foundation

actor RemoteLivenessPoller {
    struct Key: Hashable, Sendable {
        let workspaceID: UUID
        let paneID: UUID
    }

    private struct Active {
        let nonce: UUID
        let task: Task<RemoteForegroundLiveness?, Never>
    }

    private let limiter: RemoteProbeConcurrencyLimiter
    private let probe: @Sendable (String) async -> RemoteForegroundLiveness?
    private var active: [Key: Active] = [:]

    init(
        maximumConcurrentProbes: Int = 3,
        probe: @escaping @Sendable (String) async -> RemoteForegroundLiveness? = { command in
            try? await RemoteLivenessProbe.run(command: command)
        }
    ) {
        limiter = RemoteProbeConcurrencyLimiter(limit: maximumConcurrentProbes)
        self.probe = probe
    }

    func sample(key: Key, command: String) async -> RemoteForegroundLiveness? {
        if let existing = active[key] { return await existing.task.value }
        let nonce = UUID()
        let limiter = limiter
        let probe = probe
        let task = Task<RemoteForegroundLiveness?, Never> {
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            return await probe(command)
        }
        active[key] = Active(nonce: nonce, task: task)
        let result = await task.value
        if active[key]?.nonce == nonce { active[key] = nil }
        return result
    }

    func cancel(key: Key) {
        active.removeValue(forKey: key)?.task.cancel()
    }
}

private actor RemoteProbeConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            running -= 1
        }
    }
}
