import AppKit
import Testing
@testable import awesoMux

@Suite("Window chrome button visibility")
@MainActor
struct WindowChromeButtonVisibilityTests {
    @Test("visible policy restores every standard title-bar control")
    func visiblePolicyRestoresStandardButtons() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        StandardWindowButtonVisibility.hidden.apply(to: window)
        StandardWindowButtonVisibility.visible.apply(to: window)

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(window.standardWindowButton(button)?.isHidden == false)
        }
    }
}
