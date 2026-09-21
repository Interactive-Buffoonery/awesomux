import AwesoMuxBridgeProtocol
import Foundation

@MainActor
final class SessionRecoveryConfirmationCenter {
    static let shared = SessionRecoveryConfirmationCenter()
    private var confirmed: Set<TerminalSessionID> = []
    private var waiters: [TerminalSessionID: (UUID, CheckedContinuation<Bool, Never>)] = [:]

    func begin(_ id: TerminalSessionID) {
        cancel(id)
        confirmed.remove(id)
    }

    func confirm(_ id: TerminalSessionID) {
        if let (_, continuation) = waiters.removeValue(forKey: id) {
            continuation.resume(returning: true)
        } else {
            confirmed.insert(id)
        }
    }

    func wait(for id: TerminalSessionID, timeout: Duration = .seconds(3)) async -> Bool {
        if confirmed.remove(id) != nil { return true }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
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
        guard let waiter = waiters[id], token == nil || waiter.0 == token else { return }
        waiters.removeValue(forKey: id)
        waiter.1.resume(returning: false)
    }
}
