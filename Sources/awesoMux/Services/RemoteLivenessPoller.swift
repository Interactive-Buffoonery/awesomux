import AwesoMuxCore
import Foundation

actor RemoteLivenessPoller {
    struct Key: Hashable, Sendable {
        let workspaceID: UUID
        let paneID: UUID
        let generation: String
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
            guard await limiter.acquire() else { return nil }
            defer { Task { await limiter.release() } }
            guard !Task.isCancelled else { return nil }
            return await probe(command)
        }
        active[key] = Active(nonce: nonce, task: task)
        let result = await task.value
        if active[key]?.nonce == nonce { active[key] = nil }
        return result
    }

    @discardableResult
    func cancel(key: Key) -> Bool {
        guard let task = active.removeValue(forKey: key)?.task else { return false }
        task.cancel()
        return true
    }

    func cancel(workspaceID: UUID, paneID: UUID) {
        let keys = active.keys.filter {
            $0.workspaceID == workspaceID && $0.paneID == paneID
        }
        for key in keys {
            active.removeValue(forKey: key)?.task.cancel()
        }
    }
}

private actor RemoteProbeConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if running < limit {
            running += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            running -= 1
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
