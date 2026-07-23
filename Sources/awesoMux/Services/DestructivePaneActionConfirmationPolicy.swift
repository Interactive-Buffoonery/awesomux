import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

enum DestructivePaneActionConfirmationPolicy {
    enum ConfirmedCloseAction: Equatable {
        case closePane
        case closeWorkspace
        case alreadyClosed
    }

    enum Action: Equatable {
        case closePane
        case restartShell

        var destructiveButtonTitle: String {
            switch self {
            case .closePane:
                String(
                    localized: "Close Pane",
                    comment: "Destructive button on the close-pane confirmation dialog."
                )
            case .restartShell:
                String(
                    localized: "Restart Shell",
                    comment: "Destructive button on the restart-shell confirmation dialog."
                )
            }
        }

        var keyboardHint: String {
            switch self {
            case .closePane:
                String(
                    localized: "Press ⌘Return to close pane. Esc cancels.",
                    comment: "Keyboard hint line on the close-pane confirmation dialog."
                )
            case .restartShell:
                String(
                    localized: "Press ⌘Return to restart shell. Esc cancels.",
                    comment: "Keyboard hint line on the restart-shell confirmation dialog."
                )
            }
        }
    }

    enum Decision: Equatable {
        case proceedWithoutPrompt(Action)
        case prompt(Action)
        case unavailable
    }

    static func decision(
        session: TerminalSession?,
        workspaces: WorkspaceConfig,
        now: Date = Date()
    ) -> Decision {
        guard let session, let activePane = session.activePane else {
            return .unavailable
        }

        // Single-pane ⌘W is a workspace close, not a pane action — the caller
        // (closeActivePane) routes it to closeWorkspace(_:) before consulting
        // this policy. Landed atomically with that routing; if you are reading
        // this without the closeActivePane early-branch, something reverted.
        guard !session.layout.isSinglePane else {
            return .unavailable
        }

        let action: Action = .closePane
        guard activePane.isCloseRisk(at: now) else {
            return .proceedWithoutPrompt(action)
        }
        guard workspaces.confirmDestructivePaneActionWithRunningAgent else {
            return .proceedWithoutPrompt(action)
        }
        return .prompt(action)
    }

    /// Body copy for the close-pane confirmation. When the risk is the pane's
    /// own live agent process, name it — "activity that will be interrupted"
    /// oversells an agent TUI idling at its input box (issue #190, mechanism 1).
    /// Every other risk reason keeps the generic phrasing: for those the live
    /// process is either not an agent or not actually verified.
    static func closePaneConfirmationBody(
        displayTitle: String,
        agentKind: AgentKind?,
        riskReason: QuitRiskReason?
    ) -> String {
        // ponytail: names the pane's *tagged* agent, which can lag reality —
        // an exited agent whose tag hasn't reset yet makes this claim about
        // whatever runs now. Gate on a live comm match if that bites in the field.
        if riskReason == .liveAgentProcess, let agentKind, agentKind != .shell {
            return String(
                localized:
                    "\(agentKind.rawValue) is running in the active pane in \(displayTitle). Closing the pane will terminate \(agentKind.rawValue).",
                comment:
                    "Body of the close-pane confirmation dialog when a live agent process is the risk. First and third arguments are the agent name (e.g. Claude Code), second is the bidi-isolated workspace title."
            )
        }
        return String(
            localized:
                "The active pane in \(displayTitle) has activity that will be interrupted. Closing the pane will terminate the running process.",
            comment: "Body of the close-pane confirmation dialog. Argument is the bidi-isolated workspace title."
        )
    }

    static func confirmedCloseAction(
        session: TerminalSession?,
        targetPaneID: TerminalPane.ID
    ) -> ConfirmedCloseAction {
        guard let session,
            session.layout.pane(id: targetPaneID) != nil
        else {
            return .alreadyClosed
        }
        return session.layout.isSinglePane ? .closeWorkspace : .closePane
    }
}
