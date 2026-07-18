import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Git worktree service")
struct GitWorktreeServiceTests {
    @Test("branch listing uses exact fixed argv")
    func branchListing() async {
        let context = repositoryContext()
        let runner = StubLocalGitRunner(outcomes: [.success(Data("main\nfeature/foo\n".utf8))])
        let service = GitWorktreeService(
            locator: LocalGitRepositoryLocator(runner: StubLocalGitRunner(outcomes: validationOutcomes(for: context))), runner: runner)
        #expect(await service.branches(in: context) == .success(["main", "feature/foo"]))
        #expect(
            runner.invocations == [
                .init(arguments: ["for-each-ref", "refs/heads", "--format=%(refname:short)"], directory: context.invocationRoot)
            ])
    }

    @Test(arguments: [
        (false, ["worktree", "add", "/tmp/awesomux-phase3-target", "feature/foo"]),
        (true, ["worktree", "add", "-b", "feature/foo", "/tmp/awesomux-phase3-target", "HEAD"]),
    ])
    func createUsesExactArgv(newBranch: Bool, expected: [String]) async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(
            outcomes: Array(repeating: validationOutcomes(for: context), count: newBranch ? 4 : 3).flatMap { $0 })
        let before = Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)
        let after = Data("worktree /tmp/awesomux-phase3-target\0HEAD def\0branch refs/heads/feature/foo\0\0".utf8)
        var outcomes: [BoundedCommandResult] = [.success(before)]
        if newBranch { outcomes.append(.success(Data())) }
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

    @Test("branch-only mutation is distinct from clean failure")
    func branchOnlyPartial() async {
        let context = repositoryContext()
        let validation = StubLocalGitRunner(outcomes: Array(repeating: validationOutcomes(for: context), count: 5).flatMap { $0 })
        let emptyList = Data("worktree /repo\0HEAD abc\0branch refs/heads/main\0\0".utf8)
        let runner = StubLocalGitRunner(outcomes: [
            .success(emptyList), .success(Data()), .nonZeroExit(4), .success(emptyList), .success(Data("main\nfeature/foo\n".utf8)),
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
        (.outputTruncated, .outputTruncated),
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
