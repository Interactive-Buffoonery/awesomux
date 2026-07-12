import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Terminal panel screen clamp")
struct TerminalPanelClampTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let size = CGSize(width: 520, height: 360)

    @Test("an on-screen origin is left untouched")
    func onScreenUnchanged() {
        let origin = CGPoint(x: 200, y: 200)
        #expect(TerminalPanelController.clampedToScreen(origin: origin, size: size, screen: screen) == origin)
    }

    @Test("an origin off the right/top edge is pulled fully back on-screen")
    func offEdgeClamped() {
        let clamped = TerminalPanelController.clampedToScreen(
            origin: CGPoint(x: 1900, y: 1050), size: size, screen: screen
        )
        #expect(clamped.x == screen.maxX - size.width)   // 1400
        #expect(clamped.y == screen.maxY - size.height)  // 720
    }

    @Test("an origin off the left/bottom edge is pinned to the screen minimum")
    func negativeClamped() {
        let clamped = TerminalPanelController.clampedToScreen(
            origin: CGPoint(x: -50, y: -50), size: size, screen: screen
        )
        #expect(clamped.x == screen.minX)
        #expect(clamped.y == screen.minY)
    }
}

@Suite("Terminal panel display-change resize")
struct TerminalPanelDisplayChangeResizeTests {
    private let defaultSize = CGSize(width: 480, height: 320)
    private let newScreen = CGRect(x: 2000, y: 0, width: 1440, height: 900)

    @Test("a drag to another monitor loads the stored size at the preserved, clamped origin")
    func dragLoadsStoredSizeAtClampedOrigin() {
        let stored = CGSize(width: 600, height: 400)
        let decision = TerminalPanelController.displayChangeResize(
            isResizing: false,
            userPositioned: true,
            storedSize: stored,
            defaultSize: defaultSize,
            currentOrigin: CGPoint(x: 2100, y: 100),
            newScreenVisibleFrame: newScreen
        )
        #expect(decision == .applyFrame(CGRect(origin: CGPoint(x: 2100, y: 100), size: stored)))
    }

    @Test("a user-positioned panel off the new screen edge is clamped back on")
    func dragClampsOffscreenOriginToNewScreen() {
        let stored = CGSize(width: 600, height: 400)
        let decision = TerminalPanelController.displayChangeResize(
            isResizing: false,
            userPositioned: true,
            storedSize: stored,
            defaultSize: defaultSize,
            currentOrigin: CGPoint(x: 9000, y: 9000),
            newScreenVisibleFrame: newScreen
        )
        #expect(decision == .applyFrame(CGRect(
            origin: CGPoint(x: newScreen.maxX - stored.width, y: newScreen.maxY - stored.height),
            size: stored
        )))
    }

    @Test("a user-positioned panel with no stored size falls back to the mode default")
    func dragWithoutStoredSizeUsesDefault() {
        let decision = TerminalPanelController.displayChangeResize(
            isResizing: false,
            userPositioned: true,
            storedSize: nil,
            defaultSize: defaultSize,
            currentOrigin: CGPoint(x: 2100, y: 100),
            newScreenVisibleFrame: newScreen
        )
        #expect(decision == .applyFrame(CGRect(origin: CGPoint(x: 2100, y: 100), size: defaultSize)))
    }

    @Test("a live resize in flight skips the reload so the drag isn't clobbered")
    func midResizeSkips() {
        let decision = TerminalPanelController.displayChangeResize(
            isResizing: true,
            userPositioned: true,
            storedSize: CGSize(width: 600, height: 400),
            defaultSize: defaultSize,
            currentOrigin: CGPoint(x: 2100, y: 100),
            newScreenVisibleFrame: newScreen
        )
        #expect(decision == .skip)
    }

    @Test("an anchored panel re-anchors at the new display's stored size")
    func anchoredReanchors() {
        let stored = CGSize(width: 600, height: 400)
        let decision = TerminalPanelController.displayChangeResize(
            isResizing: false,
            userPositioned: false,
            storedSize: stored,
            defaultSize: defaultSize,
            currentOrigin: CGPoint(x: 2100, y: 100),
            newScreenVisibleFrame: newScreen
        )
        #expect(decision == .reanchor(size: stored))
    }
}
