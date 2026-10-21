import AwesoMuxCore
import Foundation
import Testing

@Suite("Git worktree create policy")
struct GitWorktreeCreatePolicyTests {
    private let policy = GitWorktreeCreatePolicy()

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

    @Test("invoked from a linked worktree, fresh target under main's .worktrees validates clean")
    func freshTargetUnderMainValidatesCleanFromLinkedInvocationRoot() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The exact maintainer repro (round-8 smoke): Worktree Manager opened
        // FROM the linked worktree ("other-branch"), suggesting a fresh
        // sibling under MAIN's `.worktrees/` — not nested under
        // "other-branch" itself. `canonicalCommonGitDirectory` is main's real
        // `.git` (never a linked worktree's own — confirmed against real
        // git's `--git-common-dir`), which is what both the suggestion and
        // this exemption now resolve against instead of `invocationRoot`.
        let linkedContext = fixture.linkedInvocationContext()
        let prefill = policy.formTargetPathPrefill(repositoryContext: linkedContext, branchName: "can-it-have-spaces")
        #expect(prefill == fixture.worktreesDir.appendingPathComponent("can-it-have-spaces", isDirectory: true).path)

        let issues = policy.validate(
            request(linkedContext, .newBranchFromMain("can-it-have-spaces"), URL(fileURLWithPath: prefill)),
            currentWorktrees: fixture.currentWorktrees)
        #expect(issues.isEmpty)
    }

    @Test("linked worktree overlap rejects ancestor and nested targets", arguments: [false, true])
    func targetInsideOtherWorktreeStillRejectsFromLinkedInvocationRoot(nested: Bool) throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // A second, unrelated linked worktree the request is NOT invoked
        // from — the exemption is scoped to {main} ∪ {invocation root}, not
        // every non-main worktree.
        let thirdWorktree = fixture.worktreesDir.appendingPathComponent("third-branch", isDirectory: true)
        try FileManager.default.createDirectory(at: thirdWorktree, withIntermediateDirectories: true)
        let thirdRecord = GitWorktreeRecord(
            canonicalPath: thirdWorktree, headObjectID: nil, branchRef: "refs/heads/third-branch", isDetached: false,
            displayBranch: "third-branch", isMainWorktree: false, isBare: false, lockReason: nil, prunableReason: nil)

        let linkedContext = nested ? fixture.linkedInvocationContext() : fixture.context
        let insideThird = nested ? thirdWorktree.appendingPathComponent("nested", isDirectory: true) : fixture.worktreesDir
        let issues = policy.validate(
            request(linkedContext, .newBranchFromMain("x"), insideThird), currentWorktrees: fixture.currentWorktrees + [thirdRecord])
        #expect(issues.contains(.targetOverlapsWorktree(nested ? thirdWorktree : fixture.linked)))
    }

    private struct WorktreeFixture {
        let root: URL
        let context: GitRepositoryContext
        let worktreesDir: URL
        let linked: URL
        let currentWorktrees: [GitWorktreeRecord]

        /// The `GitRepositoryContext` a Worktree Manager opened FROM the
        /// linked worktree would actually see: `invocationRoot` is that
        /// worktree's own `--show-toplevel`, but `canonicalCommonGitDirectory`
        /// is STILL main's real `.git` — a linked worktree's own `.git` is a
        /// FILE pointing back at it, `--git-common-dir` never resolves to the
        /// linked worktree itself (confirmed against real git).
        func linkedInvocationContext() -> GitRepositoryContext {
            GitRepositoryContext(
                invocationRoot: linked, canonicalCommonGitDirectory: context.canonicalCommonGitDirectory,
                displayName: "other-branch")
        }
    }

    private func mainPlusLinkedFixture() throws -> WorktreeFixture {
        let root = temporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let worktreesDir = repo.appendingPathComponent(".worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        let linked = worktreesDir.appendingPathComponent("other-branch", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)

        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")
        let main = GitWorktreeRecord(
            canonicalPath: repo, headObjectID: nil, branchRef: "refs/heads/main", isDetached: false, displayBranch: "main",
            isMainWorktree: true, isBare: false, lockReason: nil, prunableReason: nil)
        let linkedRecord = GitWorktreeRecord(
            canonicalPath: linked, headObjectID: nil, branchRef: "refs/heads/other-branch", isDetached: false,
            displayBranch: "other-branch", isMainWorktree: false, isBare: false, lockReason: nil, prunableReason: nil)
        return WorktreeFixture(
            root: root, context: context, worktreesDir: worktreesDir, linked: linked, currentWorktrees: [main, linkedRecord])
    }

    private func request(_ context: GitRepositoryContext, _ mode: GitWorktreeCreateMode, _ target: URL) -> GitWorktreeCreateRequest {
        .init(repositoryContext: context, mode: mode, targetPath: target, destinationWorkspaceGroupID: UUID())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
