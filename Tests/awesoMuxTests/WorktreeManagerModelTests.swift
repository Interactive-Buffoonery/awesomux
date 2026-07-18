import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Worktree Manager model")
struct WorktreeManagerModelTests {
    @Test("create success refreshes and opens the confirmed workspace")
    func createSuccessOpensWorkspace() async {
        let groupID = UUID()
        var openedPath: String?
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [record()], diagnostics: []))],
            createOutcomes: [.success(record())]
        )
        let model = makeModel(
            service: service, currentGroupID: { groupID },
            add: { _, path, _ in
                openedPath = path; return UUID()
            })
        let result = await model.create(request: request(groupID: groupID))
        guard case .opened = result else { Issue.record("Expected opened result"); return }
        #expect(openedPath == "/tmp/worktrees/int-857")
    }

    @Test("branch-only partial does not open a workspace")
    func partialDoesNotOpen() async {
        var addCalls = 0
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [], diagnostics: []))],
            createOutcomes: [.branchCreatedWithoutWorktree(branchName: "feature/int-857", diagnostic: .nonZeroExit(1))]
        )
        let model = makeModel(
            service: service, currentGroupID: { UUID() },
            add: { _, _, _ in
                addCalls += 1; return UUID()
            })
        let result = await model.create(request: request(groupID: UUID()))
        #expect(result == .branchCreatedWithoutWorktree("feature/int-857"))
        #expect(addCalls == 0)
    }

    @Test("rejected create preserves the submitted form values")
    func rejectedCreatePreservesRequest() async {
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [], diagnostics: []))],
            createOutcomes: [.failure(.invalidRequest([.targetAlreadyExists]))]
        )
        let model = makeModel(service: service)
        let submitted = request(groupID: UUID())
        _ = await model.create(request: submitted)
        #expect(model.lastCreateRequest == submitted)
        guard case .result(.failed) = model.createSubmissionState else {
            Issue.record("Expected visible rejected result")
            return
        }
    }

    @Test("duplicate create submission is blocked while submitting")
    func duplicateCreateBlocked() async {
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [], diagnostics: []))],
            createOutcomes: [.failure(.spawnFailure)],
            createDelay: .milliseconds(100)
        )
        let model = makeModel(service: service)
        let request = request(groupID: UUID())
        let first = Task { await model.create(request: request) }
        await Task.yield()
        let duplicate = await model.create(request: request)
        _ = await first.value
        #expect(duplicate == nil)
        #expect(service.createCallCount == 1)
    }
    @Test("refresh transitions from loading to loaded")
    func refreshLoadsRows() async {
        let service = StubWorktreeListing(outcomes: [.success(.init(records: [record()], diagnostics: []))])
        let model = makeModel(service: service)

        #expect(model.state == .loading)
        await model.refresh()

        #expect(model.state.rows.map(\.record.displayBranch) == ["feature/int-857"])
        guard case .loaded = model.state else {
            Issue.record("Expected loaded state")
            return
        }
    }

    @Test("initial refresh failure transitions to error")
    func refreshFails() async {
        let model = makeModel(service: StubWorktreeListing(outcomes: [.failure(.spawnFailure)]))

        await model.refresh()

        guard case .error(let rows, _) = model.state else {
            Issue.record("Expected error state")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test("failed refresh preserves the last good rows")
    func refreshFailurePreservesRows() async {
        let service = StubWorktreeListing(outcomes: [
            .success(.init(records: [record()], diagnostics: [])),
            .failure(.timedOut),
        ])
        let model = makeModel(service: service)

        await model.refresh()
        await model.refresh()

        guard case .error(let rows, _) = model.state else {
            Issue.record("Expected error state")
            return
        }
        #expect(rows.map(\.record.canonicalPath.path) == ["/tmp/worktrees/int-857"])
    }

    @Test("open focuses a fresh live match without creating a session")
    func openIsIdempotentForLivePane() async throws {
        let session = TerminalSession(
            title: "existing",
            workingDirectory: "/tmp/worktrees/int-857/Sources"
        )
        let group = SessionGroup(name: "work", sessions: [session])
        var focused: WorktreeWorkspaceMatch?
        var createCalls = 0
        let model = makeModel(
            groups: { [group] },
            currentGroupID: { group.id },
            focus: { focused = $0 },
            add: { _, _, _ in
                createCalls += 1; return UUID()
            }
        )
        let row = WorktreeManagerRow(record: record(), liveMatch: nil)

        let outcome = await model.open(row: row)

        let match = try #require(focused)
        #expect(outcome == .focused(match))
        #expect(match.sessionID == session.id)
        #expect(createCalls == 0)
    }

    @Test("open fails closed when the captured group vanished")
    func openFailsWhenGroupVanishes() async {
        let groupID = UUID()
        var capturedAddGroupID: UUID?
        let model = makeModel(
            currentGroupID: { groupID },
            add: { _, _, id in
                capturedAddGroupID = id; return nil
            }
        )

        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        guard case .failed = outcome else {
            Issue.record("Expected failed open")
            return
        }
        #expect(capturedAddGroupID == groupID)
    }

    @Test("open revalidates repository identity before focusing or creating")
    func openFailsWhenRepositoryChanged() async {
        var focusCalls = 0
        var addCalls = 0
        let service = StubWorktreeListing(
            outcomes: [.repositoryChanged],
            identityOutcomes: [.changed]
        )
        let model = makeModel(
            service: service,
            currentGroupID: { UUID() },
            focus: { _ in focusCalls += 1 },
            add: { _, _, _ in
                addCalls += 1
                return UUID()
            })

        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        guard case .failed(let message) = outcome else {
            Issue.record("Expected repository-change failure, got \(outcome)")
            return
        }
        #expect(message.contains("repository changed"))
        #expect(focusCalls == 0)
        #expect(addCalls == 0)
        guard case .error = model.state else {
            Issue.record("Expected repository-change refresh to update model state")
            return
        }
    }

    @Test("open fails closed when identity validation itself fails, not just when it detects drift")
    func openFailsWhenIdentityValidationErrors() async {
        var focusCalls = 0
        var addCalls = 0
        let service = StubWorktreeListing(
            outcomes: [.failure(.spawnFailure)],
            identityOutcomes: [.failed(.spawnFailure)]
        )
        let model = makeModel(
            service: service,
            currentGroupID: { UUID() },
            focus: { _ in focusCalls += 1 },
            add: { _, _, _ in
                addCalls += 1
                return UUID()
            })

        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        guard case .failed = outcome else {
            Issue.record("Expected identity-validation failure, got \(outcome)")
            return
        }
        #expect(focusCalls == 0)
        #expect(addCalls == 0)
    }

    private func makeModel(
        service: any GitWorktreeManaging = StubWorktreeListing(outcomes: []),
        groups: @escaping () -> [SessionGroup] = { [] },
        currentGroupID: @escaping () -> SessionGroup.ID? = { nil },
        focus: @escaping (WorktreeWorkspaceMatch) -> Void = { _ in },
        add: @escaping (String?, String, SessionGroup.ID) -> TerminalSession.ID? = { _, _, _ in nil }
    ) -> WorktreeManagerModel {
        WorktreeManagerModel(
            repositoryContext: .init(
                invocationRoot: URL(fileURLWithPath: "/tmp/repo"),
                canonicalCommonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
                displayName: "repo"
            ),
            service: service,
            // Fixture working directories are fictional paths — stub existence
            // so live-match tests don't depend on the real filesystem.
            projection: WorktreeWorkspaceProjection(directoryExists: { _ in true }),
            groups: groups,
            currentGroupID: currentGroupID,
            focus: focus,
            addLocalSession: add
        )
    }

    private func record() -> GitWorktreeRecord {
        GitWorktreeRecord(
            canonicalPath: URL(fileURLWithPath: "/tmp/worktrees/int-857"),
            headObjectID: "abc",
            branchRef: "refs/heads/feature/int-857",
            isDetached: false,
            displayBranch: "feature/int-857",
            isMainWorktree: false,
            isBare: false,
            lockReason: nil,
            prunableReason: nil
        )
    }

    private func request(groupID: UUID) -> GitWorktreeCreateRequest {
        .init(
            repositoryContext: .init(
                invocationRoot: URL(fileURLWithPath: "/tmp/repo"), canonicalCommonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
                displayName: "repo"),
            mode: .existingBranch("feature/int-857"),
            targetPath: URL(fileURLWithPath: "/tmp/worktrees/int-857"),
            destinationWorkspaceGroupID: groupID
        )
    }
}

private final class StubWorktreeListing: GitWorktreeManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [GitWorktreeListOutcome]
    private var identityOutcomes: [GitRepositoryIdentityValidation]
    private var createOutcomes: [GitWorktreeCreateOutcome]
    private let createDelay: Duration?
    private var recordedCreateCalls = 0

    init(
        outcomes: [GitWorktreeListOutcome],
        identityOutcomes: [GitRepositoryIdentityValidation] = [],
        createOutcomes: [GitWorktreeCreateOutcome] = [],
        createDelay: Duration? = nil
    ) {
        self.outcomes = outcomes
        self.identityOutcomes = identityOutcomes
        self.createOutcomes = createOutcomes
        self.createDelay = createDelay
    }

    var createCallCount: Int { lock.withLock { recordedCreateCalls } }

    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation {
        lock.withLock { identityOutcomes.isEmpty ? .valid : identityOutcomes.removeFirst() }
    }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        lock.withLock { outcomes.isEmpty ? .failure(.spawnFailure) : outcomes.removeFirst() }
    }

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome {
        .success(["main"])
    }

    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> Bool { true }

    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome {
        let result = lock.withLock { () -> GitWorktreeCreateOutcome in
            recordedCreateCalls += 1
            return createOutcomes.isEmpty ? .failure(.spawnFailure) : createOutcomes.removeFirst()
        }
        if let createDelay { try? await Task.sleep(for: createDelay) }
        return result
    }
}
