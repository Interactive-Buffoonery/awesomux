import AwesoMuxConfig
import AwesoMuxCore
import Foundation

enum DestructivePaneActionConfirmationPolicy {
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
}
