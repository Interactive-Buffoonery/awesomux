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
    /// Injected so tests can stub existence without touching the real
    /// filesystem; defaults to a real check so a pane whose worktree was
    /// removed externally (e.g. `git worktree remove` run outside awesoMux)
    /// is never reported as a live match on stale path text alone.
    private let directoryExists: @Sendable (URL) -> Bool

    public init(directoryExists: @escaping @Sendable (URL) -> Bool = Self.realDirectoryExists) {
        self.directoryExists = directoryExists
    }

    public func match(
        canonicalWorktreePath: URL,
        groups: [SessionGroup]
    ) -> WorktreeWorkspaceMatch? {
        let worktreeComponents = canonicalPathComponents(canonicalWorktreePath)
        for group in groups {
            for session in group.sessions {
                for pane in session.panes where WorkspacePaneCapabilities.terminal(pane).localFileAccess {
                    let paneURL = URL(fileURLWithPath: pane.workingDirectory)
                    let paneComponents = canonicalPathComponents(paneURL)
                    guard paneComponents.starts(with: worktreeComponents), directoryExists(paneURL) else {
                        continue
                    }
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

    public static func realDirectoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
