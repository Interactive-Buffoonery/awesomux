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
        for _ in 0..<20 where controller.hasPendingRefresh {
            await Task.yield()
        }
        #expect(service.callCount == 1)
        #expect(!controller.hasPendingRefresh)

        for _ in 0..<20 { await Task.yield() }
        #expect(service.callCount == 1)
        controller.dismiss()
    }

    private func makeModel(service: any GitWorktreeListing) -> WorktreeManagerModel {
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

private final class CountingWorktreeListing: GitWorktreeListing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func list(in repositoryContext: GitRepositoryContext) async -> GitWorktreeListOutcome {
        lock.withLock { calls += 1 }
        return .success(.init(records: [], diagnostics: []))
    }
}
