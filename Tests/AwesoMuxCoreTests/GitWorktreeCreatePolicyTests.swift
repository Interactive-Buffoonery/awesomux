import AwesoMuxCore
import Foundation
import Testing

@Suite("Git worktree create policy")
struct GitWorktreeCreatePolicyTests {
    private let policy = GitWorktreeCreatePolicy()

    @Test("suggestion is available only when the sibling container exists")
    func suggestionRequiresExistingContainer() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")

        #expect(policy.suggestedTargetPath(repositoryContext: context, branchName: "feature/foo") == nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo-worktrees"), withIntermediateDirectories: true)
        #expect(
            policy.suggestedTargetPath(repositoryContext: context, branchName: "feature/foo")?.path.hasSuffix("repo-worktrees/feature-foo")
                == true)
    }

    @Test("validation covers absolute parent target overlap and blank branch rules")
    func validationRules() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: root, canonicalCommonGitDirectory: root.appendingPathComponent(".git"), displayName: "repo")
        let record = GitWorktreeRecord(
            canonicalPath: existing, headObjectID: nil, branchRef: nil, isDetached: true, displayBranch: "detached", isMainWorktree: false,
            isBare: false, lockReason: nil, prunableReason: nil)

        let relative = GitWorktreeCreateRequest(
            repositoryContext: context, mode: .existingBranch(" "), targetPath: URL(string: "relative")!,
            destinationWorkspaceGroupID: UUID())
        #expect(policy.validate(relative, currentWorktrees: []).contains(.targetPathMustBeAbsolute))
        #expect(policy.validate(relative, currentWorktrees: []).contains(.blankBranchName))

        let missingParent = request(context, .existingBranch("main"), root.appendingPathComponent("missing/target"))
        #expect(policy.validate(missingParent, currentWorktrees: []).contains(.parentDirectoryMissing))
        let existingTarget = request(context, .existingBranch("main"), existing)
        #expect(policy.validate(existingTarget, currentWorktrees: []).contains(.targetAlreadyExists))
        let nested = request(context, .existingBranch("main"), existing.appendingPathComponent("nested"))
        #expect(policy.validate(nested, currentWorktrees: [record]).contains(.targetOverlapsWorktree(existing)))

        let prefixOnly = root.appendingPathComponent("existing-other")
        #expect(
            !policy.validate(request(context, .existingBranch("main"), prefixOnly), currentWorktrees: [record]).contains(
                .targetOverlapsWorktree(existing)))
    }

    private func request(_ context: GitRepositoryContext, _ mode: GitWorktreeCreateMode, _ target: URL) -> GitWorktreeCreateRequest {
        .init(repositoryContext: context, mode: mode, targetPath: target, destinationWorkspaceGroupID: UUID())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
