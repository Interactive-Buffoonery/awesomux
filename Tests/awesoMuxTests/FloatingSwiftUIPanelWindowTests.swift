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
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)
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
