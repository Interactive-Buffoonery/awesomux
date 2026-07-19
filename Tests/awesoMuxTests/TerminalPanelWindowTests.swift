import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Carbon.HIToolbox
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct TerminalPanelWindowTests {
    @Test("application installs the shared shortcut-routing subclass")
    func applicationInstallsSharedShortcutRoutingSubclass() {
        let application = AwesoMuxApplication.installAsSharedApplicationIfNeeded()

        #expect(NSApplication.shared === application)
        #expect(NSApplication.shared is AwesoMuxApplication)
        #expect(AwesoMuxApplication.installAsSharedApplicationIfNeeded() === application)
    }

    @Test("application promotes a Companion event when its parent is key")
    func applicationPromotesCompanionEventWhenParentIsKey() throws {
        let fixture = PromotionFixture(attachedToParent: true)
        fixture.parent.makeKeyAndOrderFront(nil)

        fixture.application.sendEvent(try fixture.event())

        #expect(fixture.promotionCount == 1)
    }

    @Test("application preserves detached terminal panel promotion")
    func applicationPreservesDetachedTerminalPanelPromotion() throws {
        let fixture = PromotionFixture(attachedToParent: false)

        fixture.application.sendEvent(try fixture.event())

        #expect(fixture.promotionCount == 1)
    }

    @Test("application does not promote repeated Command-Return")
    func applicationDoesNotPromoteRepeatedCommandReturn() throws {
        let fixture = PromotionFixture(attachedToParent: true)

        fixture.application.sendEvent(try fixture.event(isARepeat: true))

        #expect(fixture.promotionCount == 0)
    }

    @Test("application blocks promotion while the terminal panel owns a sheet")
    func applicationBlocksPromotionForTerminalPanelSheet() throws {
        let fixture = PromotionFixture(attachedToParent: true)
        let sheet = fixture.beginSheet(on: fixture.panel)
        defer { fixture.panel.endSheet(sheet) }

        fixture.application.sendEvent(try fixture.event())

        #expect(fixture.promotionCount == 0)
    }

    @Test("application blocks Companion promotion while its parent owns a sheet")
    func applicationBlocksCompanionPromotionForParentSheet() throws {
        let fixture = PromotionFixture(attachedToParent: true)
        let sheet = fixture.beginSheet(on: fixture.parent)
        defer { fixture.parent.endSheet(sheet) }

        fixture.application.sendEvent(try fixture.event())

        #expect(fixture.promotionCount == 0)
    }

    @Test("application blocks terminal panel promotion during an app-modal session")
    func applicationBlocksPromotionDuringAppModalSession() throws {
        let fixture = PromotionFixture(attachedToParent: true)
        let modalWindow = fixture.makeWindow()
        let session = fixture.application.beginModalSession(for: modalWindow)
        defer {
            fixture.application.endModalSession(session)
            modalWindow.close()
        }

        fixture.application.sendEvent(try fixture.event())

        #expect(fixture.promotionCount == 0)
    }

    @Test("application ignores Command-Return from a foreign window")
    func applicationIgnoresCommandReturnFromForeignWindow() throws {
        let fixture = PromotionFixture(attachedToParent: true)
        let foreignWindow = fixture.makeWindow()
        let receiver = KeyEventReceiver(frame: foreignWindow.contentView?.bounds ?? .zero)
        foreignWindow.contentView = receiver
        foreignWindow.makeKeyAndOrderFront(nil)
        foreignWindow.makeFirstResponder(receiver)
        defer { foreignWindow.close() }

        fixture.application.sendEvent(try fixture.event(windowNumber: foreignWindow.windowNumber))

        #expect(fixture.promotionCount == 0)
        #expect(receiver.receivedEventCount == 1)
    }

    @Test("promotion target ignores an event without a window")
    func promotionTargetIgnoresEventWithoutWindow() throws {
        let fixture = PromotionFixture(attachedToParent: true)

        #expect(AwesoMuxApplication.promotionTarget(for: try fixture.event(windowNumber: 0)) == nil)
    }

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
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private static func application() -> AwesoMuxApplication {
        AwesoMuxApplication.installAsSharedApplicationIfNeeded()
    }
}
