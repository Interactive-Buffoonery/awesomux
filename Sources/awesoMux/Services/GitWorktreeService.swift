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

enum GitRepositoryIdentityValidation: Equatable, Sendable {
    case valid
    case changed
    case failed(GitRepositoryLocationFailure)
}

enum GitWorktreeBranchNameValidation: Equatable, Sendable {
    case valid
    case blank
    case invalidSyntax
    case repositoryChanged
    case repositoryValidationFailed
    case checkFailed
}

protocol GitWorktreeListing: Sendable {
    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome
}

protocol GitWorktreeManaging: GitWorktreeListing {
    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation
    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome
    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchNameValidation
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
        switch await validateIdentity(repositoryContext) {
        case .valid:
            break
        case .changed:
            return .repositoryChanged
        case .failed(let failure):
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

    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation {
        await validateIdentity(repositoryContext)
    }

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome {
        switch await validateIdentity(repositoryContext) {
        case .valid: break
        case .changed: return .repositoryChanged
        case .failed(let failure): return .failure(.repositoryValidationFailed(failure))
        }
        // Full refname, not `:short` — when a tag shares a branch's name,
        // `:short` returns the disambiguated `heads/<name>` for that ONE
        // entry instead of `<name>`, which then fails to resolve as a branch
        // when passed back to `worktree add`. Stripping our own known
        // `refs/heads/` prefix sidesteps that ambiguity entirely.
        let result = await runner.run(
            arguments: ["for-each-ref", "refs/heads", "--format=%(refname)"],
            inDirectory: repositoryContext.invocationRoot
        )
        switch result {
        case .success(let data):
            guard let output = String(data: data, encoding: .utf8) else { return .failure(.outputTruncated) }
            let names = output.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("refs/heads/") else { return nil }
                return String(line.dropFirst("refs/heads/".count))
            }
            return .success(names)
        default:
            return .failure(mapFailure(result))
        }
    }

    func validateNewBranchName(
        _ name: String,
        in repositoryContext: GitRepositoryContext
    ) async -> GitWorktreeBranchNameValidation {
        switch await validateIdentity(repositoryContext) {
        case .valid: break
        case .changed: return .repositoryChanged
        case .failed: return .repositoryValidationFailed
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .blank }
        switch await runner.run(
            arguments: ["check-ref-format", "--branch", name],
            inDirectory: repositoryContext.invocationRoot
        ) {
        case .success: return .valid
        case .nonZeroExit: return .invalidSyntax
        default: return .checkFailed
        }
    }

    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome {
        switch await validateIdentity(request.repositoryContext) {
        case .valid: break
        case .changed: return .failure(.repositoryChanged)
        case .failed: return .failure(.repositoryValidationFailed)
        }
        let before: [GitWorktreeRecord]
        switch await list(in: request.repositoryContext) {
        case .success(let parsed): before = parsed.records
        case .repositoryChanged: return .failure(.repositoryChanged)
        case .failure: return .failure(.reconciliationFailed)
        }
        let issues = policy.validate(request, currentWorktrees: before)
        guard issues.isEmpty else { return .failure(.invalidRequest(issues)) }
        let targetExistedBefore = before.contains {
            canonicalPathComponents($0.canonicalPath) == canonicalPathComponents(request.targetPath)
        }
        var branchesBefore: Set<String> = []
        if case .newBranchFromHEAD(let name) = request.mode {
            switch await validateNewBranchName(name, in: request.repositoryContext) {
            case .valid: break
            case .blank: return .failure(.invalidRequest([.blankBranchName]))
            case .invalidSyntax: return .failure(.invalidRequest([.invalidBranchName]))
            case .repositoryChanged: return .failure(.repositoryChanged)
            case .repositoryValidationFailed: return .failure(.repositoryValidationFailed)
            case .checkFailed: return .failure(.reconciliationFailed)
            }
            switch await branches(in: request.repositoryContext) {
            case .success(let names):
                branchesBefore = Set(names)
            case .repositoryChanged:
                return .failure(.repositoryChanged)
            case .failure:
                return .failure(.reconciliationFailed)
            }
        }

        let arguments: [String]
        switch request.mode {
        case .existingBranch(let branch):
            arguments = ["worktree", "add", request.targetPath.path, "refs/heads/\(branch)"]
        case .newBranchFromHEAD(let branch):
            arguments = ["worktree", "add", "-b", branch, request.targetPath.path, "HEAD"]
        }
        let commandResult = await runner.run(
            arguments: arguments,
            inDirectory: request.repositoryContext.invocationRoot
        )
        let diagnostic = createDiagnostic(commandResult)
        let expectedBranchRef = "refs/heads/\(request.mode.branchName)"

        switch await list(in: request.repositoryContext) {
        case .success(let parsed):
            if !targetExistedBefore,
                let record = parsed.records.first(where: {
                    canonicalPathComponents($0.canonicalPath) == canonicalPathComponents(request.targetPath)
                        && $0.branchRef == expectedBranchRef
                })
            {
                return .success(record)
            }
        case .repositoryChanged:
            return .failure(.repositoryChanged)
        case .failure:
            return .failure(.reconciliationFailed)
        }

        if case .newBranchFromHEAD(let branch) = request.mode, !branchesBefore.contains(branch),
            case .success(let names) = await branches(in: request.repositoryContext),
            names.contains(branch)
        {
            return .branchCreatedWithoutWorktree(branchName: branch, diagnostic: diagnostic)
        }
        return .failure(diagnostic)
    }

    private func validateIdentity(_ context: GitRepositoryContext) async -> GitRepositoryIdentityValidation {
        switch await locator.locate(startingAt: context.invocationRoot) {
        case .located(let current):
            return current.canonicalCommonGitDirectory == context.canonicalCommonGitDirectory ? .valid : .changed
        case .notRepository, .bareRepository: return .changed
        case .failure(let failure): return .failed(failure)
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
        case .success: .reconciliationFailed
        case .executableNotFound: .executableNotFound
        case .spawnFailure: .spawnFailure
        case .nonZeroExit(let status): .nonZeroExit(status)
        case .timedOut: .timedOut
        case .outputTruncated: .outputTruncated
        case .outputNotDrained: .outputNotDrained
        }
    }
}
