import Foundation

public enum PaneCloseResult: Hashable, Sendable {
    case pane(TerminalPane.ID)
    case session(TerminalSession.ID, paneIDs: [TerminalPane.ID])
}
