import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Carbon.HIToolbox
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct TerminalPanelWindowTests {

    @Test(arguments: ["companion", "detached", "repeat", "panel sheet", "parent sheet", "modal", "foreign"])
    func panelPromotion(scenario: String) throws {
        let fixture = PromotionFixture(attachedToParent: scenario != "detached")
        if scenario == "companion" { fixture.parent.makeKeyAndOrderFront(nil) }
        let sheetOwner = scenario == "panel sheet" ? fixture.panel : (scenario == "parent sheet" ? fixture.parent : nil)
        let sheet = sheetOwner.map { fixture.beginSheet(on: $0) }
        defer { if let sheet, let sheetOwner { sheetOwner.endSheet(sheet) } }
        let extraWindow = ["modal", "foreign"].contains(scenario) ? fixture.makeWindow() : nil
        defer { extraWindow?.close() }
        let modal = scenario == "modal" ? extraWindow.map { fixture.application.beginModalSession(for: $0) } : nil
        defer { if let modal { fixture.application.endModalSession(modal) } }
        let receiver = KeyEventReceiver(frame: extraWindow?.contentView?.bounds ?? .zero)
        if scenario == "foreign", let extraWindow {
            extraWindow.contentView = receiver
            extraWindow.makeKeyAndOrderFront(nil)
            extraWindow.makeFirstResponder(receiver)
        }
        fixture.application.sendEvent(
            try fixture.event(
                windowNumber: scenario == "foreign" ? extraWindow?.windowNumber : nil,
                isARepeat: scenario == "repeat"))
        #expect(fixture.promotionCount == (["companion", "detached"].contains(scenario) ? 1 : 0))
        if scenario == "foreign" { #expect(receiver.receivedEventCount == 1) }
    }

    @Test("mouse input is forwarded without reading keyboard-only fields")
    func mouseInputIsForwardedWithoutReadingKeyboardFields() throws {
        let panel = TerminalPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let event = try #require(
            NSEvent.mouseEvent(
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

@MainActor
private final class KeyEventReceiver: NSView {
    private(set) var receivedEventCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        receivedEventCount += 1
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        receivedEventCount += 1
        return true
    }
}

@MainActor
private final class PromotionFixture {
    let application: AwesoMuxApplication
    let parent: NSWindow
    let panel: TerminalPanelWindow
    private(set) var promotionCount = 0

    init(attachedToParent: Bool) {
        application = Self.application()
        parent = Self.makeWindow()
        panel = TerminalPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.onPromote = { [weak self] in self?.promotionCount += 1 }
        panel.orderFrontRegardless()
        parent.orderFrontRegardless()
        if attachedToParent {
            parent.addChildWindow(panel, ordered: .above)
        }
    }

    isolated deinit {
        if panel.parent != nil {
            parent.removeChildWindow(panel)
        }
        panel.close()
        parent.close()
    }

    func event(windowNumber: Int? = nil, isARepeat: Bool = false) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber ?? panel.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: isARepeat,
                keyCode: UInt16(kVK_Return)
            ))
    }

    func beginSheet(on window: NSWindow) -> NSWindow {
        let sheet = makeWindow()
        window.beginSheet(sheet)
        return sheet
    }

    func makeWindow() -> NSWindow {
        Self.makeWindow()
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func application() -> AwesoMuxApplication {
        AwesoMuxApplication.installAsSharedApplicationIfNeeded()
    }
}
