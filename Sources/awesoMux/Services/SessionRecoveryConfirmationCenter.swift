import AwesoMuxBridgeProtocol
import Foundation

@MainActor
final class SessionRecoveryConfirmationCenter {
    static let shared = SessionRecoveryConfirmationCenter()
    private var confirmed: Set<TerminalSessionID> = []
    private var attachStarted: Set<TerminalSessionID> = []
    private var waiters: [TerminalSessionID: (token: UUID, timeout: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var expectations: [TerminalSessionID: (token: UUID, daemonPID: Int32?, createdEpoch: Int)] = [:]

    func begin(_ id: TerminalSessionID, daemonPID: Int32?, createdEpoch: Int) {
        cancel(id)
        confirmed.remove(id)
        attachStarted.remove(id)
        expectations[id] = (UUID(), daemonPID, createdEpoch)
    }

    func expectationToken(for id: TerminalSessionID) -> UUID? {
        expectations[id]?.token
    }

    func didStartAttach(_ id: TerminalSessionID) {
        guard expectations[id] != nil, attachStarted.insert(id).inserted,
            let waiter = waiters[id]
        else { return }
        scheduleTimeout(for: id, token: waiter.token, timeout: waiter.timeout)
    }

    func confirm(_ id: TerminalSessionID, daemonPID: Int, createdEpoch: Int) {
        guard let expected = expectations[id], expected.createdEpoch == createdEpoch,
            expected.daemonPID.map({ Int($0) == daemonPID }) ?? true
        else {
            cancel(id)
            return
        }
        expectations.removeValue(forKey: id)
        attachStarted.remove(id)
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(returning: true)
        } else {
            confirmed.insert(id)
        }
    }

    func wait(for id: TerminalSessionID, timeout: Duration = .seconds(3)) async -> Bool {
        if confirmed.remove(id) != nil { return true }
        guard expectations[id] != nil else { return false }
        if Task.isCancelled {
            expectations.removeValue(forKey: id)
            return false
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    expectations.removeValue(forKey: id)
                    continuation.resume(returning: false)
                    return
                }
                // `withTaskCancellationHandler` is async, so confirmation may
                // arrive after the fast path above but before this continuation
                // is installed. Consume it instead of waiting for a second event.
                if confirmed.remove(id) != nil {
                    continuation.resume(returning: true)
                    return
                }
                guard expectations[id] != nil else {
                    continuation.resume(returning: false)
                    return
                }
                if let previous = waiters.removeValue(forKey: id) {
                    previous.continuation.resume(returning: false)
                }
                waiters[id] = (token, timeout, continuation)
                if attachStarted.contains(id) {
                    scheduleTimeout(for: id, token: token, timeout: timeout)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id, token: token) }
        }
    }

    func cancel(_ id: TerminalSessionID, token: UUID? = nil) {
        if token == nil { confirmed.remove(id) }
        guard let waiter = waiters[id] else {
            if token == nil {
                expectations.removeValue(forKey: id)
                attachStarted.remove(id)
            }
            return
        }
        guard token == nil || waiter.token == token else { return }
        waiters.removeValue(forKey: id)
        expectations.removeValue(forKey: id)
        attachStarted.remove(id)
        waiter.continuation.resume(returning: false)
    }

    func cancel(_ id: TerminalSessionID, expectationToken: UUID) {
        guard expectations[id]?.token == expectationToken else { return }
        cancel(id)
    }

    private func scheduleTimeout(for id: TerminalSessionID, token: UUID, timeout: Duration) {
        let components = timeout.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            self?.cancel(id, token: token)
        }
    }
}
