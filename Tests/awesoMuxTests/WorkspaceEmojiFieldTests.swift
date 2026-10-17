import AppKit
import Testing
@testable import awesoMux

@MainActor
@Suite("Workspace emoji field", .serialized)
struct WorkspaceEmojiFieldTests {
    @Test("successive picker inserts replace the selected emoji")
    func successiveInsertsReplace() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let field = WorkspaceEmojiTextView(frame: window.contentView!.bounds)
        window.contentView = field
        defer {
            window.contentView = nil
            window.close()
        }
        var draft = ""
        field.onChange = { draft = $0 }
        #expect(window.makeFirstResponder(field))
        let editor = field

        for emoji in ["🤠", "🍕", "👩🏽‍💻", "👩🏽‍💻"] {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText(emoji, replacementRange: editor.selectedRange())
            #expect(draft == emoji)
            #expect(field.string == emoji)

        }
    }

    @Test("picker waits for its window and presents each request once")
    func pickerWaitsForKeyWindow() async {
        let window = EmojiTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let field = WorkspaceEmojiTextView(frame: window.contentView!.bounds)
        var presentations = 0
        field.openCharacterPalette = { editor in
            #expect(window.firstResponder === editor)
            #expect(editor.inputContext?.client as? NSTextView === editor)
            #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
            presentations += 1
        }
        window.contentView = field
        defer {
            window.contentView = nil
            window.close()
        }
        field.requestPicker(0)
        await drainMainQueue()
        #expect(presentations == 0)
        window.testIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drainMainQueue()
        #expect(presentations == 1)
        field.requestPicker(0)
        await drainMainQueue()
        #expect(presentations == 1)
        let button = NSButton()
        window.contentView?.addSubview(button)
        #expect(window.makeFirstResponder(button))
        field.string = "🍕"
        field.requestPicker(1)
        window.testIsKey = false
        await drainMainQueue()
        #expect(presentations == 1)
        window.testIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drainMainQueue()
        #expect(presentations == 2)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("focused editor has room for the emoji glyph")
    func focusedEmojiFits() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 36),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = WorkspaceEmojiTextView(frame: .zero)
        editor.frame = window.contentView!.bounds
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        for emoji in ["🍕", "😊", "👩🏽‍💻"] {
            editor.insertText(emoji, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            let manager = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            #expect(editor.string == emoji)
            #expect(used.width > 0)
            #expect(used.height > 0)
            #expect(editor.bounds.contains(used))
        }
    }

}

@MainActor
private final class EmojiTestWindow: NSWindow {
    var testIsKey = false
    override var isKeyWindow: Bool { testIsKey }
}
