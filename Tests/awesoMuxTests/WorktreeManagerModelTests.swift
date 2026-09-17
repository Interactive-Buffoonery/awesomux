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
            gatesCreate: true
        )
        let model = makeModel(service: service)
        let request = request(groupID: UUID())
        let first = Task { await model.create(request: request) }
        // A bare `Task.yield()` doesn't guarantee `create` has actually
        // reached `.submitting` before the duplicate races in; wait for the
        // stub's explicit start signal instead.
        await service.waitForCreateToStart()
        let duplicate = await model.create(request: request)
        service.releaseCreate()
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

    @Test("nested linked worktree owns its pane during refresh and open")
    func nestedWorktreeOwnership() async throws {
        let linkedSession = TerminalSession(
            title: "linked",
            workingDirectory: "/tmp/repo/.worktrees/int-857/Sources"
        )
        let group = SessionGroup(name: "work", sessions: [linkedSession])
        let main = mainRecord()
        let linked = record(path: "/tmp/repo/.worktrees/int-857")
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [main, linked], diagnostics: []))]
        )
        var focused: WorktreeWorkspaceMatch?
        var openedPath: String?
        let createdID = UUID()
        let model = makeModel(
            service: service,
            groups: { [group] },
            currentGroupID: { group.id },
            focus: { focused = $0 },
            add: { _, path, _ in
                openedPath = path; return createdID
            }
        )

        await model.refresh()

        #expect(model.state.rows[0].liveMatch == nil)
        #expect(model.state.rows[1].liveMatch?.sessionID == linkedSession.id)
        #expect(await model.open(row: model.state.rows[0]) == .created(createdID))
        #expect(openedPath == "/tmp/repo")

        let linkedOutcome = await model.open(row: model.state.rows[1])
        #expect(linkedOutcome == .focused(try #require(focused)))
        #expect(focused?.sessionID == linkedSession.id)
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

    @Test("a cancelled refresh does not mutate state or announce")
    func cancelledRefreshDoesNotMutateOrAnnounce() async {
        // Cancellation is cooperative: `refresh()`'s own `await service.list()`
        // doesn't stop just because the enclosing Task was cancelled. This
        // proves the explicit `Task.isCancelled` guard actually blocks the
        // mutation/announcement a stale, cancelled refresh would otherwise
        // still perform (e.g. a controller reusing one panel across a rapid
        // dismiss-then-show for a different repository).
        // A failure outcome so an unguarded cancellation would provably
        // announce (a success never announces, so that outcome wouldn't
        // exercise the guard this test is proving).
        let service = StubWorktreeListing(
            outcomes: [.failure(.spawnFailure)],
            listDelay: .milliseconds(50)
        )
        let model = makeModel(service: service)
        var announced: [String] = []
        model.announce = { announced.append($0) }

        let task = Task { await model.refresh() }
        await Task.yield()
        task.cancel()
        await task.value

        #expect(model.state == .loading)
        #expect(announced.isEmpty)
    }

    @Test("open focuses a fresh live match without creating a session", arguments: WorktreeOpenDestination.allCases)
    func openIsIdempotentForLivePane(destination: WorktreeOpenDestination) async throws {
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

        let outcome = await model.open(row: row, destination: destination)

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
            groups: { [SessionGroup(id: groupID, name: "work", sessions: [])] },
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
        #expect(outcome == .failed("The current workspace group is no longer available."))
        #expect(capturedAddGroupID == groupID)
    }

    @Test("open tells users to create a group when none exists")
    func openExplainsHowToRecoverWithoutGroups() async {
        var addCalls = 0
        let model = makeModel(add: { _, _, _ in
            addCalls += 1
            return UUID()
        })

        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        #expect(outcome == .failed("Create a workspace group from the Workspace menu, then try again."))
        #expect(addCalls == 0)
    }

    @Test("open tells users to select a group when groups exist")
    func openExplainsHowToRecoverWithoutSelection() async {
        var addCalls = 0
        let model = makeModel(
            groups: { [SessionGroup(name: "work", sessions: [])] },
            add: { _, _, _ in
                addCalls += 1
                return UUID()
            }
        )

        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        #expect(outcome == .failed("Select a workspace group, then try again."))
        #expect(addCalls == 0)
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

    @Test("split destinations create and focus local worktree panes", arguments: [WorktreeOpenDestination.splitRight, .splitDown])
    func openAsSplit(destination: WorktreeOpenDestination) async throws {
        let session = TerminalSession(title: "original", workingDirectory: "/tmp/original")
        let group = SessionGroup(name: "work", sessions: [session])
        let store = SessionStore(groups: [group])
        let model = WorktreeManagerModel(
            repositoryContext: request(groupID: group.id).repositoryContext,
            service: StubWorktreeListing(outcomes: []), sessionStore: store)
        #expect(model.canOpenAsSplit)
        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil), destination: destination)
        guard case .split(let match) = outcome else { Issue.record("Expected split"); return }
        let updated = try #require(store.selectedSession)
        let pane = try #require(updated.layout.pane(id: match.paneID))
        #expect(updated.id == session.id)
        #expect(updated.activePaneID == pane.id)
        #expect(updated.panes.count == 2)
        #expect(pane.workingDirectory == record().canonicalPath.path)
        #expect(pane.executionPlan == .local)
        #expect(updated.layout.pane(id: session.activePaneID)?.workingDirectory == "/tmp/original")
        guard case .split(let split) = updated.layout else { Issue.record("Expected split layout"); return }
        #expect(split.orientation == (destination == .splitRight ? .vertical : .horizontal))
        #expect(store.groups[0].sessions.count == 1)
    }

    @Test("remote and missing destinations cannot split", arguments: [false, true])
    func unavailableSplit(remote: Bool) async throws {
        let target = try #require(RemoteTarget(user: "", host: "example.com"))
        let session = TerminalSession(title: "remote", workingDirectory: "/tmp/original", executionPlan: .ssh(.init(target: target)))
        let group = SessionGroup(name: "work", sessions: remote ? [session] : [])
        let store = SessionStore(groups: [group])
        let model = WorktreeManagerModel(
            repositoryContext: request(groupID: group.id).repositoryContext,
            service: StubWorktreeListing(outcomes: []), sessionStore: store)
        #expect(!model.canOpenAsSplit)
        let outcome = await model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil), destination: .splitRight)
        guard case .failed = outcome else { Issue.record("Expected unavailable split failure"); return }
        #expect(store.groups[0].sessions.count == (remote ? 1 : 0))
    }

    @Test("create captures the split destination before Git and fails without fallback when it changes")
    func createDoesNotSplitChangedSelection() async {
        let first = TerminalSession(title: "first", workingDirectory: "/tmp/first")
        let second = TerminalSession(title: "second", workingDirectory: "/tmp/second")
        let group = SessionGroup(name: "work", sessions: [first, second])
        let store = SessionStore(groups: [group])
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [record()], diagnostics: []))],
            createOutcomes: [.success(record())], gatesCreate: true)
        let model = WorktreeManagerModel(
            repositoryContext: request(groupID: group.id).repositoryContext,
            service: service, sessionStore: store)
        let task = Task { await model.create(request: request(groupID: group.id), destination: .splitDown) }
        await service.waitForCreateToStart()
        store.selectedSessionID = second.id
        service.releaseCreate()
        let result = await task.value
        guard case .worktreeCreatedWorkspaceOpenFailed = result else { Issue.record("Expected partial success"); return }
        #expect(store.groups[0].sessions.count == 2)
        #expect(store.groups[0].sessions.allSatisfy { $0.panes.count == 1 })
    }

    @Test("create opens the selected split after Git succeeds", arguments: [WorktreeOpenDestination.splitRight, .splitDown])
    func createOpensSplit(destination: WorktreeOpenDestination) async throws {
        let session = TerminalSession(title: "original", workingDirectory: "/tmp/original")
        let group = SessionGroup(name: "work", sessions: [session])
        let store = SessionStore(groups: [group])
        let service = StubWorktreeListing(
            outcomes: [.success(.init(records: [record()], diagnostics: []))],
            createOutcomes: [.success(record())])
        let model = WorktreeManagerModel(
            repositoryContext: request(groupID: group.id).repositoryContext,
            service: service, sessionStore: store)
        let result = await model.create(request: request(groupID: group.id), destination: destination)
        guard case .opened(.split(let match)) = result else { Issue.record("Expected created worktree split"); return }
        #expect(match.sessionID == session.id)
        #expect(store.selectedSession?.activePaneID == match.paneID)
        #expect(store.selectedSession?.activePane?.workingDirectory == record().canonicalPath.path)
        #expect(store.groups[0].sessions.count == 1)
        store.setActivePane(id: session.activePaneID, in: session.id)
        model.finishCreatePresentation()
        #expect(store.selectedSession?.activePaneID == match.paneID)
        #expect(model.createSubmissionState == .idle)
    }

    @Test("document leaf IDs cannot be a terminal split destination")
    func documentDestinationUnavailable() async {
        var session = TerminalSession(title: "original", workingDirectory: "/tmp/original")
        let document = DocumentGroup(browsingFrom: session.activePaneID)
        session.layout = .split(TerminalSplit(orientation: .vertical, first: session.layout, second: .documentGroup(document)))
        session.activePaneID = document.id
        let group = SessionGroup(name: "work", sessions: [session])
        var splitCalls = 0
        let model = WorktreeManagerModel(
            repositoryContext: request(groupID: group.id).repositoryContext,
            service: StubWorktreeListing(outcomes: []), groups: { [group] }, currentGroupID: { group.id },
            focus: { _ in }, addLocalSession: { _, _, _ in nil }, currentSession: { session },
            splitLocalPane: { _, _, _ in
                splitCalls += 1; return UUID()
            })
        #expect(!model.canOpenAsSplit)
        let result = await model.open(row: .init(record: record(), liveMatch: nil), destination: .splitDown)
        guard case .failed = result else { Issue.record("Expected unavailable document destination"); return }
        #expect(splitCalls == 0)
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

    private func record(path: String = "/tmp/worktrees/int-857") -> GitWorktreeRecord {
        GitWorktreeRecord(
            canonicalPath: URL(fileURLWithPath: path),
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

    private func mainRecord() -> GitWorktreeRecord {
        GitWorktreeRecord(
            canonicalPath: URL(fileURLWithPath: "/tmp/repo"),
            headObjectID: "def",
            branchRef: "refs/heads/main",
            isDetached: false,
            displayBranch: "main",
            isMainWorktree: true,
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
    private let listDelay: Duration?
    private let gatesCreate: Bool
    private var recordedCreateCalls = 0
    private var createStarted = false
    private var createStartedContinuation: CheckedContinuation<Void, Never>?
    private var createReleaseContinuation: CheckedContinuation<Void, Never>?

    init(
        outcomes: [GitWorktreeListOutcome],
        identityOutcomes: [GitRepositoryIdentityValidation] = [],
        createOutcomes: [GitWorktreeCreateOutcome] = [],
        listDelay: Duration? = nil,
        gatesCreate: Bool = false
    ) {
        self.outcomes = outcomes
        self.identityOutcomes = identityOutcomes
        self.createOutcomes = createOutcomes
        self.listDelay = listDelay
        self.gatesCreate = gatesCreate
    }

    var createCallCount: Int { lock.withLock { recordedCreateCalls } }

    /// Suspends until `create(_:)` has actually been invoked. Pair with
    /// `gatesCreate: true` so a test can prove a racing duplicate call is
    /// evaluated while the first call is genuinely in flight, instead of
    /// guessing via a bare `Task.yield()`.
    func waitForCreateToStart() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if createStarted {
                    continuation.resume()
                } else {
                    createStartedContinuation = continuation
                }
            }
        }
    }

    /// Releases a `create(_:)` call suspended by `gatesCreate: true`.
    func releaseCreate() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { createReleaseContinuation = nil }
            return createReleaseContinuation
        }
        continuation?.resume()
    }

    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation {
        lock.withLock { identityOutcomes.isEmpty ? .valid : identityOutcomes.removeFirst() }
    }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        if let listDelay { try? await Task.sleep(for: listDelay) }
        return lock.withLock { outcomes.isEmpty ? .failure(.spawnFailure) : outcomes.removeFirst() }
    }

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome {
        .success(["main"])
    }

    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchNameValidation {
        .valid
    }

    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome {
        if gatesCreate {
            // The release continuation must be stored before `createStarted`
            // flips (same locked block) — otherwise a waiter could observe
            // "started" and call `releaseCreate()` before there's anything to
            // resume, deadlocking this call forever.
            await withCheckedContinuation { continuation in
                let startedContinuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    createReleaseContinuation = continuation
                    createStarted = true
                    defer { createStartedContinuation = nil }
                    return createStartedContinuation
                }
                startedContinuation?.resume()
            }
        }
        return lock.withLock {
            recordedCreateCalls += 1
            return createOutcomes.isEmpty ? .failure(.spawnFailure) : createOutcomes.removeFirst()
        }
    }
}
