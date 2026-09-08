import AppKit
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Document keyboard focus", .serialized)
@MainActor
struct DocumentKeyboardFocusTests {
    private final class FocusButton: NSButton {
        override var canBecomeKeyView: Bool { true }
    }

    private final class FocusWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test func selectableReadOnlyTextParticipatesInKeyLoop() {
        let window = makeWindow()
        let text = SelectionAwareTextView(frame: window.contentView!.bounds)
        text.isEditable = false
        text.isSelectable = true
        window.contentView?.addSubview(text)
        #expect(text.acceptsFirstResponder)
        #expect(text.canBecomeKeyView)
        #expect(window.makeFirstResponder(text))
        #expect(window.firstResponder === text)
        text.isHidden = true
        #expect(!text.canBecomeKeyView)
    }

    @Test func textTraversalAndFocusIndicatorFollowTheResponder() {
        let window = makeWindow()
        window.autorecalculatesKeyViewLoop = false
        let scroll = DocumentTextScrollView(frame: window.contentView!.bounds)
        let text = SelectionAwareTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        scroll.documentView = text
        let button = FocusButton(title: "Tab", target: nil, action: nil)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(button)
        text.nextKeyView = button
        button.nextKeyView = text
        #expect(window.makeFirstResponder(text))
        #expect(scroll.showsDocumentFocus)
        text.insertTab(nil)
        #expect(window.firstResponder === button)
        #expect(!scroll.showsDocumentFocus)
        window.selectNextKeyView(nil)
        #expect(window.firstResponder === text)
        #expect(scroll.showsDocumentFocus)
    }

    @Test func handoffWaitsForSelectedTabAndRunsOnlyOnce() {
        let window = makeWindow()
        let outgoing = SelectionAwareTextView(frame: .zero)
        let incoming = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(outgoing)
        window.contentView?.addSubview(incoming)
        let oldID = UUID()
        let newID = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.register(outgoing, for: oldID)
        handoff.request(newID, in: window)
        #expect(!handoff.completeIfReady())
        handoff.register(incoming, for: newID)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === incoming)
        #expect(window.makeFirstResponder(outgoing))
        handoff.register(incoming, for: newID)
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === outgoing)
    }

    @Test func latestSelectionSupersedesPendingRender() {
        let window = makeWindow()
        let text = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(text)
        let first = UUID()
        let last = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(first, in: window)
        handoff.request(last, in: window)
        handoff.register(text, for: first)
        #expect(!handoff.completeIfReady())
        handoff.register(text, for: last)
        #expect(handoff.completeIfReady())
    }

    @Test func delayedRenderDoesNotStealFromAnotherControl() {
        let window = makeWindow()
        let text = SelectionAwareTextView(frame: .zero)
        let other = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(text)
        window.contentView?.addSubview(other)
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(id, in: window)
        #expect(window.makeFirstResponder(other))
        handoff.register(text, for: id)
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === other)
    }

    @Test(arguments: [NSEvent.EventType.keyDown, .leftMouseDown])
    func newInputCancelsDelayedHandoffEvenWithUnchangedResponder(type: NSEvent.EventType) throws {
        let window = makeWindow()
        let original = SelectionAwareTextView(frame: .zero)
        let incoming = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(incoming)
        #expect(window.makeFirstResponder(original))
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(id, in: window)
        let event: NSEvent
        if type == .keyDown {
            event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, characters: "x",
                    charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        } else {
            event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1))
        }
        handoff.handleSubsequentInput(event)
        handoff.register(incoming, for: id)
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === original)

        handoff.request(id, in: window)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === incoming)
    }

    @Test(arguments: [NSEvent.ModifierFlags(), .shift, .command, [.control, .option]])
    func ordinaryTabAndOtherCommandsRemainAvailable(modifiers: NSEvent.ModifierFlags) throws {
        #expect(DocumentKeyViewTraversal.direction(for: try tab(modifiers)) == nil)
    }

    @Test func controlTabTraversesInBothDirections() throws {
        #expect(DocumentKeyViewTraversal.direction(for: try tab(.control)) == false)
        #expect(DocumentKeyViewTraversal.direction(for: try tab([.control, .shift])) == true)
    }

    @Test func pinnedHeadingAcceptsKeyboardActivation() throws {
        let window = makeWindow()
        let header = BranchDiffStickyHeaderView(frame: .zero)
        window.contentView?.addSubview(header)
        #expect(!header.canBecomeKeyView)
        header.model = .init(key: "file", title: "file.swift", added: 1, removed: 0, collapsed: false, foldable: true)
        #expect(header.canBecomeKeyView)
        var activated: String?
        header.onActivate = { activated = $0 }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        header.keyDown(with: event)
        #expect(activated == "file")
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        return FocusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func tab(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
    }
}
