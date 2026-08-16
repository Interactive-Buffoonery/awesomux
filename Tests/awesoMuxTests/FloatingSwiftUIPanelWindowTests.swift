import AppKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Floating SwiftUI panel window")
@MainActor
struct FloatingSwiftUIPanelWindowTests {
    @Test("default initializer installs the titlebar-backed floating-panel recipe")
    func defaultInitializerInstallsTitlebarBackedRecipe() {
        let panel = makePanel()
        defer { panel.close() }

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.fullSizeContentView))
        #expect(panel.titleVisibility == .hidden)
        #expect(panel.titlebarAppearsTransparent)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.isOpaque)
        #expect(panel.hasShadow)
        // Hide when the app is backgrounded so the panel never floats over
        // other apps when it isn't the key window.
        #expect(panel.hidesOnDeactivate)
        #expect(!panel.isMovableByWindowBackground)
        #expect(!panel.isReleasedWhenClosed)
    }

    @Test("standard window buttons stay hidden by default")
    func standardWindowButtonsStayHiddenByDefault() {
        let panel = makePanel()
        defer { panel.close() }

        // The command palette is a fifth user of this class and must never
        // grow traffic lights, which is why the opt-in defaults off.
        #expect(!panel.showsStandardWindowButtons)
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)
    }

    @Test("opting into standard window buttons reveals them without enabling minimize")
    func optingIntoStandardWindowButtonsRevealsThemWithoutEnablingMinimize() {
        let panel = makePanel()
        defer { panel.close() }

        // Set AFTER init: `configureFloatingPanelChrome()` runs during `init`,
        // so this only works because the property re-applies on `didSet`.
        panel.showsStandardWindowButtons = true

        #expect(panel.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == false)
        // Unhiding must not touch the style mask. `.miniaturizable` is what
        // keeps minimize rendering disabled-gray; unioning it in (the way
        // `StandardWindowButtonVisibility.visible` does) would silently enable
        // minimize on a fixed-size panel.
        #expect(!panel.styleMask.contains(.miniaturizable))
        #expect(panel.styleMask == FloatingSwiftUIPanelWindow.swiftUIFloatingStyleMask)
        // Close is the only live control. Zoom has nothing to zoom on a panel
        // pinned by `setFixedContentSize`, but left enabled it renders green
        // and offers the tiling menu on hover, which would try to move a
        // floating fixed-size panel into a slot it cannot occupy.
        #expect(panel.standardWindowButton(.zoomButton)?.isEnabled == false)
        #expect(panel.standardWindowButton(.closeButton)?.isEnabled == true)
    }

    @Test("native close routes to the dismiss handler instead of closing the reused panel")
    func nativeCloseRoutesToDismissHandlerInsteadOfClosingReusedPanel() {
        let panel = makePanel()
        defer { panel.close() }

        var dismissCount = 0
        panel.onDismiss = { dismissCount += 1 }
        panel.orderFront(nil)
        panel.performClose(nil)

        #expect(dismissCount == 1)
        // The stub only counts, so nothing here orders the panel out. That is
        // the point: the window is still visible purely because
        // `performClose(_:)` delegated instead of closing itself. Ordering out
        // is the controller's job, and a `super.performClose` sneaking back in
        // would take that decision away from it.
        #expect(panel.isVisible)
    }

    @Test("hosting helper installs first-mouse SwiftUI hosting view")
    func hostingHelperInstallsFirstMouseSwiftUIHostingView() {
        let panel = makePanel()
        defer { panel.close() }

        let hosting = panel.hostSwiftUIContent(Text("Hello"))

        #expect(panel.contentViewController === hosting)
        #expect(hosting.view is FloatingPanelHostingView<AnyView>)
        #expect(hosting.view.acceptsFirstResponder)
        #expect(hosting.view.canBecomeKeyView)
        #expect(!hosting.view.mouseDownCanMoveWindow)
        #expect(hosting.view.acceptsFirstMouse(for: nil as NSEvent?))
    }

    @Test("fixed content size constrains user resizing while retaining resizable style")
    func fixedContentSizeConstrainsUserResizingWhileRetainingResizableStyle() {
        let panel = makePanel(size: CGSize(width: 320, height: 200))
        defer { panel.close() }

        let fixedSize = CGSize(width: 260, height: 140)
        panel.setFixedContentSize(fixedSize)

        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.contentMinSize == fixedSize)
        #expect(panel.contentMaxSize == fixedSize)
    }

    @Test("focus helper makes hosted SwiftUI view first responder")
    func focusHelperMakesHostedSwiftUIViewFirstResponder() {
        let panel = makePanel()
        defer { panel.close() }

        let hosting = panel.hostSwiftUIContent(Text("Hello"))
        panel.focusHostedContent()

        #expect(panel.firstResponder === hosting.view)
    }

    private func makePanel(
        size: CGSize = CGSize(width: 320, height: 200)
    ) -> FloatingSwiftUIPanelWindow {
        FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            backing: .buffered,
            defer: false
        )
    }
}
