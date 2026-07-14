import AppKit
import AwesoMuxConfig
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar overlay host", .serialized)
@MainActor
struct SidebarOverlayHostControllerTests {
    private final class AnimationDriver {
        var presentationTranslation: CGFloat?
        var completions: [() -> Void] = []
        var requestCount = 0
    }
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

    private func makeControlledController(
        position: AppearanceConfig.SidebarPosition = .left,
        driver: AnimationDriver
    ) -> (SidebarSplitController, NSViewController, NSViewController) {
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            overlayPresentationTranslation: { driver.presentationTranslation },
            overlayAnimationRunner: { _, _, _, _, completion in
                driver.requestCount += 1
                driver.completions.append(completion)
            })
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

    @Test(
        "animated overlay changes compositor transform without split geometry",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func compositorOnlyAnimation(position: AppearanceConfig.SidebarPosition) {
        let (controller, _, detail) = makeController(position: position)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let detailFrame = detail.view.frame
        let splitWidth = controller.sidebarSplitPaneWidthForTesting

        controller.setOverlayPresented(
            true, transition: .hover, reduceMotion: false)

        #expect(
            controller.overlayContentViewForTesting.layer?.animation(
                forKey: SidebarOverlayAnimator.animationKey) != nil)
        #expect(controller.overlayClipViewForTesting.frame.width == 300)
        #expect(controller.overlayContentViewForTesting.frame.size == CGSize(width: 300, height: 800))
        #expect(controller.sidebarSplitPaneWidthForTesting == splitWidth)
        #expect(detail.view.frame == detailFrame)
    }

    @Test("Reduce Motion reveals immediately with aligned hit testing")
    func reduceMotionReveal() {
        let (controller, _, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: true)

        #expect(
            controller.overlayContentViewForTesting.layer?.animation(
                forKey: SidebarOverlayAnimator.animationKey) == nil)
        #expect(controller.overlayContentViewForTesting.layer?.transform.m41 == 0)
        #expect(controller.overlayClipViewForTesting.presentationTranslationX() == 0)
    }

    @Test("persistent restore invalidates an in-flight overlay completion")
    func persistentRestoreCancelsOverlay() async throws {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)

        controller.setSidebarHidden(false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
    }

    @Test("controller detach invalidates stale animation completion")
    func detachInvalidatesCompletion() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]

        controller.viewWillDisappear()
        staleCompletion()

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
    }

    @Test("active accessibility focus retains overlay and cancels hide")
    func accessibilityFocusRetainsOverlay() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        driver.completions[0]()
        controller.hasActiveSidebarAccessibilityFocus = { true }
        let requestsBeforeHide = driver.requestCount

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)

        #expect(driver.requestCount == requestsBeforeHide)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
    }

    @Test("side change cancels old animation and permits fresh mirrored reveal")
    func sideChangeLifecycle() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]

        controller.setSidebarPosition(.right)
        staleCompletion()

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayContentViewForTesting.layer?.transform.m41 == 0)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(driver.requestCount == 2)
        #expect(controller.overlayClipViewForTesting.frame.maxX == controller.view.bounds.maxX)
        #expect(controller.overlayContentViewForTesting.layer?.transform.m41 == 0)
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
