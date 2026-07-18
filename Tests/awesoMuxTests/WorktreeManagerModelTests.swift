import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Worktree Manager model")
struct WorktreeManagerModelTests {
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
    func openIsIdempotentForLivePane() throws {
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

        let outcome = model.open(row: row)

        let match = try #require(focused)
        #expect(outcome == .focused(match))
        #expect(match.sessionID == session.id)
        #expect(createCalls == 0)
    }

    @Test("open fails closed when the captured group vanished")
    func openFailsWhenGroupVanishes() {
        let groupID = UUID()
        var capturedAddGroupID: UUID?
        let model = makeModel(
            currentGroupID: { groupID },
            add: { _, _, id in
                capturedAddGroupID = id; return nil
            }
        )

        let outcome = model.open(row: WorktreeManagerRow(record: record(), liveMatch: nil))

        guard case .failed = outcome else {
            Issue.record("Expected failed open")
            return
        }
        #expect(capturedAddGroupID == groupID)
    }

    private func makeModel(
        service: any GitWorktreeListing = StubWorktreeListing(outcomes: []),
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
}

private final class StubWorktreeListing: GitWorktreeListing, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [GitWorktreeListOutcome]

    init(outcomes: [GitWorktreeListOutcome]) {
        self.outcomes = outcomes
    }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        lock.withLock { outcomes.isEmpty ? .failure(.spawnFailure) : outcomes.removeFirst() }
    }
}
