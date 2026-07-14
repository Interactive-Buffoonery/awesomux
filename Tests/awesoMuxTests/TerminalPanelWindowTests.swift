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

    @Test("queued pointer event cannot re-key an evicted floating slot")
    func queuedPointerEventCannotRekeyEvictedFloatingSlot() throws {
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
        let queuedEvent = try #require(
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

        controller.evictFloatingSlot(for: workspace.id)
        panel.sendEvent(queuedEvent)

        #expect(!panel.isPointerRekeyEnabled)
        #expect(!panel.isKeyWindow)
        #expect(!controller.isPanelFocused)

        controller.show(
            relativeTo: nil,
            sessionStore: sessionStore,
            ghosttyRuntime: runtime,
            appSettingsStore: settingsStore,
            announcement: .none
        )

        #expect(panel.isPointerRekeyEnabled)
        #expect(panel.canBecomeKey)
    }
}
