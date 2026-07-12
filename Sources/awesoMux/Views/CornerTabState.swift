import AwesoMuxCore
import DesignSystem

/// The minimized corner tab has two honest states: an active session (command,
/// directory, live status) or an ended session whose shell exited while
/// minimized. Ended renders a distinct label so the tab does not masquerade as
/// idle; clicking it restores to the "session unavailable" placeholder.
enum CornerTabState: Equatable {
    case active(command: String, directory: String, status: AwState)
    case ended(directory: String)

    @MainActor
    static func resolve(
        session: TerminalSession?,
        fallbackCommand: String,
        fallbackDirectory: String
    ) -> CornerTabState {
        guard let session else { return .ended(directory: fallbackDirectory) }
        // An exited foreground process in the active pane means the shell is
        // gone even though the session record is still around.
        if session.activePane?.foregroundProcessLiveness == .exited {
            return .ended(directory: session.workingDirectory)
        }
        let command: String
        if session.activeAgentKind != .shell {
            command = session.activeAgentKind.shortName
        } else if let title = session.activePane?.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty {
            command = title
        } else {
            command = fallbackCommand
        }
        return .active(
            command: command,
            directory: session.workingDirectory,
            status: session.effectiveChromeState.awState
        )
    }
}
