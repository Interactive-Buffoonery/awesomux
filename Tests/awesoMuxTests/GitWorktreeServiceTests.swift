import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Git worktree service")
struct GitWorktreeServiceTests {
    @Test("branch listing uses exact fixed argv")
    func branchListing() async {
        let context = repositoryContext()
        let runner = StubLocalGitRunner(
            outcomes: [.success(Data("refs/heads/main\nrefs/heads/feature/foo\n".utf8))])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: StubLocalGitRunner(outcomes: validationOutcomes(for: context))), runner: runner)
        #expect(await service.branches(in: context) == .success(["main", "feature/foo"]))
        #expect(
            runner.invocations == [
                .init(arguments: ["for-each-ref", "refs/heads", "--format=%(refname)"], directory: context.invocationRoot)
            ])
    }

    @Test("a branch sharing its name with a tag is never mistaken for the tag's disambiguated form")
    func branchListingIgnoresNonHeadsAmbiguousLines() async {
        // `for-each-ref refs/heads --format=%(refname:short)` would print
        // `heads/foo` (not `foo`) for a branch named `foo` when a tag `foo`
        // also exists — reproduced against real git while investigating this
        // fix. Requesting the full refname and stripping our own known
        // `refs/heads/` prefix sidesteps that disambiguation entirely, so
        // simulate the full-refname output directly here rather than the
        // ambiguous short form.
        let context = repositoryContext()
        let runner = StubLocalGitRunner(outcomes: [.success(Data("refs/heads/foo\n".utf8))])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: StubLocalGitRunner(outcomes: validationOutcomes(for: context))), runner: runner)
        #expect(await service.branches(in: context) == .success(["foo"]))
    }

    @Test(arguments: [
        (false, ["worktree", "add", "/tmp/awesomux-phase3-target", "refs/heads/feature/foo"]),
        (true, ["worktree", "add", "-b", "feature/foo", "/tmp/awesomux-phase3-target", "HEAD"]),
    ])
    func createUsesExactArgv(newBranch: Bool, expected: [String]) async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(
            // newBranch mode adds a branch-existence snapshot before running
            // git (validateNewBranchName + the new before/after branches()
            // check), each re-validating identity: +2 rounds over existing-branch.
            outcomes: Array(repeating: validationOutcomes(for: context), count: newBranch ? 5 : 3).flatMap { $0 })
        let before = Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)
        let after = Data("worktree /tmp/awesomux-phase3-target\0HEAD def\0branch refs/heads/feature/foo\0\0".utf8)
        var outcomes: [BoundedCommandResult] = [.success(before)]
        if newBranch {
            outcomes.append(.success(Data()))  // check-ref-format
            outcomes.append(.success(Data("refs/heads/main\n".utf8)))  // before-snapshot for-each-ref: branch absent
        }
        outcomes.append(.success(Data()))
        outcomes.append(.success(after))
        let runner = StubLocalGitRunner(outcomes: outcomes)
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)
        let mode: GitWorktreeCreateMode = newBranch ? .newBranchFromHEAD("feature/foo") : .existingBranch("feature/foo")
        let outcome = await service.create(
            .init(
                repositoryContext: context, mode: mode, targetPath: URL(fileURLWithPath: "/tmp/awesomux-phase3-target"),
                destinationWorkspaceGroupID: UUID()))
        guard case .success = outcome else { Issue.record("Expected success, got \(outcome)"); return }
        #expect(runner.invocations.contains(.init(arguments: expected, directory: context.invocationRoot)))
    }

    @Test("an existing leading-dash branch is passed as a full ref")
    func leadingDashExistingBranchIsNotTreatedAsAFlag() async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(
            outcomes: Array(repeating: validationOutcomes(for: context), count: 3).flatMap { $0 })
        let runner = StubLocalGitRunner(outcomes: [
            .success(Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)),
            .success(Data()),
            .success(Data("worktree /tmp/awesomux-leading-dash\0HEAD def\0branch refs/heads/--detach\0\0".utf8)),
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)

        let outcome = await service.create(
            .init(
                repositoryContext: context,
                mode: .existingBranch("--detach"),
                targetPath: URL(fileURLWithPath: "/tmp/awesomux-leading-dash"),
                destinationWorkspaceGroupID: UUID()
            ))

        guard case .success(let record) = outcome else {
            Issue.record("Expected leading-dash branch checkout, got \(outcome)")
            return
        }
        #expect(record.branchRef == "refs/heads/--detach")
        #expect(
            runner.invocations.contains(
                .init(
                    arguments: ["worktree", "add", "/tmp/awesomux-leading-dash", "refs/heads/--detach"],
                    directory: context.invocationRoot)))
    }

    @Test("non-zero create reconciles an actually-created worktree as success")
    func nonZeroReconcilesSuccess() async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(outcomes: Array(repeating: validationOutcomes(for: context), count: 3).flatMap { $0 })
        let runner = StubLocalGitRunner(outcomes: [
            .success(Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)),
            .nonZeroExit(9),
            .success(Data("worktree /tmp/awesomux-phase3-target\0HEAD def\0branch refs/heads/feature/foo\0\0".utf8)),
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)
        let outcome = await service.create(
            .init(
                repositoryContext: context, mode: .existingBranch("feature/foo"),
                targetPath: URL(fileURLWithPath: "/tmp/awesomux-phase3-target"), destinationWorkspaceGroupID: UUID()))
        guard case .success = outcome else { Issue.record("Expected reconciled success"); return }
    }

    @Test("a new-branch name that already existed before the call is a clean failure, not a partial")
    func preexistingNewBranchNameIsNotMisreportedAsPartial() async {
        let context = repositoryContext()
        // Same shape as branchOnlyPartial, but the before-snapshot for-each-ref
        // already lists the requested name: git's `-b` refusal is expected
        // (the branch already existed), so this must resolve to a clean
        // failure, not "branch created without worktree" for a branch this
        // call never touched.
        let validation = StubLocalGitRunner(outcomes: Array(repeating: validationOutcomes(for: context), count: 5).flatMap { $0 })
        let emptyList = Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)
        let runner = StubLocalGitRunner(outcomes: [
            .success(emptyList),  // list-before
            .success(Data()),  // check-ref-format
            .success(Data("refs/heads/main\nrefs/heads/feature/foo\n".utf8)),  // before-snapshot: branch ALREADY exists
            .nonZeroExit(128),  // worktree add -b refuses: branch exists
            .success(emptyList),  // list-after: target still not a worktree
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)
        let outcome = await service.create(
            .init(
                repositoryContext: context, mode: .newBranchFromHEAD("feature/foo"),
                targetPath: URL(fileURLWithPath: "/tmp/awesomux-phase3-target"), destinationWorkspaceGroupID: UUID()))
        #expect(outcome == .failure(.nonZeroExit(128)))
    }

    @Test("post-create reconciliation requires the branch ref to match, not just the path")
    func reconciliationRequiresMatchingBranchRef() async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(outcomes: Array(repeating: validationOutcomes(for: context), count: 3).flatMap { $0 })
        // A concurrent external `worktree add` occupies the exact requested
        // path with a DIFFERENT branch just as this call's command fails —
        // the path alone must not be mistaken for this call's own result.
        let wrongBranchAtPath = Data(
            "worktree /repo\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/awesomux-phase3-target\0HEAD def\0branch refs/heads/someone-elses-branch\0\0"
                .utf8)
        let runner = StubLocalGitRunner(outcomes: [
            .success(Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)),  // list-before
            .nonZeroExit(1),  // worktree add fails
            .success(wrongBranchAtPath),  // list-after: same path, wrong branch
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)
        let outcome = await service.create(
            .init(
                repositoryContext: context, mode: .existingBranch("feature/foo"),
                targetPath: URL(fileURLWithPath: "/tmp/awesomux-phase3-target"), destinationWorkspaceGroupID: UUID()))
        #expect(outcome == .failure(.nonZeroExit(1)))
    }

    @Test("a target already present in the baseline cannot reconcile as a new success")
    func reconciliationRejectsBaselineWorktreeAtTarget() async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(
            outcomes: Array(repeating: validationOutcomes(for: context), count: 2).flatMap { $0 })
        let occupiedPath = URL(fileURLWithPath: "/tmp/awesomux-preexisting-worktree")
        let runner = StubLocalGitRunner(outcomes: [
            .success(
                Data(
                    "worktree /repo\0HEAD abc\0branch refs/heads/main\0\0worktree \(occupiedPath.path)\0HEAD def\0branch refs/heads/unrelated\0\0"
                        .utf8))
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)

        let outcome = await service.create(
            .init(
                repositoryContext: context,
                mode: .existingBranch("feature/foo"),
                targetPath: occupiedPath,
                destinationWorkspaceGroupID: UUID()
            ))

        guard case .failure(.invalidRequest(let issues)) = outcome else {
            Issue.record("Expected occupied baseline target to fail, got \(outcome)")
            return
        }
        #expect(issues.contains(.targetOverlapsWorktree(occupiedPath)))
        #expect(runner.invocations.count == 1)
    }

    @Test("branch-only mutation is distinct from clean failure")
    func branchOnlyPartial() async {
        let context = repositoryContext()
        // 6 rounds: create's own validateIdentity, list-before, validateNewBranchName,
        // the new before-snapshot branches(), list-after, and the final
        // branch-only-check branches() — each re-validates repository identity.
        let validation = StubLocalGitRunner(outcomes: Array(repeating: validationOutcomes(for: context), count: 6).flatMap { $0 })
        let emptyList = Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)
        let runner = StubLocalGitRunner(outcomes: [
            .success(emptyList),  // list-before
            .success(Data()),  // check-ref-format
            .success(Data("refs/heads/main\n".utf8)),  // before-snapshot for-each-ref: branch absent
            .nonZeroExit(4),  // worktree add fails
            .success(emptyList),  // list-after: target still not a worktree
            .success(Data("refs/heads/main\nrefs/heads/feature/foo\n".utf8)),  // final branches() check: branch now exists
        ])
        let service = GitWorktreeService(locator: LocalGitRepositoryLocator(runner: validation), runner: runner)
        let outcome = await service.create(
            .init(
                repositoryContext: context, mode: .newBranchFromHEAD("feature/foo"),
                targetPath: URL(fileURLWithPath: "/tmp/awesomux-phase3-target"), destinationWorkspaceGroupID: UUID()))
        #expect(outcome == .branchCreatedWithoutWorktree(branchName: "feature/foo", diagnostic: .nonZeroExit(4)))
    }
    @Test("successful listing uses the exact fixed argv and parses raw NUL output")
    func successfulListing() async throws {
        let context = repositoryContext()
        let validationRunner = StubLocalGitRunner(outcomes: validationOutcomes(for: context))
        let listRunner = StubLocalGitRunner(outcomes: [
            .success(Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8))
        ])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: validationRunner),
            runner: listRunner
        )

        let outcome = await service.list(in: context)
        guard case .success(let parsed) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.records.map(\.displayBranch) == ["main"])
        #expect(
            listRunner.invocations == [
                .init(arguments: ["worktree", "list", "--porcelain", "-z"], directory: context.invocationRoot)
            ])
    }

    @Test("a changed common git directory is a distinct outcome and skips listing")
    func repositoryChanged() async {
        let context = repositoryContext()
        let validationRunner = StubLocalGitRunner(outcomes: [
            .success(Data("false\n".utf8)),
            .success(Data("/repo\n/other/common\n".utf8)),
        ])
        let listRunner = StubLocalGitRunner(outcomes: [])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: validationRunner),
            runner: listRunner
        )

        #expect(await service.list(in: context) == .repositoryChanged)
        #expect(listRunner.invocations.isEmpty)
    }

    @Test(arguments: [
        (BoundedCommandResult.nonZeroExit(7), GitWorktreeListFailure.nonZeroExit(7)),
        (.timedOut, .timedOut),
        (.spawnFailure, .spawnFailure),
        (.outputTruncated(Data()), .outputTruncated),
    ])
    func processFailures(result: BoundedCommandResult, failure: GitWorktreeListFailure) async {
        let context = repositoryContext()
        let validationRunner = StubLocalGitRunner(outcomes: validationOutcomes(for: context))
        let listRunner = StubLocalGitRunner(outcomes: [result])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: validationRunner),
            runner: listRunner
        )

        #expect(await service.list(in: context) == .failure(failure))
    }

    private func repositoryContext() -> GitRepositoryContext {
        GitRepositoryContext(
            invocationRoot: URL(fileURLWithPath: "/repo"),
            canonicalCommonGitDirectory: URL(fileURLWithPath: "/repo/.git"),
            displayName: "repo"
        )
    }

    private func validationOutcomes(for context: GitRepositoryContext) -> [BoundedCommandResult] {
        [
            .success(Data("false\n".utf8)),
            .success(Data("\(context.invocationRoot.path)\n\(context.canonicalCommonGitDirectory.path)\n".utf8)),
        ]
    }
}

private final class StubLocalGitRunner: LocalGitCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var arguments: [String]
        var directory: URL
    }

    private let lock = NSLock()
    private var outcomes: [BoundedCommandResult]
    private var recorded: [Invocation] = []

    init(outcomes: [BoundedCommandResult]) {
        self.outcomes = outcomes
    }

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    func run(arguments: [String], inDirectory directory: URL) async -> BoundedCommandResult {
        lock.withLock {
            recorded.append(Invocation(arguments: arguments, directory: directory))
            return outcomes.isEmpty ? .spawnFailure : outcomes.removeFirst()
        }
    }
}
