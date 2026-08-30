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
        case closeWorkspace

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
            case .closeWorkspace:
                String(
                    localized: "Close Workspace",
                    comment: "Destructive button on the close-workspace confirmation dialog."
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
            case .closeWorkspace:
                String(
                    localized: "Press ⌘Return to close workspace. Esc cancels.",
                    comment: "Keyboard hint line on the close-workspace confirmation dialog."
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

    /// Centralized body copy for destructive pane/workspace confirmations.
    ///
    /// - When activity is verified and the live foreground command matches the
    ///   tagged agent, names the agent and says the action will stop it.
    /// - When the state is unknown (.indeterminate), says awesoMux couldn't verify
    ///   activity and the action may stop a process.
    /// - Otherwise, gives action-specific generic activity warnings.
    static func confirmationBody(
        action: Action,
        displayTitle: String,
        agentKind: AgentKind?,
        sampledComm: String?,
        riskReason: QuitRiskReason?,
        riskyPaneCount: Int = 1
    ) -> String {
        let isVerifiedAgent: Bool = {
            guard let agentKind, agentKind != .shell, let sampledComm else {
                return false
            }
            return (riskReason == .liveAgentProcess || riskReason == .activeAgentExecution)
                && AgentPromptGate.foregroundCommandMatches(agentKind, observedCommand: sampledComm)
        }()

        if isVerifiedAgent, let agentKind {
            switch action {
            case .closePane:
                return String(
                    localized: "\(agentKind.rawValue) is running in this pane. Closing the pane will stop it.",
                    comment:
                        "Body of the close-pane confirmation dialog when a live agent process is verified. Argument is the agent name (e.g. Claude Code)."
                )
            case .restartShell:
                return String(
                    localized: "\(agentKind.rawValue) is running in this pane. Restarting the shell will stop it.",
                    comment:
                        "Body of the restart-shell confirmation dialog when a live agent process is verified. Argument is the agent name (e.g. Claude Code)."
                )
            case .closeWorkspace:
                return String(
                    localized: "\(agentKind.rawValue) is running in this workspace. Closing the workspace will stop it.",
                    comment:
                        "Body of the close-workspace confirmation dialog when a live agent process is verified in the workspace. Argument is the agent name (e.g. Claude Code)."
                )
            }
        }

        if riskReason == .indeterminate {
            switch action {
            case .closePane:
                return String(
                    localized: "awesoMux couldn’t verify whether this pane is busy. Closing it may stop a running process.",
                    comment: "Body of the close-pane confirmation dialog when pane activity is unverifiable."
                )
            case .restartShell:
                return String(
                    localized: "awesoMux couldn’t verify whether this pane is busy. Restarting the shell may stop a running process.",
                    comment: "Body of the restart-shell confirmation dialog when pane activity is unverifiable."
                )
            case .closeWorkspace:
                return String(
                    localized:
                        "awesoMux couldn’t verify whether this workspace has running activity. Closing it may stop running processes.",
                    comment: "Body of the close-workspace confirmation dialog when workspace activity is unverifiable."
                )
            }
        }

        switch action {
        case .closePane:
            return String(
                localized: "This pane has running activity. Closing the pane will stop it.",
                comment: "Body of the close-pane confirmation dialog when generic activity is running."
            )
        case .restartShell:
            if riskReason != nil {
                return String(
                    localized: "This pane has running activity. Restarting the shell will stop it.",
                    comment: "Body of the restart-shell confirmation dialog when generic activity is running."
                )
            } else {
                return String(
                    localized:
                        "Restarting the shell in \(displayTitle) ends the current session and starts a fresh one. Scrollback isn't kept.",
                    comment:
                        "Body of the restart-shell confirmation dialog when the active pane is idle. Argument is the bidi-isolated workspace title."
                )
            }
        case .closeWorkspace:
            if riskyPaneCount > 1 {
                return String(
                    localized: "This workspace has activity running in multiple panes. Closing the workspace will stop it.",
                    comment: "Body of the close-workspace confirmation dialog when multiple panes have running activity."
                )
            } else {
                return String(
                    localized: "This workspace has running activity. Closing the workspace will stop it.",
                    comment: "Body of the close-workspace confirmation dialog when generic activity is running."
                )
            }
        }
    }

    /// Legacy / convenience close-pane confirmation body helper.
    static func closePaneConfirmationBody(
        displayTitle: String,
        agentKind: AgentKind?,
        sampledComm: String? = nil,
        riskReason: QuitRiskReason?
    ) -> String {
        confirmationBody(
            action: .closePane,
            displayTitle: displayTitle,
            agentKind: agentKind,
            sampledComm: sampledComm,
            riskReason: riskReason
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
