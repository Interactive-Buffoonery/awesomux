import Foundation

public struct WorktreeWorkspaceMatch: Equatable, Sendable {
    public var groupID: SessionGroup.ID
    public var sessionID: TerminalSession.ID
    public var paneID: TerminalPane.ID

    public init(
        groupID: SessionGroup.ID,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        self.groupID = groupID
        self.sessionID = sessionID
        self.paneID = paneID
    }
}

public struct WorktreeWorkspaceProjection: Sendable {
    public init() {}

    public func match(
        canonicalWorktreePath: URL,
        groups: [SessionGroup]
    ) -> WorktreeWorkspaceMatch? {
        let worktreeComponents = canonicalPathComponents(canonicalWorktreePath)
        for group in groups {
            for session in group.sessions {
                for pane in session.panes where WorkspacePaneCapabilities.terminal(pane).localFileAccess {
                    let paneComponents = canonicalPathComponents(URL(fileURLWithPath: pane.workingDirectory))
                    guard paneComponents.starts(with: worktreeComponents) else { continue }
                    return WorktreeWorkspaceMatch(
                        groupID: group.id,
                        sessionID: session.id,
                        paneID: pane.id
                    )
                }
            }
        }
        return nil
    }
}
