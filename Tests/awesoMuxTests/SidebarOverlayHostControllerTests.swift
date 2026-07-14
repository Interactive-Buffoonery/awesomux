import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
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
        var accessibilityHiddenHistory: [Bool] = []
        override var acceptsFirstResponder: Bool { true }

        override func setAccessibilityHidden(_ accessibilityHidden: Bool) {
            recordedAccessibilityHidden = accessibilityHidden
            accessibilityHiddenHistory.append(accessibilityHidden)
            super.setAccessibilityHidden(accessibilityHidden)
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
    private final class LifetimeToken {}

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
        #expect(controller.overlayClipViewForTesting.accessibilityIsIgnored())
        #expect(!controller.overlayClipViewForTesting.isAccessibilityElement())
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

    @Test(
        "overlay to persistent handoff is one silent atomic geometry mutation",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func atomicOverlayToPersistentHandoff(position: AppearanceConfig.SidebarPosition) {
        let (controller, _, _) = makeController(position: position)
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
                .captureSidebarResponder,
                .querySidebarAccessibilityFocus,
                .handOffSidebarFocus,
                .beginNoActionsTransaction,
                .cancelOverlayGeneration,
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
        controller.setEdgeTrackingEnabled(false)
        controller.overlayContentViewForTesting.layer = nil

        controller.setPersistentSidebarVisible(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("hide queries AX and performs focus callback before geometry transaction")
    func hideExternalCallbacksPrecedeTransaction() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeFirstResponder(sidebar.view)
        var trace: [SidebarHostHandoffAction] = []
        var externalCallbackActionCounts: [Int] = []
        controller.handoffActionObserverForTesting = { trace.append($0) }
        controller.hasActiveSidebarAccessibilityFocus = {
            externalCallbackActionCounts.append(trace.count)
            return true
        }
        var handoffRequests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            handoffRequests.append(request)
            externalCallbackActionCounts.append(trace.count)
            return true
        }

        controller.setPersistentSidebarVisible(false)

        #expect(externalCallbackActionCounts == [2, 3])
        #expect(handoffRequests == [.init(requiresAccessibilityFocus: true)])
        #expect(controller.lastCapturedSidebarAccessibilityFocusForTesting)
        #expect(trace.firstIndex(of: .beginNoActionsTransaction) == 3)
        #expect(window.firstResponder !== sidebar.view)
    }

    @Test("persistent hide stays visible when required AX focus handoff fails")
    func persistentHideAbortsAfterFailedAccessibilityHandoff() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        var handoffRequests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            handoffRequests.append(request)
            return false
        }

        controller.setPersistentSidebarVisible(false)

        #expect(handoffRequests == [.init(requiresAccessibilityFocus: true)])
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!controller.isEdgeTrackingVisibleForTesting)
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
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        let midReveal: CGFloat = position == .left ? -120 : 120
        driver.presentationTranslation = midReveal
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == midReveal)
        driver.presentationTranslation = nil
        revealCompletion()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        let staleHide = driver.completions[1]
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        #expect(
            controller.hostPresentationState.titlebarTranslationX
                == SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position))
        let midHide: CGFloat = position == .left ? -180 : 180
        driver.presentationTranslation = midHide
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == midHide)
        driver.presentationTranslation = nil
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        staleHide()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        driver.completions[2]()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        driver.completions[3]()
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
        #expect(
            controller.hostPresentationState.titlebarTranslationX
                == SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position))
    }

    @Test("titlebar visible width follows presentation translation on both sides")
    func titlebarVisibleWidthFollowsPresentationTranslation() {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(presented: false, width: 300, position: .left)

        state.overlayPresentationTranslation = { -300 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
        state.overlayPresentationTranslation = { -180 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 120)
        state.overlayPresentationTranslation = { 0 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 300)
        state.overlayPresentationTranslation = { -180 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 120)

        state.overlayPresentationTranslation = { 180 }
        #expect(state.currentTitlebarVisibleWidth(position: .right) == 120)
    }

    @Test("titlebar visible width clamps invalid presentation geometry")
    func titlebarVisibleWidthClampsInvalidPresentationGeometry() {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(presented: true, width: 300, position: .left)

        state.overlayPresentationTranslation = { -600 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
        #expect(
            state.currentTitlebarVisibleWidth(position: .left, translation: .infinity) == 0)

        state.beginOverlayTransition(presented: true, width: .infinity, position: .right)
        state.overlayPresentationTranslation = { 0 }
        #expect(state.currentTitlebarVisibleWidth(position: .right) == 0)
    }

    @Test("Reduce Motion keeps titlebar and overlay transition targets instant")
    func reduceMotionTitlebarParity() {
        let (controller, _, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: true)
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == 0)

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: true)
        #expect(controller.hostPresentationState.titlebarTranslationX == 300)
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == 300)
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

    @Test("persistent disappearance preserves ownership, hides AX, and restores on attach")
    func persistentDisappearPreservesSidebar() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)

        controller.viewWillDisappear()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
        controller.viewWillAppear()
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.interactionObserverCountForTesting == 4)
    }

    @Test("window removal and re-add preserve persistent semantics and restore AX")
    func windowDetachAndReattach() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        var availabilityLosses = 0
        var edgeMoves = 0
        var edgeExits = 0
        var liveWidths = 0
        var commits = 0
        var focusHandoffs = 0
        var interactions: [Bool] = []
        controller.onTrackingAvailabilityLost = { availabilityLosses += 1 }
        controller.onEdgePointerMove = { _, _ in edgeMoves += 1 }
        controller.onEdgeExit = { edgeExits += 1 }
        controller.onLiveWidthChange = { _ in liveWidths += 1 }
        controller.onCommitWidth = { _ in commits += 1 }
        controller.onSidebarFocusHandoff = { _ in
            focusHandoffs += 1
            return true
        }
        controller.onSidebarInteractionChanged = { interactions.append($0) }
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        #expect(controller.interactionObserverCountForTesting == 4)

        window.contentView = NSView()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
        #expect(controller.interactionObserverCountForTesting == 0)
        #expect(!controller.isFinalizedForTesting)
        let lossesAfterDetach = availabilityLosses
        #expect(lossesAfterDetach > 0)

        window.contentView = controller.view

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.interactionObserverCountForTesting == 4)
        controller.simulateEdgePointerMoveForTesting(x: 10, width: 40)
        controller.simulateEdgeExitForTesting()
        controller.simulateTrackingAvailabilityLostForTesting()
        controller.setSidebarWidth(320)
        controller.simulateDividerDragCompletionForTesting()
        #expect(window.makeFirstResponder(sidebar.view))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        controller.setPersistentSidebarVisible(false)

        #expect(edgeMoves == 1)
        #expect(edgeExits == 1)
        #expect(liveWidths > 0)
        #expect(commits == 1)
        #expect(focusHandoffs == 1)
        #expect(interactions.first == true)
        #expect(availabilityLosses == lossesAfterDetach + 1)
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

    @Test("passive overlay reveal preserves the detail first responder")
    func passiveRevealPreservesResponder() {
        let driver = AnimationDriver()
        let (controller, _, detail) = makeControlledController(driver: driver)
        let responder = FirstResponderView()
        detail.view.addSubview(responder)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        #expect(window.makeFirstResponder(responder))
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(window.firstResponder === responder)
        driver.completions[0]()
        #expect(window.firstResponder === responder)
    }

    @Test(
        "collapsed rail tile coordinates survive overlay reparent on both sides",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func collapsedRailCoordinateStability(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, _) = makeController(position: position)
        controller.setSidebarWidth(SidebarWidthPolicy.collapsedWidth)
        let tile = NSView(
            frame: CGRect(x: 8, y: 123, width: SidebarWidthPolicy.collapsedWidth - 16, height: 44))
        sidebar.view.addSubview(tile)
        let before = sidebar.view.convert(tile.frame, to: controller.view)
        let beforeInward = position == .left ? before.maxX : before.minX

        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        let after = sidebar.view.convert(tile.frame, to: controller.view)
        let afterInward = position == .left ? after.maxX : after.minX

        #expect(after.origin.y == before.origin.y)
        #expect(afterInward == beforeInward)
    }

    @Test("AX descendants stay hidden until full reveal and hide before movement")
    func accessibilityExposurePhases() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        let recorder = sidebar.view as! AccessibilityRecordingView
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        #expect(recorder.recordedAccessibilityHidden)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(recorder.recordedAccessibilityHidden)
        driver.completions[0]()
        #expect(!recorder.recordedAccessibilityHidden)

        controller.hasActiveSidebarAccessibilityFocus = { true }
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        #expect(!recorder.recordedAccessibilityHidden)
        #expect(driver.requestCount == 1)

        controller.hasActiveSidebarAccessibilityFocus = { false }
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        #expect(recorder.recordedAccessibilityHidden)
        #expect(driver.requestCount == 2)
    }

    @Test("persistent handoff preserves focused AX descendant identity and ancestry")
    func persistentHandoffPreservesAccessibilityDescendant() {
        let (controller, sidebar, _) = makeController()
        let descendant = NSView()
        sidebar.view.addSubview(descendant)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        let identity = ObjectIdentifier(descendant)
        controller.sidebarAccessibilityFocusedElement = { descendant }

        controller.setPersistentSidebarVisible(true)

        #expect(ObjectIdentifier(descendant) == identity)
        #expect(descendant.isDescendant(of: sidebar.view))
        #expect(controller.lastPreservedSidebarAccessibilityElementForTesting)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
    }

    @Test("persistent handoff aborts before publication when AX ancestry breaks")
    func persistentHandoffRejectsBrokenAccessibilityAncestry() {
        let (controller, sidebar, _) = makeController()
        let descendant = NSView()
        sidebar.view.addSubview(descendant)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        controller.sidebarAccessibilityFocusedElement = { descendant }
        var persistentPublications = 0
        controller.hostPresentationState.onSettleForTesting = {
            if case .persistent = controller.hostPresentationState.mode {
                persistentPublications += 1
            }
        }
        controller.persistentHandoffBeforeAccessibilityValidationForTesting = {
            descendant.removeFromSuperview()
        }

        controller.setPersistentSidebarVisible(true)

        #expect(persistentPublications == 0)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(sidebar.view.superview === controller.overlayContentViewForTesting)
        #expect(!controller.overlayClipViewForTesting.isHidden)
        #expect(!controller.lastPreservedSidebarAccessibilityElementForTesting)
    }

    @Test("detach is idempotent, invalidates stale completion, and reattaches one monitor")
    func detachAndReattachLifecycle() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]
        #expect(controller.interactionObserverCountForTesting == 4)

        controller.settleDetached()
        controller.settleDetached()
        staleCompletion()

        #expect(controller.interactionObserverCountForTesting == 0)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.overlayClipViewForTesting.isHidden)
        #expect(controller.overlayContentViewForTesting.layer?.transform.m41 == 0)
        controller.viewWillAppear()
        controller.viewWillAppear()
        #expect(controller.interactionObserverCountForTesting == 4)
    }

    @Test("focused sidebar control and attributed menu retain until interaction ends")
    func focusedControlAndMenuRetention() {
        let (controller, sidebar, _) = makeController()
        let focus = FirstResponderView()
        sidebar.view.addSubview(focus)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        var changes: [Bool] = []
        controller.onSidebarInteractionChanged = { changes.append($0) }
        #expect(window.makeFirstResponder(focus))

        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        controller.sidebarPointerChanged(true)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.sidebarPointerChanged(false)
        #expect(changes == [true])

        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(changes == [true, false])
    }

    @Test("keyboard menu and live AX retention flow through grace to overlay removal")
    func interactionEndToEndRemoval() async throws {
        let suiteName = "SidebarOverlayHostControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let focus = FirstResponderView()
        let axElement = NSView()
        sidebar.view.addSubview(focus)
        sidebar.view.addSubview(axElement)
        var focusedAX: Any?
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAX },
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)
        focusedAX = axElement
        #expect(window.makeFirstResponder(focus))
        center.post(name: NSWindow.didUpdateNotification, object: window)
        controller.sidebarPointerChanged(true)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.sidebarPointerChanged(false)
        model.sidebarPointerChanged(false)
        model.trackingRegionExited()

        window.makeFirstResponder(nil)
        center.post(name: NSWindow.didUpdateNotification, object: window)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(model.isTemporarilyRevealed)
        controller.setOverlayPresentedImmediately(false)
        #expect(controller.hostModeForTesting == .overlay(width: 300))

        focusedAX = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { !model.isSidebarVisible })
        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
    }

    @Test("active interaction reports false exactly once across repeated lifecycle teardown")
    func teardownReportsFalseOnce() {
        let (controller, sidebar, _) = makeController()
        let focus = FirstResponderView()
        sidebar.view.addSubview(focus)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        var changes: [Bool] = []
        controller.onSidebarInteractionChanged = { changes.append($0) }
        #expect(window.makeFirstResponder(focus))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        controller.viewWillDisappear()
        controller.viewDidDisappear()

        #expect(changes == [true, false])
        #expect(controller.interactionObserverCountForTesting == 0)
    }

    @Test("detached controller releases after outward callbacks are cleared")
    func detachedControllerDeallocates() {
        weak var weakController: SidebarSplitController?
        weak var weakToken: LifetimeToken?
        autoreleasepool {
            let (controller, _, _) = makeController()
            weakController = controller
            let token = LifetimeToken()
            weakToken = token
            controller.onLiveWidthChange = { _ in _ = token }
            controller.onSidebarInteractionChanged = { _ in _ = token }
            controller.settleDetached()
            #expect(weakToken != nil)
        }
        #expect(weakController == nil)
        #expect(weakToken == nil)
    }

    @Test("representable dismantle releases never-loaded self-capturing controller")
    func neverLoadedDismantleDeallocates() {
        weak var weakController: SidebarSplitController?
        autoreleasepool {
            let controller = SidebarSplitController(
                sidebar: NSViewController(), detail: NSViewController())
            weakController = controller
            controller.onLiveWidthChange = { [controller] _ in _ = controller }
            controller.onSidebarInteractionChanged = { [controller] _ in _ = controller }

            SidebarSplitView<EmptyView, EmptyView>.dismantleNSViewController(
                controller, coordinator: ())
            #expect(controller.isFinalizedForTesting)
        }
        #expect(weakController == nil)
    }

    @Test("deinit reports active interaction false and releases controller")
    func activeControllerDeinitCleansInteraction() {
        weak var weakController: SidebarSplitController?
        var changes: [Bool] = []
        autoreleasepool {
            let (controller, sidebar, _) = makeController()
            weakController = controller
            let focus = FirstResponderView()
            sidebar.view.addSubview(focus)
            let window = NSWindow(
                contentRect: controller.view.bounds, styleMask: [], backing: .buffered,
                defer: false)
            window.contentView = controller.view
            controller.onSidebarInteractionChanged = { changes.append($0) }
            #expect(window.makeFirstResponder(focus))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            #expect(changes == [true])
        }
        #expect(weakController == nil)
        #expect(changes == [true, false])
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

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 10_000) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
