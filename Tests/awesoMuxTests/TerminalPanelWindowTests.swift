import AppKit
import AwesoMuxConfig
import AwesoMuxCore
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

    @Test("queued pointer events cannot re-key an evicted floating slot")
    func queuedPointerEventsCannotRekeyEvictedFloatingSlot() throws {
        let workspace = TerminalSession(
            title: "main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        let sessionStore = SessionStore(groups: [
            SessionGroup(name: "Workspaces", sessions: [workspace])
        ])
        let runtime = GhosttyRuntime()
        let settingsStore = AppSettingsStore(legacySnapshotProvider: { nil })
        let controller = TerminalPanelController(mode: .floating)

        controller.show(
            relativeTo: nil,
            sessionStore: sessionStore,
            ghosttyRuntime: runtime,
            appSettingsStore: settingsStore,
            announcement: .none
        )
        let panel = try #require(controller.ownedWindow as? TerminalPanelWindow)
        defer {
            controller.evictFloatingSlot(for: workspace.id)
            panel.close()
        }
        let controllerKeyStateChanged = panel.onKeyStateChanged
        var trueFocusCallbackCount = 0
        panel.onKeyStateChanged = { isKey in
            if isKey {
                trueFocusCallbackCount += 1
            }
            controllerKeyStateChanged?(isKey)
        }
        panel.becomeKey()

        #expect(controller.isPanelFocused)
        #expect(trueFocusCallbackCount == 1)

        let queuedMouseEvent = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 10, y: 10),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        let scrollEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            ))
        scrollEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        let queuedMomentumEvent = try #require(NSEvent(cgEvent: scrollEvent))

        panel.resignKey()

        #expect(!controller.isPanelFocused)

        controller.evictFloatingSlot(for: workspace.id)
        panel.sendEvent(queuedMouseEvent)
        panel.sendEvent(queuedMomentumEvent)

        #expect(!panel.isPointerRekeyEnabled)
        #expect(!panel.canBecomeKey)
        #expect(!controller.isPanelFocused)
        #expect(trueFocusCallbackCount == 1)

        controller.show(
            relativeTo: nil,
            sessionStore: sessionStore,
            ghosttyRuntime: runtime,
            appSettingsStore: settingsStore,
            announcement: .none
        )
        panel.becomeKey()

        #expect(panel.isPointerRekeyEnabled)
        #expect(panel.canBecomeKey)
        #expect(controller.isPanelFocused)
        #expect(trueFocusCallbackCount == 2)
    }
}
