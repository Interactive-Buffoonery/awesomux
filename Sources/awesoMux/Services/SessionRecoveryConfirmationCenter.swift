import AwesoMuxBridgeProtocol
import Foundation

@MainActor
final class SessionRecoveryConfirmationCenter {
    static let shared = SessionRecoveryConfirmationCenter()
    private var confirmed: Set<TerminalSessionID> = []
    private var waiters: [TerminalSessionID: (UUID, CheckedContinuation<Bool, Never>)] = [:]

    func begin(_ id: TerminalSessionID) {
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
        return await withCheckedContinuation { continuation in
            waiters[id] = (token, continuation)
            let components = timeout.components
            let seconds =
                Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                guard let self, waiters[id]?.0 == token,
                    let (_, continuation) = waiters.removeValue(forKey: id)
                else { return }
                continuation.resume(returning: false)
            }
        }
    }
}
