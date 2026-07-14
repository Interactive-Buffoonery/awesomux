import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

/// SwiftUI bridge to the native `SidebarSplitController` (INT-535).
///
/// Hosts the sidebar and detail SwiftUI panes inside a plain `NSViewController` that
/// owns a bare `NSSplitView`, so the divider drag is a real AppKit live resize. Width
/// feedback is surfaced as two callbacks rather than a single per-frame `@State`
/// binding: `onLiveWidthChange` (per drag tick → a titlebar-only `@Observable`) and
/// `onCommitWidth` (drag end → persists the width).
struct SidebarSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let terminalMinimumWidth: CGFloat
    /// Initial divider position (the persisted width). Applied once.
    let initialWidth: CGFloat
    /// Channel for `ContentView` to command the divider (the `⌘\` toggle).
    let proxy: SidebarSplitProxy
    let hostPresentation: SidebarHostPresentationState
    var position: AppearanceConfig.SidebarPosition = .left
    var initiallyHidden = false
    var edgeTrackingEnabled = false
    var onLiveWidthChange: ((CGFloat) -> Void)?
    var onCommitWidth: ((CGFloat) -> Void)?
    var onSidebarFocusHandoff: (() -> Bool)?
    var onEdgePointerMove: ((CGFloat, CGFloat) -> Void)?
    var onEdgeExit: (() -> Void)?
    var onTrackingAvailabilityLost: (() -> Void)?
    var onSidebarInteractionChanged: ((Bool) -> Void)?
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> SidebarSplitController {
        let controller = SidebarSplitController(
            sidebar: NSHostingController(rootView: sidebar()),
            detail: NSHostingController(rootView: detail())
        )
        controller.terminalMinimumWidth = terminalMinimumWidth
        controller.onLiveWidthChange = onLiveWidthChange
        controller.onCommitWidth = onCommitWidth
        controller.onSidebarFocusHandoff = onSidebarFocusHandoff
        controller.onEdgePointerMove = onEdgePointerMove
        controller.onEdgeExit = onEdgeExit
        controller.onTrackingAvailabilityLost = onTrackingAvailabilityLost
        controller.onSidebarInteractionChanged = onSidebarInteractionChanged
        controller.hostPresentationState = hostPresentation
        controller.setSidebarPosition(position)
        controller.setSidebarHidden(initiallyHidden)
        controller.setSidebarWidth(initialWidth)
        controller.setEdgeTrackingEnabled(edgeTrackingEnabled)
        proxy.setSelectedWidth = { [weak controller] width in
            controller?.setSelectedSidebarWidth(width)
        }
        proxy.setOverlayVisible = { [weak controller] visible, transition, reduceMotion in
            controller?.setOverlayPresented(
                visible, transition: transition, reduceMotion: reduceMotion)
        }
        proxy.setPersistentVisible = { [weak controller] visible in
            controller?.setPersistentSidebarVisible(visible)
        }
        proxy.setPosition = { [weak controller] position in controller?.setSidebarPosition(position) }
        proxy.sidebarPointerChanged = { [weak controller] inside in
            controller?.sidebarPointerChanged(inside)
        }
        return controller
    }

    func updateNSViewController(_ controller: SidebarSplitController, context: Context) {
        controller.onLiveWidthChange = onLiveWidthChange
        controller.onCommitWidth = onCommitWidth
        controller.onSidebarFocusHandoff = onSidebarFocusHandoff
        controller.onEdgePointerMove = onEdgePointerMove
        controller.onEdgeExit = onEdgeExit
        controller.onTrackingAvailabilityLost = onTrackingAvailabilityLost
        controller.onSidebarInteractionChanged = onSidebarInteractionChanged
        precondition(controller.hostPresentationState === hostPresentation)
        // Re-host each pane's root view so @Observable / @Bindable updates inside the
        // panes propagate. SwiftUI diffs the new root against the old, so this is
        // cheap when nothing changed; it does not rebuild the hosting controllers.
        //
        // The casts below depend on `sidebar()`/`detail()` producing a STABLE
        // concrete `some View` type across make/update. If either builder ever
        // returns a different outermost generic type between renders (e.g. an
        // unerased `if/else` at the body root), the cast fails silently and that
        // pane stops updating. Both builders are stable today; keep them so (don't
        // erase to `AnyView` — that loses SwiftUI diffing — and don't branch the
        // root type).
        if let host = controller.sidebarViewController as? NSHostingController<Sidebar> {
            host.rootView = sidebar()
        }
        if let host = controller.detailViewController as? NSHostingController<Detail> {
            host.rootView = detail()
        }
    }

    static func dismantleNSViewController(
        _ controller: SidebarSplitController,
        coordinator: Void
    ) {
        controller.finalizeOwnedLifecycle()
    }
}
