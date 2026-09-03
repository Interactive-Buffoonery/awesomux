import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Branch changes coordinator refresh state")
@MainActor
struct BranchChangesCoordinatorTests {
    @Test("begin marks the pane as refreshing")
    func beginMarksThePane() {
        let coordinator = BranchChangesCoordinator()
        let pane = UUID()
        #expect(!coordinator.refreshingPaneIDs.contains(pane))
        _ = coordinator.begin(paneID: pane)
        #expect(coordinator.refreshingPaneIDs.contains(pane))
    }

    @Test("finishing the last ticket clears the pane")
    func finishClearsThePane() {
        let coordinator = BranchChangesCoordinator()
        let pane = UUID()
        let ticket = coordinator.begin(paneID: pane)
        coordinator.finish(ticket, paneID: pane)
        #expect(!coordinator.refreshingPaneIDs.contains(pane))
    }

    @Test("a superseded ticket finishing leaves the newer run marked")
    func supersededFinishKeepsTheNewerRun() {
        let coordinator = BranchChangesCoordinator()
        let pane = UUID()
        let first = coordinator.begin(paneID: pane)
        let second = coordinator.begin(paneID: pane)
        coordinator.finish(first, paneID: pane)
        #expect(coordinator.refreshingPaneIDs.contains(pane))
        coordinator.finish(second, paneID: pane)
        #expect(!coordinator.refreshingPaneIDs.contains(pane))
    }
}
