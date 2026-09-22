import AwesoMuxBridgeProtocol
import Foundation

@MainActor
final class SessionRecoveryConfirmationCenter {
    static let shared = SessionRecoveryConfirmationCenter()
    private var confirmed: Set<TerminalSessionID> = []
    private var waiters: [TerminalSessionID: (UUID, CheckedContinuation<Bool, Never>)] = [:]
    private var expectations: [TerminalSessionID: (daemonPID: Int32?, createdEpoch: Int)] = [:]

    func begin(_ id: TerminalSessionID, daemonPID: Int32?, createdEpoch: Int) {
        cancel(id)
        confirmed.remove(id)
        expectations[id] = (daemonPID, createdEpoch)
    }

    func confirm(_ id: TerminalSessionID, daemonPID: Int, createdEpoch: Int) {
        guard let expected = expectations[id], expected.createdEpoch == createdEpoch,
            expected.daemonPID.map({ Int($0) == daemonPID }) ?? true
        else {
            cancel(id)
            return
        }
        expectations.removeValue(forKey: id)
        if let (_, continuation) = waiters.removeValue(forKey: id) {
            continuation.resume(returning: true)
        } else {
            confirmed.insert(id)
        }
    }

    func wait(for id: TerminalSessionID, timeout: Duration = .seconds(3)) async -> Bool {
        if confirmed.remove(id) != nil { return true }
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
                if let (_, previous) = waiters.removeValue(forKey: id) {
                    previous.resume(returning: false)
                }
                waiters[id] = (token, continuation)
                let components = timeout.components
                let seconds =
                    Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                    self?.cancel(id, token: token)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id, token: token) }
        }
    }

    func cancel(_ id: TerminalSessionID, token: UUID? = nil) {
        guard let waiter = waiters[id] else {
            if token == nil { expectations.removeValue(forKey: id) }
            return
        }
        guard token == nil || waiter.0 == token else { return }
        waiters.removeValue(forKey: id)
        expectations.removeValue(forKey: id)
        waiter.1.resume(returning: false)
    }
}
