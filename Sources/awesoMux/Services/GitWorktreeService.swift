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

enum GitWorktreeBranchesOutcome: Equatable, Sendable {
    case success([String])
    case repositoryChanged
    case failure(GitWorktreeListFailure)
}

protocol GitWorktreeListing: Sendable {
    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome
}

protocol GitWorktreeManaging: GitWorktreeListing {
    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome
    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> Bool
    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome
}

struct GitWorktreeService: GitWorktreeManaging, Sendable {
    private let locator: LocalGitRepositoryLocator
    private let runner: any LocalGitCommandRunning
    private let parser: GitWorktreePorcelainParser
    private let policy: GitWorktreeCreatePolicy

    init(
        locator: LocalGitRepositoryLocator = LocalGitRepositoryLocator(),
        runner: any LocalGitCommandRunning = BoundedLocalGitCommandRunner(),
        parser: GitWorktreePorcelainParser = GitWorktreePorcelainParser(),
        policy: GitWorktreeCreatePolicy = GitWorktreeCreatePolicy()
    ) {
        self.locator = locator
        self.runner = runner
        self.parser = parser
        self.policy = policy
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

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome {
        guard case .valid = await validateIdentity(repositoryContext) else {
            return .repositoryChanged
        }
        let result = await runner.run(
            arguments: ["for-each-ref", "refs/heads", "--format=%(refname:short)"],
            inDirectory: repositoryContext.invocationRoot
        )
        switch result {
        case .success(let data):
            guard let output = String(data: data, encoding: .utf8) else { return .failure(.outputTruncated) }
            return .success(output.split(separator: "\n").map(String.init))
        default:
            return .failure(mapFailure(result))
        }
    }

    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> Bool {
        guard case .valid = await validateIdentity(repositoryContext) else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .success = await runner.run(
            arguments: ["check-ref-format", "--branch", name],
            inDirectory: repositoryContext.invocationRoot
        ) {
            return true
        }
        return false
    }

    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome {
        guard case .valid = await validateIdentity(request.repositoryContext) else {
            return .failure(.repositoryChanged)
        }
        let before: [GitWorktreeRecord]
        switch await list(in: request.repositoryContext) {
        case .success(let parsed): before = parsed.records
        case .repositoryChanged: return .failure(.repositoryChanged)
        case .failure: return .failure(.reconciliationFailed)
        }
        let issues = policy.validate(request, currentWorktrees: before)
        guard issues.isEmpty else { return .failure(.invalidRequest(issues)) }
        if case .newBranchFromHEAD(let name) = request.mode,
            !(await validateNewBranchName(name, in: request.repositoryContext))
        {
            return .failure(.invalidRequest([.blankBranchName]))
        }

        let arguments: [String]
        switch request.mode {
        case .existingBranch(let branch):
            arguments = ["worktree", "add", request.targetPath.path, branch]
        case .newBranchFromHEAD(let branch):
            arguments = ["worktree", "add", "-b", branch, request.targetPath.path, "HEAD"]
        }
        let commandResult = await runner.run(
            arguments: arguments,
            inDirectory: request.repositoryContext.invocationRoot
        )
        let diagnostic = createDiagnostic(commandResult)

        switch await list(in: request.repositoryContext) {
        case .success(let parsed):
            if let record = parsed.records.first(where: {
                canonicalPathComponents($0.canonicalPath) == canonicalPathComponents(request.targetPath)
            }) {
                return .success(record)
            }
        case .repositoryChanged:
            return .failure(.repositoryChanged)
        case .failure:
            return .failure(.reconciliationFailed)
        }

        if case .newBranchFromHEAD(let branch) = request.mode,
            case .success(let names) = await branches(in: request.repositoryContext),
            names.contains(branch)
        {
            return .branchCreatedWithoutWorktree(branchName: branch, diagnostic: diagnostic)
        }
        return .failure(diagnostic)
    }

    private enum IdentityValidation { case valid, changed, failed }

    private func validateIdentity(_ context: GitRepositoryContext) async -> IdentityValidation {
        switch await locator.locate(startingAt: context.invocationRoot) {
        case .located(let current):
            return current.canonicalCommonGitDirectory == context.canonicalCommonGitDirectory ? .valid : .changed
        case .notRepository, .bareRepository: return .changed
        case .failure: return .failed
        }
    }

    private func mapFailure(_ result: BoundedCommandResult) -> GitWorktreeListFailure {
        switch result {
        case .executableNotFound: .executableNotFound
        case .spawnFailure: .spawnFailure
        case .nonZeroExit(let status): .nonZeroExit(status)
        case .timedOut: .timedOut
        case .outputTruncated: .outputTruncated
        case .outputNotDrained: .outputNotDrained
        case .success: .spawnFailure
        }
    }

    private func createDiagnostic(_ result: BoundedCommandResult) -> GitWorktreeCreateDiagnostic {
        switch result {
        case .success: .nonZeroExit(0)
        case .executableNotFound: .executableNotFound
        case .spawnFailure: .spawnFailure
        case .nonZeroExit(let status): .nonZeroExit(status)
        case .timedOut: .timedOut
        case .outputTruncated: .outputTruncated
        case .outputNotDrained: .outputNotDrained
        }
    }
}
