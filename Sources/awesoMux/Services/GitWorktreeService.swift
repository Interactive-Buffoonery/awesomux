import AwesoMuxCore
import Foundation

enum GitWorktreeListFailure: Equatable, Sendable {
    case repositoryValidationFailed(GitRepositoryLocationFailure)
    case executableNotFound
    case spawnFailure
    case nonZeroExit(Int32)
    case timedOut
    case outputTruncated
    case outputNotDrained
}

enum GitWorktreeListOutcome: Equatable, Sendable {
    case success(GitWorktreeParseResult)
    case repositoryChanged
    case failure(GitWorktreeListFailure)
}

struct GitWorktreeService: Sendable {
    private let locator: LocalGitRepositoryLocator
    private let runner: any LocalGitCommandRunning
    private let parser: GitWorktreePorcelainParser

    init(
        locator: LocalGitRepositoryLocator = LocalGitRepositoryLocator(),
        runner: any LocalGitCommandRunning = BoundedLocalGitCommandRunner(),
        parser: GitWorktreePorcelainParser = GitWorktreePorcelainParser()
    ) {
        self.locator = locator
        self.runner = runner
        self.parser = parser
    }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        switch await locator.locate(startingAt: repositoryContext.invocationRoot) {
        case .located(let current):
            guard current.canonicalCommonGitDirectory == repositoryContext.canonicalCommonGitDirectory else {
                return .repositoryChanged
            }
        case .notRepository, .bareRepository:
            return .repositoryChanged
        case .failure(let failure):
            return .failure(.repositoryValidationFailed(failure))
        }

        let result = await runner.run(
            arguments: ["worktree", "list", "--porcelain", "-z"],
            inDirectory: repositoryContext.invocationRoot
        )
        switch result {
        case .success(let data):
            return .success(parser.parse(data))
        case .executableNotFound:
            return .failure(.executableNotFound)
        case .spawnFailure:
            return .failure(.spawnFailure)
        case .nonZeroExit(let status):
            return .failure(.nonZeroExit(status))
        case .timedOut:
            return .failure(.timedOut)
        case .outputTruncated:
            return .failure(.outputTruncated)
        case .outputNotDrained:
            return .failure(.outputNotDrained)
        }
    }
}
