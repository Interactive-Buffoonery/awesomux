import AppKit
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar semantic pane identity", .serialized)
@MainActor
struct SidebarSemanticPaneIdentityTests {
    @Test("split panes remain stable across position and host modes")
    func stablePanes() {
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: NSViewController(), detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.splitPaneViewsForTesting == [controller.sidebarPaneContainerForTesting, detail.view])
        controller.setSidebarPosition(.right)
        #expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        #expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
    }
}
