import AppKit
import Testing
@testable import awesoMux

@Suite("GhosttySurfaceIMEPolicy")
struct GhosttySurfaceIMEPolicyTests {
    // MARK: - layoutChangedDuringComposition

    @Test("no layout change is not flagged")
    func layoutUnchangedIsNotFlagged() {
        let changed = GhosttySurfaceIMEPolicy.layoutChangedDuringComposition(
            markedTextBefore: false,
            keyboardIdBefore: "com.apple.keylayout.US",
            keyboardIdAfter: "com.apple.keylayout.US"
        )

        #expect(!changed)
    }

    @Test("layout change while not composing is flagged")
    func layoutChangeWhileNotComposingIsFlagged() {
        let changed = GhosttySurfaceIMEPolicy.layoutChangedDuringComposition(
            markedTextBefore: false,
            keyboardIdBefore: "com.apple.keylayout.US",
            keyboardIdAfter: "com.apple.inputmethod.Korean.2SetKorean"
        )

        #expect(changed)
    }

    @Test("layout change while already composing is not flagged")
    func layoutChangeWhileComposingIsNotFlagged() {
        // Layout churn is expected IME behavior once composition has
        // already started — only a change with no prior marked text
        // signals "an IME just grabbed this keystroke."
        let changed = GhosttySurfaceIMEPolicy.layoutChangedDuringComposition(
            markedTextBefore: true,
            keyboardIdBefore: nil,
            keyboardIdAfter: "com.apple.inputmethod.Korean.2SetKorean"
        )

        #expect(!changed)
    }

    // MARK: - shouldReplayCommittedPreeditKey

    @Test(
        "up, right, and down arrows always replay",
        arguments: [0x7E, 0x7C, 0x7D] as [UInt16]
    )
    func verticalAndRightArrowsAlwaysReplay(keyCode: UInt16) {
        let shouldReplay = GhosttySurfaceIMEPolicy.shouldReplayCommittedPreeditKey(
            keyCode: keyCode,
            modifierFlags: []
        )

        #expect(shouldReplay)
    }

    @Test("plain left arrow does not replay")
    func plainLeftArrowDoesNotReplay() {
        let shouldReplay = GhosttySurfaceIMEPolicy.shouldReplayCommittedPreeditKey(
            keyCode: 0x7B,
            modifierFlags: []
        )

        #expect(!shouldReplay)
    }

    @Test(
        "modified left arrow replays",
        arguments: [
            NSEvent.ModifierFlags.shift,
            .control,
            .option,
            .command,
        ]
    )
    func modifiedLeftArrowReplays(modifier: NSEvent.ModifierFlags) {
        let shouldReplay = GhosttySurfaceIMEPolicy.shouldReplayCommittedPreeditKey(
            keyCode: 0x7B,
            modifierFlags: [modifier]
        )

        #expect(shouldReplay)
    }

    @Test("non-arrow keys do not replay")
    func nonArrowKeysDoNotReplay() {
        let shouldReplay = GhosttySurfaceIMEPolicy.shouldReplayCommittedPreeditKey(
            keyCode: 0x00, // kVK_ANSI_A
            modifierFlags: [.command]
        )

        #expect(!shouldReplay)
    }

    // MARK: - shouldSuppressComposingControlInput

    @Test("control character while composing is suppressed")
    func controlCharacterWhileComposingIsSuppressed() {
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            "\u{08}",
            composing: true
        )

        #expect(suppressed)
    }

    @Test("control character while not composing is not suppressed")
    func controlCharacterWhileNotComposingIsNotSuppressed() {
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            "\u{08}",
            composing: false
        )

        #expect(!suppressed)
    }

    @Test("printable text while composing is not suppressed")
    func printableTextWhileComposingIsNotSuppressed() {
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            "a",
            composing: true
        )

        #expect(!suppressed)
    }

    @Test("multi-character text while composing is not suppressed")
    func multiCharacterTextWhileComposingIsNotSuppressed() {
        // A committed IME string is never a single control character even if
        // it happens to start with one, so only single-scalar text qualifies.
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            "\u{08}a",
            composing: true
        )

        #expect(!suppressed)
    }

    @Test("nil text is not suppressed")
    func nilTextIsNotSuppressed() {
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            nil,
            composing: true
        )

        #expect(!suppressed)
    }

    @Test("empty text is not suppressed")
    func emptyTextIsNotSuppressed() {
        let suppressed = GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(
            "",
            composing: true
        )

        #expect(!suppressed)
    }
}
