import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Annotation hosted keyboard", .serialized)
@MainActor
struct AnnotationKeyboardHostedTests {
    @Test(arguments: ["note", "rich", "reply", "edit", "compose"])
    func hostedAccept(scenario: String) async throws {
        for code: UInt16 in [36, 76] {
            for flags: NSEvent.ModifierFlags in [.command, [.command, .numericPad], [.command, .function, .capsLock]] {
                let fixture = try AnnotationKeyboardFixture(scenario: scenario)
                defer { fixture.close() }
                fixture.enter("draft")
                fixture.key(code, modifiers: flags)
                await SidebarHostedTestHarness.drainMainQueue()
                #expect(fixture.submissions == ["draft"], "\(scenario), key \(code), flags \(flags)")
            }
        }
    }

    @Test(arguments: ["note", "rich", "reply", "edit"], [false, true])
    func hostedAcceptAfterLeavingEditor(scenario: String, buttonFocus: Bool) async throws {
        for code: UInt16 in [36, 76] {
            let fixture = try AnnotationKeyboardFixture(scenario: scenario)
            defer { fixture.close() }
            fixture.enter("draft")
            if buttonFocus {
                let button = NSButton(title: "Fixture focus", target: nil, action: nil)
                fixture.window.contentView?.addSubview(button)
                #expect(fixture.window.makeFirstResponder(button))
            } else {
                #expect(fixture.window.makeFirstResponder(fixture.window))
            }
            SidebarHostedTestHarness.settleMainRunLoop()
            fixture.key(code, modifiers: .command)
            await SidebarHostedTestHarness.drainMainQueue()
            #expect(fixture.submissions == ["draft"], "blurred \(scenario), key \(code)")
        }
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func hostedReplyRejectsReadonlyTextFocus(code: UInt16) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: "reply")
        defer { fixture.close() }
        fixture.enter("draft")
        let payload = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        payload.string = "annotation payload"
        payload.isEditable = false
        payload.isSelectable = true
        fixture.window.contentView?.addSubview(payload)
        #expect(fixture.window.makeFirstResponder(payload))
        payload.selectAll(nil)
        #expect(fixture.window.firstResponder === payload)
        fixture.key(code, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions.isEmpty)
        try fixture.focusEditor()
        #expect(fixture.editor.string == "draft")
        #expect(payload.string == "annotation payload")
    }

    @Test
    func hostedReplyEditorsRemainIndependent() async throws {
        var replies: [String] = []
        let window = SidebarHostedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let host = NSHostingView(
            rootView: VStack {
                ForEach(0..<2) { index in
                    FullCommentPopover(
                        displayNumber: index + 1,
                        annotation: PlanAnnotation(id: "fixture-\(index)", author: .user, payload: "note", anchor: .span),
                        quotedText: "fixture", onEdit: { _ in .saved }, onDelete: { .saved }, onSetStatus: { _ in .saved },
                        onReply: { text in
                            replies.append("\(index):\(text)")
                            return .saved
                        })
                }
            })
        window.contentView = host
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()
        func fields(in view: NSView) -> [NSTextField] {
            let here = (view as? NSTextField).map { $0.placeholderString == "Reply…" ? [$0] : [] } ?? []
            return here + view.subviews.flatMap { fields(in: $0) }
        }
        let controls = fields(in: host)
        try #require(controls.count == 2)
        controls[0].selectText(nil)
        let first = try #require(controls[0].currentEditor() as? NSTextView)
        first.insertText("first", replacementRange: first.selectedRange())
        SidebarHostedTestHarness.settleMainRunLoop()
        controls[1].selectText(nil)
        let second = try #require(controls[1].currentEditor() as? NSTextView)
        #expect(first !== second)
        second.insertText("second", replacementRange: second.selectedRange())
        SidebarHostedTestHarness.settleMainRunLoop()
        second.setMarkedText(
            "候補", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
            keyCode: 36)!
        if !window.performKeyEquivalent(with: markedEvent) { NSApp.sendEvent(markedEvent) }
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(replies.isEmpty)
        second.unmarkText()
        second.selectAll(nil)
        second.insertText("second", replacementRange: second.selectedRange())
        SidebarHostedTestHarness.settleMainRunLoop()
        for (index, code) in [(1, UInt16(76)), (0, UInt16(36))] {
            controls[index].selectText(nil)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: code == 76 ? "\u{3}" : "\r",
                charactersIgnoringModifiers: code == 76 ? "\u{3}" : "\r", isARepeat: false, keyCode: code)!
            #expect(window.performKeyEquivalent(with: event))
            await SidebarHostedTestHarness.drainMainQueue()
        }
        #expect(replies == ["1:second", "0:first"])
    }

    @Test(arguments: ["note", "rich", "reply", "edit", "compose"])
    func hostedMarkedTextAndRejection(scenario: String) async throws {
        for code: UInt16 in [36, 76] {
            let fixture = try AnnotationKeyboardFixture(scenario: scenario)
            defer { fixture.close() }
            fixture.enter("draft")
            fixture.editor.setMarkedText(
                "候補", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(fixture.editor.hasMarkedText())
            fixture.key(code, modifiers: .command)
            await SidebarHostedTestHarness.drainMainQueue()
            #expect(fixture.submissions.isEmpty, "marked \(scenario), key \(code)")
        }
        for code: UInt16 in [36, 76] {
            for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control]] {
                let fixture = try AnnotationKeyboardFixture(scenario: scenario)
                defer { fixture.close() }
                fixture.enter("draft")
                fixture.key(code, modifiers: flags)
                fixture.key(code, modifiers: .command, repeated: true)
                await SidebarHostedTestHarness.drainMainQueue()
                #expect(fixture.submissions.isEmpty, "rejected \(scenario), key \(code), flags \(flags)")
            }
        }
    }

    @Test(arguments: ["note", "rich", "reply", "edit", "compose"])
    func hostedEmptyAndPlainReturn(scenario: String) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: scenario)
        defer { fixture.close() }
        fixture.enter("")
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions.isEmpty)
        fixture.enter("draft")
        fixture.key(36)
        await SidebarHostedTestHarness.drainMainQueue()
        if scenario == "rich" || scenario == "reply" {
            #expect(fixture.submissions == ["draft"])
        } else {
            #expect(fixture.submissions.isEmpty)
            #expect(fixture.editor.string.contains("\n"))
        }
    }
    @Test(arguments: ["note", "rich", "reply", "edit", "compose"])
    func hostedDisabledAndInflight(scenario: String) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: scenario)
        defer { fixture.close() }
        fixture.enter("draft")
        fixture.setEnabled(false)
        fixture.key(36, modifiers: .command)
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions.isEmpty)
        fixture.setEnabled(true)
        try fixture.focusEditor()
        fixture.holdSaves = true
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions == ["draft"])
        fixture.key(36, modifiers: .command)
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions == ["draft"])
        fixture.finishSave()
    }

    @Test(arguments: ["note", "rich", "reply", "edit", "compose"])
    func hostedCallbackRefresh(scenario: String) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: scenario)
        defer { fixture.close() }
        fixture.enter("draft")
        let editor = fixture.editor
        fixture.refreshCallbacks()
        #expect(fixture.window.firstResponder === editor)
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions == ["draft"])
        #expect(fixture.callbackVersions == [1])
    }

    @Test(arguments: ["note", "reply", "edit", "compose"])
    func hostedRecoveryGate(scenario: String) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: scenario)
        defer { fixture.close() }
        fixture.saveOutcome = scenario == "compose" ? .copyAndReselect : .copyOnly
        fixture.enter("draft")
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions == ["draft"])
        fixture.key(36, modifiers: .command)
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions == ["draft"])
    }

    @Test
    func hostedRichInputSanitizedEmpty() async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: "rich")
        defer { fixture.close() }
        fixture.enter("\u{202E}")
        fixture.key(36, modifiers: .command)
        fixture.key(76, modifiers: .command)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions.isEmpty)
    }

    @Test(arguments: ["rich", "reply"])
    func hostedMarkedPlainReturn(scenario: String) async throws {
        let fixture = try AnnotationKeyboardFixture(scenario: scenario)
        defer { fixture.close() }
        fixture.enter("draft")
        fixture.editor.setMarkedText(
            "候補", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.key(36)
        await SidebarHostedTestHarness.drainMainQueue()
        #expect(fixture.submissions.isEmpty)
    }

}

