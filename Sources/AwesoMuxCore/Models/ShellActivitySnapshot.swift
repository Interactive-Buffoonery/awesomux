import Foundation

/// Per-pane prompt-marker shell activity reading. Produced from
/// `ghostty_surface_needs_confirm_quit`, whose default behavior is
/// `!cursorIsAtPrompt()`, and OR-folded by session before presentation.
///
/// `paneID` is load-bearing, not bookkeeping: the prompt-seen trust gate is
/// keyed per pane, so a pane whose integration never emits a prompt marker
/// cannot have its permanently-busy reading "authorized" by a sibling pane
/// that did reach a prompt (see `SessionStore.updateShellActivity`).
public struct ShellActivitySnapshot: Sendable, Hashable {
    public let sessionID: TerminalSession.ID
    public let paneID: TerminalPane.ID
    public let isBusy: Bool

    public init(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        isBusy: Bool
    ) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.isBusy = isBusy
    }
}
