import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

public extension ShellActivitySnapshot {
    static func active(_ session: TerminalSession, isBusy: Bool) -> ShellActivitySnapshot {
        ShellActivitySnapshot(sessionID: session.id, paneID: session.activePaneID, isBusy: isBusy)
    }
}

public extension TerminalQuitConfirmationSnapshot {
    static func active(
        _ session: TerminalSession,
        needsConfirmation: Bool,
        liveness: ForegroundProcessLiveness = .unsampled
    ) -> TerminalQuitConfirmationSnapshot {
        TerminalQuitConfirmationSnapshot(
            sessionID: session.id,
            paneID: session.activePaneID,
            needsConfirmation: needsConfirmation,
            liveness: liveness
        )
    }
}

public extension TerminalSession {
    var agentKind: AgentKind { activePane?.agentKind ?? .shell }
    var agentExecutionState: AgentExecutionState { activePane?.agentExecutionState ?? .idle }
    var attentionReason: AttentionReason? { activePane?.attentionReason }
    var shellActivity: ShellActivity { activePane?.shellActivity ?? .idle }
    var needsTerminalQuitConfirmation: Bool { activePane?.needsTerminalQuitConfirmation ?? false }
    var lastAgentStateChangeAt: Date { activePane?.lastAgentStateChangeAt ?? Date() }
    static var staleAgentActivityThreshold: TimeInterval { TerminalPane.staleAgentActivityThreshold }
}
