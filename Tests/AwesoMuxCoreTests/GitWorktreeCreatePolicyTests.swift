import AwesoMuxCore
import Foundation
import Testing

@Suite("Git worktree create policy")
struct GitWorktreeCreatePolicyTests {
    private let policy = GitWorktreeCreatePolicy()

    @Test("suggestion is available only when the .worktrees container exists")
    func suggestionRequiresExistingContainer() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")

        #expect(policy.suggestedTargetPath(repositoryContext: context, branchName: "feature/foo") == nil)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".worktrees"), withIntermediateDirectories: true)
        let expected = repo.appendingPathComponent(".worktrees", isDirectory: true).appendingPathComponent("feature-foo", isDirectory: true)
        #expect(policy.suggestedTargetPath(repositoryContext: context, branchName: "feature/foo")?.path == expected.path)
    }

    @Test("candidate target path is available even without the .worktrees container, pinned for a named branch")
    func candidateIgnoresContainerExistence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")

        // No ".worktrees" container exists yet — the gated suggestion is nil,
        // but the candidate (used as the form's placeholder hint) still
        // resolves, pinned to the exact path (round-4 smoke: "I still don't
        // get what the pre-filled text is" — it must read as an obvious,
        // full, real path, not just "hasSuffix" close-enough).
        #expect(policy.suggestedTargetPath(repositoryContext: context, branchName: "test-branch") == nil)
        let expected = repo.appendingPathComponent(".worktrees", isDirectory: true).appendingPathComponent("test-branch", isDirectory: true)
        #expect(policy.candidateTargetPath(repositoryContext: context, branchName: "test-branch")?.path == expected.path)
    }

    @Test("sanitized path component keeps internal and trailing hyphens from a branch name")
    func sanitizationKeepsHyphens() {
        // Regression for round-4 smoke: trimming "-" like ".", " " truncated
        // a live-typed "test-" (before "branch" lands) down to "test".
        #expect(policy.sanitizedPathComponent("test-branch") == "test-branch")
        #expect(policy.sanitizedPathComponent("test-") == "test-")
        #expect(policy.sanitizedPathComponent("-leading") == "-leading")
        // Dots and spaces still trim — a leaf named "." or with stray
        // whitespace is the actual hazard this trim exists to avoid.
        #expect(policy.sanitizedPathComponent(" test-branch. ") == "test-branch")
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

    @Test("a typed absolute path with a real, empty, writable target validates clean")
    func typedAbsolutePathValidatesClean() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: root, canonicalCommonGitDirectory: root.appendingPathComponent(".git"), displayName: "repo")

        // Mirrors the form's own construction: `URL(fileURLWithPath:)` on a
        // user-typed absolute string, same as `WorktreeCreateForm.submit()`.
        let typed = root.appendingPathComponent("new-worktree").path
        let request = GitWorktreeCreateRequest(
            repositoryContext: context, mode: .newBranchFromHEAD("test-branch"),
            targetPath: URL(fileURLWithPath: typed), destinationWorkspaceGroupID: UUID())

        let issues = policy.validate(request, currentWorktrees: [])
        #expect(!issues.contains(.targetPathMustBeAbsolute))
        #expect(issues.isEmpty)
    }

    @Test("a fresh .worktrees/<new-name> target validates clean with linked worktrees present")
    func freshWorktreesTargetValidatesCleanAlongsideLinkedWorktrees() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The suggestion's own convention — nested under the MAIN worktree —
        // used to always "overlap" the main entry itself (round-5 smoke: the
        // overlap check iterated every record, main included).
        let fresh = fixture.worktreesDir.appendingPathComponent("brand-new-name", isDirectory: true)
        let issues = policy.validate(
            request(fixture.context, .newBranchFromHEAD("brand-new-name"), fresh), currentWorktrees: fixture.currentWorktrees)
        #expect(issues.isEmpty)
    }

    @Test("a target inside a LINKED worktree still rejects")
    func targetInsideLinkedWorktreeRejects() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let insideLinked = fixture.linked.appendingPathComponent("nested", isDirectory: true)
        let issues = policy.validate(
            request(fixture.context, .newBranchFromHEAD("x"), insideLinked), currentWorktrees: fixture.currentWorktrees)
        #expect(issues.contains(.targetOverlapsWorktree(fixture.linked)))
    }

    @Test("a target containing a LINKED worktree still rejects")
    func targetContainingLinkedWorktreeRejects() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // `.worktrees/` itself is an ancestor of the linked worktree below it.
        let issues = policy.validate(
            request(fixture.context, .newBranchFromHEAD("x"), fixture.worktreesDir), currentWorktrees: fixture.currentWorktrees)
        #expect(issues.contains(.targetOverlapsWorktree(fixture.linked)))
    }

    private func mainPlusLinkedFixture() throws -> (
        root: URL, context: GitRepositoryContext, worktreesDir: URL, linked: URL, currentWorktrees: [GitWorktreeRecord]
    ) {
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
        return (root, context, worktreesDir, linked, [main, linkedRecord])
    }

    private func request(_ context: GitRepositoryContext, _ mode: GitWorktreeCreateMode, _ target: URL) -> GitWorktreeCreateRequest {
        .init(repositoryContext: context, mode: mode, targetPath: target, destinationWorkspaceGroupID: UUID())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
