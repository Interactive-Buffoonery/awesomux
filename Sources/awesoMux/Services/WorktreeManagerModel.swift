import AwesoMuxCore
import Foundation
import Observation

struct WorktreeManagerRow: Identifiable, Equatable, Sendable {
    var record: GitWorktreeRecord
    var liveMatch: WorktreeWorkspaceMatch?

    var id: URL { record.canonicalPath }

    var workspaceTitle: String {
        record.isDetached ? record.canonicalPath.lastPathComponent : record.displayBranch
    }
}

enum WorktreeManagerState: Equatable, Sendable {
    case loading
    case loaded([WorktreeManagerRow])
    case error(lastGoodRows: [WorktreeManagerRow], message: String)

    var rows: [WorktreeManagerRow] {
        switch self {
        case .loading: []
        case .loaded(let rows): rows
        case .error(let rows, _): rows
        }
    }
}

enum WorktreeManagerOpenOutcome: Equatable, Sendable {
    case focused(WorktreeWorkspaceMatch)
    case created(TerminalSession.ID)
    case failed(String)
}

enum WorktreeManagerCreateResult: Equatable, Sendable {
    case opened(WorktreeManagerOpenOutcome)
    case worktreeCreatedWorkspaceOpenFailed(String)
    case branchCreatedWithoutWorktree(String)
    case failed(String)
}

enum WorktreeManagerCreateSubmissionState: Equatable, Sendable {
    case idle
    case submitting
    case result(WorktreeManagerCreateResult)

    var isSubmitting: Bool { self == .submitting }
}

@MainActor
@Observable
final class WorktreeManagerModel {
    let repositoryContext: GitRepositoryContext
    private(set) var state: WorktreeManagerState = .loading
    private(set) var createSubmissionState: WorktreeManagerCreateSubmissionState = .idle
    private(set) var lastCreateRequest: GitWorktreeCreateRequest?

    @ObservationIgnored private let service: any GitWorktreeManaging
    @ObservationIgnored private let projection: WorktreeWorkspaceProjection
    @ObservationIgnored private let groups: () -> [SessionGroup]
    @ObservationIgnored private let currentGroupID: () -> SessionGroup.ID?
    @ObservationIgnored private let focus: (WorktreeWorkspaceMatch) -> Void
    @ObservationIgnored private let addLocalSession: (String?, String, SessionGroup.ID) -> TerminalSession.ID?

    init(
        repositoryContext: GitRepositoryContext,
        service: any GitWorktreeManaging = GitWorktreeService(),
        projection: WorktreeWorkspaceProjection = WorktreeWorkspaceProjection(),
        groups: @escaping () -> [SessionGroup],
        currentGroupID: @escaping () -> SessionGroup.ID?,
        focus: @escaping (WorktreeWorkspaceMatch) -> Void,
        addLocalSession: @escaping (String?, String, SessionGroup.ID) -> TerminalSession.ID?
    ) {
        self.repositoryContext = repositoryContext
        self.service = service
        self.projection = projection
        self.groups = groups
        self.currentGroupID = currentGroupID
        self.focus = focus
        self.addLocalSession = addLocalSession
    }

    convenience init(
        repositoryContext: GitRepositoryContext,
        service: any GitWorktreeManaging = GitWorktreeService(),
        sessionStore: SessionStore
    ) {
        self.init(
            repositoryContext: repositoryContext,
            service: service,
            groups: { sessionStore.groups },
            currentGroupID: {
                guard let selectedID = sessionStore.selectedSessionID else { return nil }
                return sessionStore.groups.first { group in
                    group.sessions.contains { $0.id == selectedID }
                }?.id
            },
            focus: { match in
                sessionStore.selectedSessionID = match.sessionID
                sessionStore.setActivePane(id: match.paneID, in: match.sessionID)
            },
            addLocalSession: { title, workingDirectory, groupID in
                sessionStore.addLocalSession(
                    title: title,
                    workingDirectory: workingDirectory,
                    toGroupID: groupID
                )
            }
        )
    }

    func refresh() async {
        if state.rows.isEmpty {
            state = .loading
        }
        let previousRows = state.rows
        switch await service.list(in: repositoryContext) {
        case .success(let result):
            let liveGroups = groups()
            state = .loaded(
                result.records.map { record in
                    WorktreeManagerRow(
                        record: record,
                        liveMatch: projection.match(
                            canonicalWorktreePath: record.canonicalPath,
                            groups: liveGroups
                        )
                    )
                })
        case .repositoryChanged:
            state = .error(
                lastGoodRows: previousRows,
                message: String(
                    localized: "The Git repository changed. Reopen Worktree Manager from the active workspace.",
                    comment: "Worktree Manager refresh error when the captured repository is no longer current."
                )
            )
        case .failure:
            state = .error(
                lastGoodRows: previousRows,
                message: String(
                    localized: "Couldn’t refresh worktrees. Check Git and try again.",
                    comment: "Worktree Manager refresh error when the Git command fails."
                )
            )
        }
    }

    func open(row: WorktreeManagerRow) -> WorktreeManagerOpenOutcome {
        open(record: row.record)
    }

    func branches() async -> GitWorktreeBranchesOutcome {
        await service.branches(in: repositoryContext)
    }

    var destinationWorkspaceGroupID: SessionGroup.ID? { currentGroupID() }

    func validateNewBranchName(_ name: String) async -> Bool {
        await service.validateNewBranchName(name, in: repositoryContext)
    }

    @discardableResult
    func create(request: GitWorktreeCreateRequest) async -> WorktreeManagerCreateResult? {
        guard !createSubmissionState.isSubmitting else { return nil }
        lastCreateRequest = request
        createSubmissionState = .submitting
        let outcome = await service.create(request)
        await refresh()

        let result: WorktreeManagerCreateResult
        switch outcome {
        case .success(let record):
            let openOutcome = open(record: record, destinationGroupID: request.destinationWorkspaceGroupID)
            if case .failed(let message) = openOutcome {
                result = .worktreeCreatedWorkspaceOpenFailed(message)
            } else {
                result = .opened(openOutcome)
            }
        case .branchCreatedWithoutWorktree(let branchName, _):
            result = .branchCreatedWithoutWorktree(branchName)
        case .failure:
            result = .failed(
                String(
                    localized: "Couldn’t create the worktree. Check the path and Git details, then try again.",
                    comment: "Worktree creation failure message."))
        }
        createSubmissionState = .result(result)
        return result
    }

    func resetCreateResult() {
        guard !createSubmissionState.isSubmitting else { return }
        createSubmissionState = .idle
    }

    private func open(
        record: GitWorktreeRecord,
        destinationGroupID: SessionGroup.ID? = nil
    ) -> WorktreeManagerOpenOutcome {
        if let match = projection.match(
            canonicalWorktreePath: record.canonicalPath,
            groups: groups()
        ) {
            focus(match)
            return .focused(match)
        }

        guard let groupID = destinationGroupID ?? currentGroupID() else {
            return .failed(
                String(
                    localized: "The current workspace group is no longer available.",
                    comment: "Worktree Manager open failure when its target group disappeared."
                ))
        }
        guard
            let sessionID = addLocalSession(
                record.isDetached ? record.canonicalPath.lastPathComponent : record.displayBranch,
                record.canonicalPath.path,
                groupID
            )
        else {
            return .failed(
                String(
                    localized: "The current workspace group is no longer available.",
                    comment: "Worktree Manager open failure when its target group disappeared."
                ))
        }
        return .created(sessionID)
    }
}
