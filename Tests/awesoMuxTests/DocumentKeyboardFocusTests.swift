import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Document keyboard focus", .serialized)
@MainActor
struct DocumentKeyboardFocusTests {
    @Test("the split detail receives the app's shared document action handler")
    func documentActionHandlerCrossesSplitHostingBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"), encoding: .utf8)
        #expect(source.contains("@Environment(DocumentComposeTabActionHandler.self) private var documentTabActions"))
        let detailStart = try #require(source.range(of: "detail: {"))
        let tail = source[detailStart.upperBound...]
        let detailEnd = try #require(tail.range(of: ".appearanceBridge(appSettingsStore)"))
        #expect(tail[..<detailEnd.lowerBound].contains(".environment(documentTabActions)"))
    }

    private final class FocusButton: NSButton {
        override var canBecomeKeyView: Bool { true }
    }

    private final class FocusWindow: NSWindow {
        var treatsAsKeyWindow = true
        override var isKeyWindow: Bool { treatsAsKeyWindow }
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

    @Test func handoffResumesWhenTheRegisteredViewAttaches() {
        let window = makeWindow()
        let original = FocusButton(title: "Original", target: nil, action: nil)
        window.contentView?.addSubview(original)
        #expect(window.makeFirstResponder(original))
        let incoming = SelectionAwareTextView(frame: .zero)
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.register(incoming, for: id)
        handoff.request(id, in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        #expect(window.firstResponder === original)

        window.contentView?.addSubview(incoming)
        let deadline = Date().addingTimeInterval(1)
        while window.firstResponder !== incoming, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        #expect(window.firstResponder === incoming)
    }

    @Test func attachingTheViewDoesNotReviveACanceledHandoff() {
        let window = makeWindow()
        let original = FocusButton(title: "Original", target: nil, action: nil)
        window.contentView?.addSubview(original)
        #expect(window.makeFirstResponder(original))
        let incoming = SelectionAwareTextView(frame: .zero)
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.register(incoming, for: id)
        handoff.request(id, in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        handoff.cancel()

        window.contentView?.addSubview(incoming)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        #expect(window.firstResponder === original)
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

    @Test func programmaticSelectionCancelsAnEarlierUserHandoff() {
        let window = makeWindow()
        let original = SelectionAwareTextView(frame: .zero)
        let incoming = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(incoming)
        #expect(window.makeFirstResponder(original))
        let requestedID = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(requestedID, in: window)
        handoff.selectedTabDidChange(to: UUID())
        handoff.register(incoming, for: requestedID)
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === original)

        handoff.request(requestedID, in: window)
        handoff.selectedTabDidChange(to: requestedID)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === incoming)
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
        let event = try makeSubsequentInputEvent(type: type, window: window)
        handoff.handleSubsequentInput(event)
        handoff.register(incoming, for: id)
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === original)

        handoff.request(id, in: window)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === incoming)
    }

    @Test func scrollDoesNotCancelDelayedHandoff() throws {
        let window = makeWindow()
        let original = SelectionAwareTextView(frame: .zero)
        let incoming = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(incoming)
        #expect(window.makeFirstResponder(original))
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(id, in: window)
        let event = try makeSubsequentInputEvent(type: .scrollWheel, window: window)
        handoff.handleSubsequentInput(event)
        handoff.register(incoming, for: id)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === incoming)
    }

    @Test func handoffRetriesWhenTheWindowBecomesKey() {
        let window = makeWindow()
        let original = FocusButton(title: "Original", target: nil, action: nil)
        let incoming = SelectionAwareTextView(frame: .zero)
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(incoming)
        #expect(window.makeFirstResponder(original))
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(id, in: window)
        handoff.register(incoming, for: id)
        window.treatsAsKeyWindow = false
        #expect(!handoff.completeIfReady())
        #expect(window.firstResponder === original)

        window.treatsAsKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let deadline = Date().addingTimeInterval(1)
        while window.firstResponder !== incoming, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
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

    @Test func controlTabFromATerminalLandsOnTheTabStrip() throws {
        let window = makeWindow()
        window.autorecalculatesKeyViewLoop = false
        let terminal = FocusButton(title: "Terminal", target: nil, action: nil)
        terminal.identifier = DocumentKeyViewTraversal.terminalSurfaceIdentifier
        terminal.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        let anchor = NSView(frame: NSRect(x: 0, y: 180, width: 400, height: 28))
        anchor.identifier = DocumentKeyViewTraversal.tabStripIdentifier
        let first = FocusButton(title: "First", target: nil, action: nil)
        first.frame = NSRect(x: 8, y: 180, width: 80, height: 28)
        let last = FocusButton(title: "Last", target: nil, action: nil)
        last.frame = NSRect(x: 200, y: 180, width: 80, height: 28)
        let body = FocusButton(title: "Body", target: nil, action: nil)
        body.frame = NSRect(x: 0, y: 220, width: 400, height: 80)
        for view in [terminal, anchor, first, last, body] {
            window.contentView?.addSubview(view)
        }
        terminal.nextKeyView = body
        body.nextKeyView = terminal
        #expect(window.makeFirstResponder(terminal))

        #expect(DocumentKeyViewTraversal.handle(try tab(.control), in: window, from: terminal))
        #expect(window.firstResponder === first)

        #expect(window.makeFirstResponder(terminal))
        #expect(
            DocumentKeyViewTraversal.handle(try tab([.control, .shift]), in: window, from: terminal))
        #expect(window.firstResponder === last)
    }

    @Test func controlTabWithoutATabStripFollowsTheKeyViewLoop() throws {
        let window = makeWindow()
        window.autorecalculatesKeyViewLoop = false
        let terminal = FocusButton(title: "Terminal", target: nil, action: nil)
        terminal.identifier = DocumentKeyViewTraversal.terminalSurfaceIdentifier
        let next = FocusButton(title: "Next", target: nil, action: nil)
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(next)
        terminal.nextKeyView = next
        next.nextKeyView = terminal
        #expect(window.makeFirstResponder(terminal))

        #expect(DocumentKeyViewTraversal.handle(try tab(.control), in: window, from: terminal))
        #expect(window.firstResponder === next)
    }

    @Test func documentChromeRecognizesViewerResponders() {
        #expect(!DocumentFocusHandoff.isDocumentChrome(nil))
        #expect(DocumentFocusHandoff.isDocumentChrome(SelectionAwareTextView(frame: .zero)))
        #expect(DocumentFocusHandoff.isDocumentChrome(BranchDiffStickyHeaderView(frame: .zero)))
        #expect(DocumentFocusHandoff.isDocumentChrome(DocumentTextScrollView(frame: .zero)))
        #expect(!DocumentFocusHandoff.isDocumentChrome(FocusButton(title: "Other", target: nil, action: nil)))
    }

    @Test func terminalControlTabPassesTheSurfaceAsOrigin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceInputBridge.swift"),
            encoding: .utf8)
        #expect(source.contains("DocumentKeyViewTraversal.handle(event, in: window, from: self)"))
        let markdown = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/Markdown/MarkdownTextView.swift"),
            encoding: .utf8)
        #expect(markdown.contains("textView.setAccessibilityRole(.textArea)"))
        #expect(!markdown.contains("setAccessibilityRole(.staticText)"))
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

    @Test func pinnedHeadingIgnoresKeyRepeat() throws {
        let window = makeWindow()
        let header = BranchDiffStickyHeaderView(frame: .zero)
        window.contentView?.addSubview(header)
        header.model = .init(
            key: "file", title: "file.swift", added: 1, removed: 0, collapsed: false, foldable: true)
        var activations = 0
        header.onActivate = { _ in activations += 1 }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        header.keyDown(with: event)
        #expect(activations == 0)
    }

    @Test func pinnedHeadingPassesModifiedTabThrough() throws {
        let window = makeWindow()
        window.autorecalculatesKeyViewLoop = false
        let header = BranchDiffStickyHeaderView(frame: .zero)
        let next = FocusButton(title: "Next", target: nil, action: nil)
        window.contentView?.addSubview(header)
        window.contentView?.addSubview(next)
        header.model = .init(
            key: "file", title: "file.swift", added: 1, removed: 0, collapsed: false, foldable: true)
        header.nextKeyView = next
        next.nextKeyView = header
        var activated: String?
        header.onActivate = { activated = $0 }
        #expect(window.makeFirstResponder(header))
        header.keyDown(with: try tab([.control, .option]))
        #expect(activated == nil)
        #expect(window.makeFirstResponder(header))
        header.keyDown(with: try tab([]))
        #expect(window.firstResponder === next)
    }

    @Test func emptyDocumentTextViewCompletesHandoff() {
        let window = makeWindow()
        let text = SelectionAwareTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.string = ""
        window.contentView?.addSubview(text)
        let id = UUID()
        let handoff = DocumentFocusHandoff()
        handoff.request(id, in: window)
        handoff.register(text, for: id)
        #expect(handoff.completeIfReady())
        #expect(window.firstResponder === text)
    }

    @Test func pinnedHeadingVoiceOverActivationReturnsFocusToText() {
        let window = makeWindow()
        let text = SelectionAwareTextView(frame: window.contentView!.bounds)
        text.isEditable = false
        text.isSelectable = true
        let other = FocusButton(title: "Other", target: nil, action: nil)
        let header = BranchDiffStickyHeaderView(frame: .zero)
        header.model = .init(
            key: "file", title: "file.swift", added: 1, removed: 0, collapsed: false, foldable: true)
        window.contentView?.addSubview(text)
        window.contentView?.addSubview(other)
        window.contentView?.addSubview(header)
        #expect(window.makeFirstResponder(other))
        let coordinator = MarkdownTextViewCoordinator(selectedSourceSpan: .constant(nil))
        coordinator.textView = text
        coordinator.stickyHeader = header
        header.isAccessibilityFocusedForTesting = true
        coordinator.returnFocusFromPinnedHeadingIfNeeded()
        #expect(window.firstResponder === text)
    }

    private final class AccessibilityFocusTextView: NSTextView {
        var onAccessibilityFocus: (() -> Void)?

        override func setAccessibilityFocused(_ focused: Bool) {
            if focused { onAccessibilityFocus?() }
            super.setAccessibilityFocused(focused)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func hidingPinnedHeadingRestoresIndependentFocus(keyboardFocused: Bool, accessibilityFocused: Bool) {
        let window = makeWindow()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let text = AccessibilityFocusTextView(frame: scroll.bounds)
        scroll.documentView = text
        let header = BranchDiffStickyHeaderView(frame: .zero)
        let other = FocusButton(title: "Other", target: nil, action: nil)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(other)
        scroll.addSubview(header)
        header.model = .init(
            key: "file", title: "file.swift", added: 1, removed: 0, collapsed: false, foldable: true)
        header.isAccessibilityFocusedForTesting = accessibilityFocused
        #expect(window.makeFirstResponder(keyboardFocused ? header : other))
        var accessibilityTransfers = 0
        text.onAccessibilityFocus = {
            #expect(!header.isHidden)
            accessibilityTransfers += 1
        }

        header.model = nil

        #expect(header.isHidden)
        #expect(window.firstResponder === (keyboardFocused ? text : other))
        if !keyboardFocused {
            #expect(accessibilityTransfers == 0)
        }
        header.model = nil
        if !keyboardFocused {
            #expect(accessibilityTransfers == 0)
        }
    }

    private func makeWindow() -> FocusWindow {
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

    private func makeSubsequentInputEvent(
        type: NSEvent.EventType, window: NSWindow
    ) throws -> NSEvent {
        switch type {
        case .keyDown:
            return try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, characters: "x",
                    charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        case .scrollWheel:
            let cgEvent = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 1,
                    wheel1: 1,
                    wheel2: 0,
                    wheel3: 0))
            return try #require(NSEvent(cgEvent: cgEvent))
        default:
            return try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1))
        }
    }
}
