import AppKit
import AwesoMuxConfig
import AwesoMuxCore
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

    @Test("overlay width selection updates live width without divider geometry")
    func overlayWidthSelectionIsCompositorOnly() {
        let (controller, _, detail) = makeController()
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.setOverlayPresentedImmediately(true)
        let dividerIntents = controller.dividerIntentCountForTesting
        let detailFrame = detail.view.frame
        var liveWidths: [CGFloat] = []
        controller.onLiveWidthChange = { liveWidths.append($0) }

        controller.setSelectedSidebarWidth(SidebarWidthPolicy.collapsedWidth)

        #expect(controller.dividerIntentCountForTesting == dividerIntents)
        #expect(detail.view.frame == detailFrame)
        #expect(liveWidths == [SidebarWidthPolicy.collapsedWidth])
        #expect(
            controller.hostPresentationState.mode
                == .overlay(width: SidebarWidthPolicy.collapsedWidth))
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

        controller.setPersistentSidebarVisible(true)
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
    }

    @Test("overlay to persistent handoff is one silent atomic geometry mutation")
    func atomicOverlayToPersistentHandoff() {
        let (controller, _, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.setOverlayPresentedImmediately(true)
        var trace: [SidebarHostHandoffAction] = []
        var publications = 0
        var livePublications = 0
        var callbackActionCounts: [Int] = []
        controller.handoffActionObserverForTesting = { trace.append($0) }
        controller.hostPresentationState.onSettleForTesting = {
            publications += 1
            callbackActionCounts.append(trace.count)
        }
        controller.onLiveWidthChange = { _ in
            livePublications += 1
            callbackActionCounts.append(trace.count)
        }
        let dividerIntentsBefore = controller.dividerIntentCountForTesting

        controller.setPersistentSidebarVisible(true)

        #expect(
            trace == [
                .beginNoActionsTransaction,
                .cancelOverlayGeneration,
                .captureSidebarResponder,
                .removeOverlayAnimation,
                .reparentHostToSplitContainer,
                .setPersistentState,
                .applySingleDividerIntent(300),
                .settleLayout,
                .clearTransform,
                .hideOverlayContainer,
                .restoreSidebarResponder,
                .endNoActionsTransaction,
            ])
        #expect(publications == 1)
        #expect(livePublications == 1)
        #expect(callbackActionCounts == [12, 12])
        #expect(controller.dividerIntentCountForTesting - dividerIntentsBefore == 1)
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
    }

    @Test(
        "persistent to hidden handoff is one silent atomic collapse",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func atomicPersistentToHiddenHandoff(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, _) = makeController(position: position)
        controller.setSidebarWidth(300)
        var trace: [SidebarHostHandoffAction] = []
        var callbackActionCounts: [Int] = []
        var livePublications = 0
        controller.handoffActionObserverForTesting = { trace.append($0) }
        controller.hostPresentationState.onSettleForTesting = {
            callbackActionCounts.append(trace.count)
        }
        controller.onLiveWidthChange = { _ in livePublications += 1 }
        let dividerIntentsBefore = controller.dividerIntentCountForTesting

        controller.setPersistentSidebarVisible(false)

        #expect(
            trace == [
                .beginNoActionsTransaction,
                .cancelOverlayGeneration,
                .captureSidebarResponder,
                .captureSidebarAccessibility,
                .handOffSidebarFocus,
                .removeOverlayAnimation,
                .reparentHostToSplitContainer,
                .setHiddenState,
                .applySingleCollapseIntent,
                .settleLayout,
                .clearTransform,
                .hideOverlayContainer,
                .hideSidebarAccessibility,
                .endNoActionsTransaction,
                .enableEdgeTracking,
            ])
        #expect(callbackActionCounts == [14])
        #expect(livePublications == 0)
        #expect(controller.dividerIntentCountForTesting - dividerIntentsBefore == 1)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect(controller.overlayContentViewForTesting.layer?.transform.m41 == 0)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("persistent show fails closed when handoff prerequisites disappear")
    func persistentShowRollback() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.overlayContentViewForTesting.layer = nil

        controller.setPersistentSidebarVisible(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("persistent hide fails closed when handoff prerequisites disappear")
    func persistentHideRollback() {
        let (controller, sidebar, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.overlayContentViewForTesting.layer = nil

        controller.setPersistentSidebarVisible(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test(
        "authoritative host state survives overlay phases and stale completion",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func authoritativeOverlayPhases(position: AppearanceConfig.SidebarPosition) {
        let driver = AnimationDriver()
        let (controller, _, _) = makeControlledController(position: position, driver: driver)
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let revealCompletion = driver.completions[0]
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 300)
        revealCompletion()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        let staleHide = driver.completions[1]
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        staleHide()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        driver.completions[2]()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        driver.completions[3]()
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
    }

    @Test("settled persistent and hidden commands are idempotent")
    func settledVisibilityCommandsAreIdempotent() {
        let (controller, _, _) = makeController()
        controller.setSidebarWidth(300)
        var trace: [SidebarHostHandoffAction] = []
        controller.handoffActionObserverForTesting = { trace.append($0) }

        controller.setPersistentSidebarVisible(true)
        #expect(trace.isEmpty)

        controller.setPersistentSidebarVisible(false)
        trace.removeAll()
        controller.setPersistentSidebarVisible(false)
        #expect(trace.isEmpty)
        #expect(controller.hostModeForTesting == .hidden)
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

    @Test("persistent controller disappearance preserves visible ownership")
    func persistentDisappearPreservesSidebar() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)

        controller.viewWillDisappear()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
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
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
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
