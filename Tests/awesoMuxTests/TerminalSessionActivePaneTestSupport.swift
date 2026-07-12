import Foundation
@testable import AwesoMuxCore

/// Test-only convenience mirroring the AwesoMuxCoreTests helper: read the former
/// session-level agent fields off the ACTIVE pane. Post INT-504 these live on
/// `TerminalPane`; single-pane test sessions read them here exactly as before.
extension TerminalSession {
    var agentKind: AgentKind {
        activePane?.agentKind ?? .shell
    }

    var agentExecutionState: AgentExecutionState {
        activePane?.agentExecutionState ?? .idle
    }

    var attentionReason: AttentionReason? {
        activePane?.attentionReason
    }

    var shellActivity: ShellActivity {
        activePane?.shellActivity ?? .idle
    }

    var needsTerminalQuitConfirmation: Bool {
        activePane?.needsTerminalQuitConfirmation ?? false
    }

    var lastAgentStateChangeAt: Date {
        activePane?.lastAgentStateChangeAt ?? Date()
    }

    static var staleAgentActivityThreshold: TimeInterval {
        TerminalPane.staleAgentActivityThreshold
    }
}
