import AwesoMuxBridgeProtocol
import Foundation

@MainActor
final class SessionRecoveryConfirmationCenter {
    static let shared = SessionRecoveryConfirmationCenter()
    private var confirmed: Set<TerminalSessionID> = []

    func begin(_ id: TerminalSessionID) {
        confirmed.remove(id)
    }

    func confirm(_ id: TerminalSessionID) {
        confirmed.insert(id)
    }

    func wait(for id: TerminalSessionID, timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if confirmed.remove(id) != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return confirmed.remove(id) != nil
    }
}
