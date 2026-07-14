import AppKit
import AwesoMuxConfig
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar overlay host", .serialized)
@MainActor
struct SidebarOverlayHostControllerTests {
    private struct RootFixture: View {
        let value: String
        var body: some View { Text(value) }
    }

    enum UpdateMode: Equatable, Sendable {
        case hidden
        case overlay
        case midAnimation
        case persistent
    }

    private final class AccessibilityRecordingView: NSView {
        var recordedAccessibilityHidden = false

        override func setAccessibilityHidden(_ accessibilityHidden: Bool) {
            recordedAccessibilityHidden = accessibilityHidden
            super.setAccessibilityHidden(accessibilityHidden)
        }
    }

    private func makeController(position: AppearanceConfig.SidebarPosition = .left) -> (
        SidebarSplitController, NSViewController, NSViewController
    ) {
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.setSidebarPosition(position)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, sidebar, detail)
    }

    @Test(
        "overlay reparents the one live sidebar host while split stays hidden", arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func oneHostOverlay(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, detail) = makeController(position: position)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let detailFrame = detail.view.frame

        controller.setOverlayPresentedImmediately(true)

        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(sidebar.view.superview === controller.overlayContentViewForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.sidebarSplitPaneWidthForTesting == 0)
        #expect(detail.view.frame == detailFrame)
        #expect(
            controller.view.subviews.firstIndex(of: detail.view.superview!)! < controller.view.subviews.firstIndex(
                of: controller.overlayClipViewForTesting)!)
        if position == .left {
            #expect(controller.overlayClipViewForTesting.frame.minX == 0)
        } else {
            #expect(controller.overlayClipViewForTesting.frame.maxX == controller.view.bounds.maxX)
        }
    }

    @Test("dismissing overlay returns the same host to the hidden semantic pane")
    func dismissOverlay() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)

        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.overlayClipViewForTesting.isHidden)
    }

    @Test("reasserting hidden dismisses a presented overlay into stable hidden ownership")
    func repeatedHiddenDismissesOverlay() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)

        controller.setSidebarHidden(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
    }

    @Test("overlay presentation fails closed when content layer is unavailable")
    func missingLayerFailsClosed() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.overlayContentViewForTesting.wantsLayer = false
        controller.overlayContentViewForTesting.layer = nil

        controller.setOverlayPresentedImmediately(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
    }

    @Test(
        "root updates preserve the same sidebar host and presentation ownership",
        arguments: [UpdateMode.hidden, .overlay, .midAnimation, .persistent])
    func sameHostRootUpdate(mode: UpdateMode) throws {
        let sidebar = NSHostingController(rootView: RootFixture(value: "old"))
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        switch mode {
        case .hidden:
            controller.setSidebarHidden(true)
        case .overlay, .midAnimation:
            controller.setSidebarHidden(true)
            controller.setOverlayPresentedImmediately(true)
            if mode == .midAnimation {
                controller.overlayContentViewForTesting.layer?.setAffineTransform(
                    CGAffineTransform(translationX: -150, y: 0))
            }
        case .persistent:
            break
        }
        let identity = ObjectIdentifier(controller.sidebarViewController)
        let parent = sidebar.view.superview
        let hostMode = controller.hostModeForTesting
        let paneViews = controller.splitPaneViewsForTesting
        let detailFrame = detail.view.frame

        // This is the operation performed by SidebarSplitView.updateNSViewController.
        sidebar.rootView = RootFixture(value: "new")

        #expect(ObjectIdentifier(controller.sidebarViewController) == identity)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(sidebar.view.superview === parent)
        #expect(controller.hostModeForTesting == hostMode)
        #expect(controller.splitPaneViewsForTesting == paneViews)
        #expect(detail.view.frame == detailFrame)
        #expect(sidebar.rootView.value == "new")
    }
}
