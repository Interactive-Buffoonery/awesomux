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

    @Test("form pre-fill never diverges from the visible candidate, even before .worktrees exists")
    func formPrefillNeverDivergesFromCandidate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")

        // No ".worktrees" container yet — the gated `suggestedTargetPath` is
        // nil, but the form's bound value must still match what it DISPLAYS
        // (the candidate), not fall back to "" — an empty bound value reads
        // as absent to `submit()`'s `hasPrefix("/")` check even while a
        // full, absolute-looking path sits in the field (INT-857 round-7
        // smoke: "Target path must be absolute" despite a visibly absolute
        // path).
        let prefill = policy.formTargetPathPrefill(repositoryContext: context, branchName: "newest-branch")
        let candidate = policy.candidateTargetPath(repositoryContext: context, branchName: "newest-branch")?.path
        #expect(prefill == candidate)
        #expect(prefill.hasPrefix("/"))

        // Once the container exists, the gated suggestion and the candidate
        // agree anyway — the prefill still matches both.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".worktrees"), withIntermediateDirectories: true)
        let confirmedPrefill = policy.formTargetPathPrefill(repositoryContext: context, branchName: "newest-branch")
        #expect(confirmedPrefill == candidate)
    }

    @Test("form pre-fill recomputes per branch name")
    func formPrefillRecomputesOnBranchNameChange() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let context = GitRepositoryContext(
            invocationRoot: repo, canonicalCommonGitDirectory: repo.appendingPathComponent(".git"), displayName: "repo")

        let first = policy.formTargetPathPrefill(repositoryContext: context, branchName: "new-branch")
        let second = policy.formTargetPathPrefill(repositoryContext: context, branchName: "newest-branch")
        #expect(first != second)
        #expect(first.hasSuffix("new-branch"))
        #expect(second.hasSuffix("newest-branch"))
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

    @Test("a fresh .worktrees/<new-name> nested under a LINKED invocation root validates clean")
    func freshWorktreesTargetValidatesCleanFromLinkedInvocationRoot() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Opening Worktree Manager FROM the linked worktree ("other-branch")
        // and creating a new one nests `.worktrees/` under THAT worktree, not
        // main. Only `isMainWorktree` was ever exempted from the overlap
        // check, so this genuinely git-allowed nesting always "overlapped"
        // the linked worktree it's standing in (INT-857 round-7 smoke).
        let linkedContext = GitRepositoryContext(
            invocationRoot: fixture.linked, canonicalCommonGitDirectory: fixture.linked.appendingPathComponent(".git"),
            displayName: "other-branch")
        let linkedWorktreesDir = fixture.linked.appendingPathComponent(".worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedWorktreesDir, withIntermediateDirectories: true)
        let target = linkedWorktreesDir.appendingPathComponent("brand-new-name", isDirectory: true)
        let issues = policy.validate(
            request(linkedContext, .newBranchFromHEAD("brand-new-name"), target), currentWorktrees: fixture.currentWorktrees)
        #expect(issues.isEmpty)
    }

    @Test("a target inside a DIFFERENT linked worktree still rejects from a LINKED invocation root")
    func targetInsideOtherWorktreeStillRejectsFromLinkedInvocationRoot() throws {
        let fixture = try mainPlusLinkedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // A second, unrelated linked worktree the request is NOT invoked
        // from — the exemption is scoped to the current invocation root, not
        // every non-main worktree.
        let thirdWorktree = fixture.worktreesDir.appendingPathComponent("third-branch", isDirectory: true)
        try FileManager.default.createDirectory(at: thirdWorktree, withIntermediateDirectories: true)
        let thirdRecord = GitWorktreeRecord(
            canonicalPath: thirdWorktree, headObjectID: nil, branchRef: "refs/heads/third-branch", isDetached: false,
            displayBranch: "third-branch", isMainWorktree: false, isBare: false, lockReason: nil, prunableReason: nil)

        let linkedContext = GitRepositoryContext(
            invocationRoot: fixture.linked, canonicalCommonGitDirectory: fixture.linked.appendingPathComponent(".git"),
            displayName: "other-branch")
        let insideThird = thirdWorktree.appendingPathComponent("nested", isDirectory: true)
        let issues = policy.validate(
            request(linkedContext, .newBranchFromHEAD("x"), insideThird), currentWorktrees: fixture.currentWorktrees + [thirdRecord])
        #expect(issues.contains(.targetOverlapsWorktree(thirdWorktree)))
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
