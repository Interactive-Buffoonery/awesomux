import AwesoMuxBridgeProtocol
import AwesoMuxCore

/// Reference semantics are load-bearing. `CommandBridgeEnactor.respawnLedger` is a
/// computed property whose read-modify-write (`recordAttach`, `recordRespawnAttempt`,
/// `refillBudget`) mutates `self.respawnLedger` in place through this shared record.
/// Making this a `struct` would silently turn every budget mutation into a write to a
/// throwaway copy — the `.error` crash-loop cap would become unreachable and a crashing
/// daemon would respawn forever.
@MainActor
final class CommandBridgeRecoveryRecord {
    let terminalSessionID: TerminalSessionID
    var respawnLedger: CommandBridgeRespawnLedger
    /// Captured once before the first spawn, retained across failed attach heals.
    var hadEstablishedSessionAtFirstAttach: Bool?

    init(
        terminalSessionID: TerminalSessionID,
        respawnLedger: CommandBridgeRespawnLedger = CommandBridgeRespawnLedger()
    ) {
        self.terminalSessionID = terminalSessionID
        self.respawnLedger = respawnLedger
    }
}