@MainActor
private final class AnnotationKeyboardFixture {
    let scenario: String
    let window: SidebarHostedTestWindow
    var submissions: [String] = []
    var callbackVersions: [Int] = []
    var editor: NSTextView!
    var holdSaves = false
    var saveOutcome = AnnotationSaveOutcome.saved
    private var pendingSave: CheckedContinuation<AnnotationSaveOutcome, Never>?
    private var host: NSHostingView<AnyView>!
    private var root = AnyView(EmptyView())

    func record(_ text: String, version: Int) async -> AnnotationSaveOutcome {
        submissions.append(text)
        callbackVersions.append(version)
        if holdSaves { return await withCheckedContinuation { pendingSave = $0 } }
        return saveOutcome
    }

    func finishSave() {
        pendingSave?.resume(returning: .saved)
        pendingSave = nil
    }

    func setEnabled(_ enabled: Bool) {
        host.rootView = AnyView(root.disabled(!enabled))
        SidebarHostedTestHarness.settleMainRunLoop()
    }

    init(scenario: String) throws {
        self.scenario = scenario
        _ = NSApplication.shared
        window = SidebarHostedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = makeRoot(version: 0)
        self.root = root
        host = NSHostingView(rootView: AnyView(root.disabled(false)))
        window.contentView = host
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()
        if scenario == "edit" {
            window.setContentSize(NSSize(width: 300, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            SidebarHostedTestHarness.settleMainRunLoop()
            // Hidden SwiftUI hosts omit AX children. Hit-test the real header's
            // Edit button; requiring the resulting editor detects layout drift.
            let point = NSPoint(x: 248, y: host.bounds.height - 20)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            SidebarHostedTestHarness.settleMainRunLoop()
        }
        if scenario == "reply" {
            let field = try #require(
                SidebarHostedTestHarness.firstDescendant(of: NSTextField.self, in: host, where: { $0.placeholderString == "Reply…" }))
            field.selectText(nil)
            editor = try #require(field.currentEditor() as? NSTextView)
            #expect(editor.isFieldEditor)
            #expect(editor is AnnotationAcceptChordTextView)
        } else {
            editor = try #require(SidebarHostedTestHarness.firstDescendant(of: NSTextView.self, in: host))
            #expect(window.makeFirstResponder(editor))
        }
        #expect(window.firstResponder === editor)
        editor.selectAll(nil)
    }

    func focusEditor() throws {
        if scenario == "reply" {
            let field = try #require(
                SidebarHostedTestHarness.firstDescendant(of: NSTextField.self, in: host, where: { $0.placeholderString == "Reply…" }))
            field.selectText(nil)
            editor = try #require(field.currentEditor() as? NSTextView)
        } else {
            #expect(window.makeFirstResponder(editor))
        }
        #expect(window.firstResponder === editor)
    }

