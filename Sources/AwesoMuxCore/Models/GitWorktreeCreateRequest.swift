import Foundation

public struct GitRepositoryContext: Equatable, Sendable {
    public var invocationRoot: URL
    public var canonicalCommonGitDirectory: URL
    public var displayName: String

    public init(invocationRoot: URL, canonicalCommonGitDirectory: URL, displayName: String) {
        self.invocationRoot = invocationRoot
        self.canonicalCommonGitDirectory = canonicalCommonGitDirectory
        self.displayName = displayName
    }
}

public enum GitWorktreeCreateMode: Equatable, Sendable {
    case existingBranch(String)
    case newBranchFromHEAD(String)

    public var branchName: String {
        switch self {
        case .existingBranch(let name), .newBranchFromHEAD(let name): name
        }
    }
}

public struct GitWorktreeCreateRequest: Equatable, Sendable {
    public var repositoryContext: GitRepositoryContext
    public var mode: GitWorktreeCreateMode
    public var targetPath: URL
    public var destinationWorkspaceGroupID: UUID

    public init(
        repositoryContext: GitRepositoryContext,
        mode: GitWorktreeCreateMode,
        targetPath: URL,
        destinationWorkspaceGroupID: UUID
    ) {
        self.repositoryContext = repositoryContext
        self.mode = mode
        self.targetPath = targetPath
        self.destinationWorkspaceGroupID = destinationWorkspaceGroupID
    }
}

public enum GitWorktreeCreateDiagnostic: Equatable, Sendable {
    case repositoryChanged
    case repositoryValidationFailed
    case executableNotFound
    case spawnFailure
    case nonZeroExit(Int32)
    case timedOut
    case outputTruncated
    case outputNotDrained
    case reconciliationFailed
    case invalidRequest([GitWorktreeCreateValidationIssue])
}

public enum GitWorktreeCreateOutcome: Equatable, Sendable {
    case success(GitWorktreeRecord)
    case branchCreatedWithoutWorktree(branchName: String, diagnostic: GitWorktreeCreateDiagnostic)
    case failure(GitWorktreeCreateDiagnostic)
}
