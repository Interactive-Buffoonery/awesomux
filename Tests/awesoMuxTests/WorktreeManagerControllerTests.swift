import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Worktree Manager controller", .serialized)
struct WorktreeManagerControllerTests {
    @Test("show dismiss and toggle preserve the visibility contract")
    func visibilityContract() async {
        _ = NSApplication.shared
        let model = makeModel(service: CountingWorktreeListing())
        let controller = WorktreeManagerController()

        controller.show(model: model, relativeTo: nil)
        #expect(controller.isVisible)

        controller.dismiss()
        #expect(!controller.isVisible)
        #expect(!controller.hasPendingRefresh)

        controller.toggle(model: model, relativeTo: nil)
        #expect(controller.isVisible)
        controller.toggle(model: model, relativeTo: nil)
        #expect(!controller.isVisible)
    }

    @Test("show performs one refresh and starts no polling timer")
    func noPolling() async {
        _ = NSApplication.shared
        let service = CountingWorktreeListing()
        let model = makeModel(service: service)
        let controller = WorktreeManagerController()

        controller.show(model: model, relativeTo: nil)
        await controller.waitForPendingRefresh()
        #expect(service.callCount == 1)
        #expect(!controller.hasPendingRefresh)

        await controller.waitForPendingRefresh()
        #expect(service.callCount == 1)
        controller.dismiss()
    }

    @Test("a rapid dismiss-then-show cancels the prior refresh task and starts a fresh one")
    func rapidReShowReplacesRefreshTask() async {
        _ = NSApplication.shared
        let serviceA = CountingWorktreeListing()
        let modelA = makeModel(service: serviceA)
        let serviceB = CountingWorktreeListing()
        let modelB = makeModel(service: serviceB)
        let controller = WorktreeManagerController()

        controller.show(model: modelA, relativeTo: nil)
        // Re-show with a DIFFERENT model before A's refresh is awaited —
        // this cancels A's task and starts B's on the same controller/panel.
        controller.show(model: modelB, relativeTo: nil)
        await controller.waitForPendingRefresh()

        #expect(serviceB.callCount == 1)
        #expect(!controller.hasPendingRefresh)
    }

    @Test("show with presentingCreateForm marks the model for the create sheet")
    func presentingCreateFormSetsPendingFlag() async {
        _ = NSApplication.shared
        let model = makeModel(service: CountingWorktreeListing())
        let controller = WorktreeManagerController()

        #expect(!model.pendingCreatePresentation)
        controller.show(model: model, relativeTo: nil, presentingCreateForm: true)
        #expect(model.pendingCreatePresentation)

        controller.dismiss()
    }

    private func makeModel(service: any GitWorktreeManaging) -> WorktreeManagerModel {
        WorktreeManagerModel(
            repositoryContext: .init(
                invocationRoot: URL(fileURLWithPath: "/tmp/repo"),
                canonicalCommonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
                displayName: "repo"
            ),
            service: service,
            groups: { [] },
            currentGroupID: { nil },
            focus: { _ in },
            addLocalSession: { _, _, _ in nil }
        )
    }
}

private final class CountingWorktreeListing: GitWorktreeManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation { .valid }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        lock.withLock { calls += 1 }
        return .success(.init(records: [], diagnostics: []))
    }

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome { .success([]) }
    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> Bool { true }
    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome { .failure(.spawnFailure) }
}
