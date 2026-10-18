import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Worktree workspace projection")
struct WorktreeWorkspaceProjectionTests {
    // Fixture paths are fictional, so stub existence to true for the
    // path-matching tests below; the dedicated stale-directory test flips it.
    private let projection = WorktreeWorkspaceProjection(directoryExists: { _ in true })

    @Test(arguments: [
        ("/tmp/worktree", "/tmp/elsewhere", false, true, false),
        ("/tmp/worktree", "/tmp/worktree", false, true, true),
        ("/tmp/x/repo-worktrees/foo", "/tmp/x/repo-worktrees/foo/Sources/App", false, true, true),
        ("/tmp/x/repo-worktrees/foo", "/tmp/x/repo-worktrees/foo-bar/sub", false, true, false),
        ("/tmp/worktree", "/tmp/worktree", true, true, false),
        ("/tmp/worktree", "/tmp/worktree", false, false, false),
    ])
    func matchingPane(worktree: String, path: String, remote: Bool, exists: Bool, expected: Bool) throws {
        let plan: PaneExecutionPlan = remote ? .ssh(SSHExecution(target: try #require(RemoteTarget(parsing: "dev@example.com")))) : .local
        let groups = groups(path: path, executionPlan: plan)
        let projection = WorktreeWorkspaceProjection(directoryExists: { _ in exists })
        let match = projection.match(worktreeComponents: canonicalPathComponents(URL(fileURLWithPath: worktree)), groups: groups)
        #expect((match != nil) == expected)
        if expected {
            #expect(match?.groupID == groups[0].id)
            #expect(match?.sessionID == groups[0].sessions[0].id)
            #expect(match?.paneID == groups[0].sessions[0].activePaneID)
        }
    }

    @Test("the most-specific worktree owns a nested pane")
    func mostSpecificWorktreeWins() throws {
        let main = URL(fileURLWithPath: "/tmp/repo")
        let linked = URL(fileURLWithPath: "/tmp/repo/.worktrees/feature")
        let groups = groups(path: "/tmp/repo/.worktrees/feature/Sources/App")

        #expect(
            projection.match(
                worktreeComponents: canonicalPathComponents(main),
                canonicalWorktreePathComponents: [main, linked].map(canonicalPathComponents),
                groups: groups
            ) == nil)
        #expect(
            projection.match(
                worktreeComponents: canonicalPathComponents(linked),
                canonicalWorktreePathComponents: [main, linked].map(canonicalPathComponents),
                groups: groups
            ) != nil)
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
