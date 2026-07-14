import Foundation

/// Per-pane libghostty quit-confirmation reading. Produced from
/// `ghostty_surface_needs_confirm_quit`, whose default behavior is
/// `!cursorIsAtPrompt()`, and applied per pane in
/// `SessionStore.updateTerminalQuitConfirmationRisks`. See INT-216 / INT-504 R4.
public struct TerminalQuitConfirmationSnapshot: Sendable, Hashable {
    public let sessionID: TerminalSession.ID
    public let paneID: TerminalPane.ID
    public let needsConfirmation: Bool
    public let promptObserved: Bool
    public let liveness: ForegroundProcessLiveness

    public init(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        needsConfirmation: Bool,
        promptObserved: Bool = true,
        liveness: ForegroundProcessLiveness = .unsampled
    ) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.needsConfirmation = needsConfirmation
        self.promptObserved = promptObserved
        self.liveness = liveness
    }
}