    func refreshCallbacks() {
        root = makeRoot(version: 1)
        setEnabled(true)
    }

    private func makeRoot(version: Int) -> AnyView {
        let annotation = PlanAnnotation(id: "fixture", author: .user, payload: "original", anchor: .span)
        let root: AnyView
        switch scenario {
        case "note":
            root = AnyView(
                DocumentNoteSheet(
                    note: nil,
                    onAdd: { [weak self] text in
                        await self?.record(text, version: version) ?? .saved
                    }, onEdit: { _, _ in .saved }, onSetStatus: { _, _ in .saved }, onDelete: { _ in .saved }, onClose: {}))
        case "rich":
            root = AnyView(
                RichInputComposerSheet(
                    seed: "", title: "Fixture", reviewedFilePath: "/tmp/annotation-keyboard-fixture.md", receivingTerminal: "Disposable",
                    capturedWorkingDirectory: "/tmp", isCopy: true,
                    onSend: { [weak self] text in
                        self?.submissions.append(text); self?.callbackVersions.append(version); return .sent
                    }, onClose: {}))
        case "compose":
            root = AnyView(
                ComposeCommentPopover(
                    onSave: { [weak self] text, _ in
                        await self?.record(text, version: version) ?? .saved
                    }, onCancel: {}))
        default:
            root = AnyView(
                FullCommentPopover(
                    displayNumber: 1, annotation: annotation, quotedText: "Fixture",
                    onEdit: { [weak self] text in
                        await self?.record(text, version: version) ?? .saved
                    }, onDelete: { .saved }, onSetStatus: { _ in .saved },
                    onReply: { [weak self] text in
                        await self?.record(text, version: version) ?? .saved
                    }))
        }
        return root
    }

    func enter(_ text: String) {
        editor.insertText(text, replacementRange: editor.selectedRange())
        SidebarHostedTestHarness.settleMainRunLoop()
    }

    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: code == 76 ? "\u{3}" : "\r",
            charactersIgnoringModifiers: code == 76 ? "\u{3}" : "\r", isARepeat: repeated, keyCode: code)!
        // Enter through the hosted window's equivalent route, including SwiftUI
        // button fallbacks; direct subclass calls cannot prove this ordering.
        let markedBefore = editor.hasMarkedText()
        let handled = window.performKeyEquivalent(with: event)
        if !handled { NSApp.sendEvent(event) }
        SidebarHostedTestHarness.settleMainRunLoop()
        print(
            "annotation-route surface=\(scenario) key=\(code) modifiers=\(modifiers.rawValue) repeat=\(repeated) equivalent=\(handled) marked=\(markedBefore)->\(editor.hasMarkedText()) selected=\(editor.selectedRange()) text=\(String(reflecting: editor.string))"
        )
    }

    func close() { finishSave(); window.close(); window.contentView = nil }

}
