import AppKit
import Testing

@testable import awesoMux

@MainActor
@Suite("Annotation accept-chord text view")
struct AnnotationAcceptChordTextViewTests {
    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }

    @Test("Command-Return fires the accept chord")
    func commandReturnFires() {
        let textView = AnnotationAcceptChordTextView()
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 36, modifiers: [.command])
        )

        #expect(handled)
        #expect(fired)
    }

    @Test("Command-keypad-Enter fires the accept chord")
    func commandKeypadEnterFires() {
        let textView = AnnotationAcceptChordTextView()
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 76, modifiers: [.command, .numericPad])
        )

        #expect(handled)
        #expect(fired)
    }

    @Test("Command-Shift-Return is not the accept chord")
    func commandShiftReturnDoesNotFire() {
        let textView = AnnotationAcceptChordTextView()
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 36, modifiers: [.command, .shift])
        )

        #expect(!handled)
        #expect(!fired)
    }

    @Test("marked text (IME composition) suppresses the accept chord")
    func markedTextIgnoresChord() {
        let textView = AnnotationAcceptChordTextView()
        textView.setMarkedText(
            "あ",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 0, length: 0)
        )
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 36, modifiers: [.command])
        )

        #expect(!handled)
        #expect(!fired)
    }

    @Test("a key-repeat of the accept chord is ignored")
    func keyRepeatIgnoresChord() {
        let textView = AnnotationAcceptChordTextView()
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 36, modifiers: [.command], isARepeat: true)
        )

        #expect(!handled)
        #expect(!fired)
    }

    @Test("a non-editable field ignores the accept chord")
    func nonEditableIgnoresChord() {
        let textView = AnnotationAcceptChordTextView()
        textView.isEditable = false
        var fired = false
        textView.onAcceptChord = { fired = true }

        let handled = textView.performKeyEquivalent(
            with: keyEvent(keyCode: 36, modifiers: [.command])
        )

        #expect(!handled)
        #expect(!fired)
    }
}
