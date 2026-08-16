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
        var presentationCount = 0
        let controller = makeController { _ in presentationCount += 1 }

        controller.show(model: model, relativeTo: nil)
        #expect(controller.isVisible)
        #expect(presentationCount == 1)

        controller.dismiss()
        #expect(!controller.isVisible)
        #expect(!controller.hasPendingRefresh)

        controller.toggle(model: model, relativeTo: nil)
        #expect(controller.isVisible)
        #expect(presentationCount == 2)
        controller.toggle(model: model, relativeTo: nil)
        #expect(!controller.isVisible)
        #expect(presentationCount == 2)
    }

    @Test("show performs one refresh and starts no polling timer")
    func noPolling() async {
        _ = NSApplication.shared
        let service = CountingWorktreeListing()
        let model = makeModel(service: service)
        let controller = makeController()

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
        let controller = makeController()

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
        let controller = makeController()

        #expect(!model.pendingCreatePresentation)
        controller.show(model: model, relativeTo: nil, presentingCreateForm: true)
        #expect(model.pendingCreatePresentation)

        controller.dismiss()
    }

    @Test("dismiss refuses to close during an in-flight create, then succeeds once it settles")
    func dismissRefusedDuringInFlightCreateThenSucceeds() async {
        _ = NSApplication.shared
        let createGate = ListEntryGate()
        let service = CountingWorktreeListing(createGate: createGate)
        let model = makeModel(service: service)
        var capturedPanel: FloatingSwiftUIPanelWindow?
        let controller = makeController { panel in
            capturedPanel = panel
            panel.orderFront(nil)
        }

        controller.show(model: model, relativeTo: nil)
        await controller.waitForPendingRefresh()
        guard let panel = capturedPanel else {
            Issue.record("Expected the panel to be presented")
            return
        }

        let createTask = Task { await model.create(request: createRequest()) }
        // Block until `create` has genuinely reached `service.create(_:)` and
        // is suspended there — proves the guard below races a real in-flight
        // submission, not one that already finished before we got a chance to
        // interrupt it (same rationale as `rapidReShowReplacesRefreshTask`).
        await createGate.waitUntilEntered()
        #expect(model.createSubmissionState.isSubmitting)

        controller.dismiss()
        #expect(controller.isVisible)
        #expect(panel.isVisible)

        await createGate.release()
        _ = await createTask.value
        #expect(!model.createSubmissionState.isSubmitting)

        controller.dismiss()
        #expect(!controller.isVisible)
        #expect(!panel.isVisible)
    }

    private func createRequest() -> GitWorktreeCreateRequest {
        .init(
            repositoryContext: .init(
                invocationRoot: URL(fileURLWithPath: "/tmp/repo"),
                canonicalCommonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
                displayName: "repo"
            ),
            mode: .existingBranch("feature/gh-371"),
            targetPath: URL(fileURLWithPath: "/tmp/worktrees/gh-371"),
            destinationWorkspaceGroupID: UUID()
        )
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

    private func makeController(
        presentPanel: @escaping @MainActor (FloatingSwiftUIPanelWindow) -> Void = { _ in }
    ) -> WorktreeManagerController {
        WorktreeManagerController(presentPanel: presentPanel)
    }
}

private final class CountingWorktreeListing: GitWorktreeManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let gate: ListEntryGate?
    private let createGate: ListEntryGate?

    init(gate: ListEntryGate? = nil, createGate: ListEntryGate? = nil) {
        self.gate = gate
        self.createGate = createGate
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
    func create(_ request: GitWorktreeCreateRequest) async -> GitWorktreeCreateOutcome {
        if let createGate {
            await createGate.enter()
        }
        return .failure(.spawnFailure)
    }
}

/// Lets a test prove a stubbed async call (`list(in:)` or `create(_:)`) is
/// genuinely suspended mid-call — signaling entry, then holding until
/// explicitly released — instead of assuming a synchronous-ish stub return
/// leaves an interruptible window.
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

    /// Called by the stub from inside the gated call.
    func enter() async {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}
