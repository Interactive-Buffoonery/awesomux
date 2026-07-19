import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Worktree workspace projection")
struct WorktreeWorkspaceProjectionTests {
    // Fixture paths are fictional, so stub existence to true for the
    // path-matching tests below; the dedicated stale-directory test flips it.
    private let projection = WorktreeWorkspaceProjection(directoryExists: { _ in true })

    @Test("returns nil when no pane is inside the worktree")
    func noMatch() {
        #expect(
            projection.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                groups: groups(path: "/tmp/elsewhere")
            ) == nil)
    }

    @Test("matches an exact pane working directory")
    func exactMatch() throws {
        let groups = groups(path: "/tmp/worktree")
        let match = try #require(
            projection.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                groups: groups
            ))

        #expect(match.groupID == groups[0].id)
        #expect(match.sessionID == groups[0].sessions[0].id)
        #expect(match.paneID == groups[0].sessions[0].activePaneID)
    }

    @Test("matches a pane nested under the worktree")
    func nestedMatch() {
        #expect(
            projection.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/x/repo-worktrees/foo"),
                groups: groups(path: "/tmp/x/repo-worktrees/foo/Sources/App")
            ) != nil)
    }

    @Test("rejects a sibling that merely shares the string prefix")
    func siblingPrefixDoesNotMatch() {
        #expect(
            projection.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/x/repo-worktrees/foo"),
                groups: groups(path: "/tmp/x/repo-worktrees/foo-bar/sub")
            ) == nil)
    }

    @Test("remote panes never match the same textual path")
    func remotePaneDoesNotMatch() throws {
        let remote = try #require(RemoteTarget(parsing: "dev@example.com"))
        #expect(
            projection.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                groups: groups(
                    path: "/tmp/worktree",
                    executionPlan: .ssh(SSHExecution(target: remote))
                )
            ) == nil)
    }

    @Test("a matching pane whose directory no longer exists is not a live match")
    func staleDirectoryDoesNotMatch() {
        let stale = WorktreeWorkspaceProjection(directoryExists: { _ in false })
        #expect(
            stale.match(
                canonicalWorktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                groups: groups(path: "/tmp/worktree")
            ) == nil)
    }

    private func groups(
        path: String,
        executionPlan: PaneExecutionPlan = .local
    ) -> [SessionGroup] {
        [
            SessionGroup(
                name: "work",
                sessions: [
                    TerminalSession(
                        title: "workspace",
                        workingDirectory: path,
                        executionPlan: executionPlan
                    )
                ]
            )
        ]
    }
}
