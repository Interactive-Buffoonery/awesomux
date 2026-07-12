import AppKit
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct TerminalPanelWindowTests {
    @Test("mouse input is forwarded without reading keyboard-only fields")
    func mouseInputIsForwardedWithoutReadingKeyboardFields() throws {
        let panel = TerminalPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 492, y: 338),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        panel.sendEvent(event)
    }
}
