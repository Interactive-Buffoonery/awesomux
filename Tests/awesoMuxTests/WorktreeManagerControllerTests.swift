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
        let gateA = ListEntryGate()
        let serviceA = CountingWorktreeListing(gate: gateA)
        let modelA = makeModel(service: serviceA)
        let serviceB = CountingWorktreeListing()
        let modelB = makeModel(service: serviceB)
        let controller = WorktreeManagerController()

        controller.show(model: modelA, relativeTo: nil)
        // Block until A's refresh has genuinely entered `list(...)` and is
        // suspended there — proves the re-show below interrupts a real
        // in-flight call, not one that already raced to completion before
        // we got a chance to interrupt it.
        await gateA.waitUntilEntered()

        // Re-show with a DIFFERENT model while A is still suspended inside
        // `list` — this cancels A's task and starts B's on the same
        // controller/panel.
        controller.show(model: modelB, relativeTo: nil)
        await controller.waitForPendingRefresh()

        #expect(serviceB.callCount == 1)
        #expect(!controller.hasPendingRefresh)

        // Release A's suspended call and let its cancelled completion run.
        // `refresh()`'s post-`list()` guard has no further `await`, so once
        // A's task resumes on the main actor it settles in one hop; a few
        // yields drain that without a fixed sleep. If this ever flakes,
        // switch to capturing A's task directly instead of guessing hops.
        await gateA.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(modelA.state == .loading)
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
    private let gate: ListEntryGate?

    init(gate: ListEntryGate? = nil) {
        self.gate = gate
    }

    var callCount: Int { lock.withLock { calls } }

    func validateRepositoryIdentity(_ repositoryContext: GitRepositoryContext) async -> GitRepositoryIdentityValidation { .valid }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        lock.withLock { calls += 1 }
        if let gate {
            await gate.enter()
        }
        return .success(.init(records: [], diagnostics: []))
    }

    func branches(in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchesOutcome { .success([]) }
    func validateNewBranchName(_ name: String, in repositoryContext: GitRepositoryContext) async -> GitWorktreeBranchNameValidation {
        .valid
    }
    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome { .failure(.spawnFailure) }
}

/// Lets a test prove `list(in:)` is genuinely suspended mid-call — signaling
/// entry, then holding until explicitly released — instead of assuming a
/// synchronous-ish stub return leaves an interruptible window.
private actor ListEntryGate {
    private var hasEntered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    /// Called by the stub from inside `list(in:)`.
    func enter() async {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}
