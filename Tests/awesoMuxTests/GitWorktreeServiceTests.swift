import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Git worktree service")
struct GitWorktreeServiceTests {
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
