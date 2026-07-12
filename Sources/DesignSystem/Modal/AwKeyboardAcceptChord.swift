import AppKit

/// The shared keyboard-accept chord for destructive confirm dialogs:
/// ⌘Return or ⌘–keypad-Enter, ignoring passive modifiers. One policy so
/// AwModal and the app's NSAlert dialogs cannot drift apart (INT-725) —
/// keypad Enter in particular must work everywhere or the unification
/// premise breaks for users who rely on it.
public enum AwKeyboardAcceptChord {
    public static func isKeyboardAcceptKeyDown(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        // 36 = Return, 76 = keypad Enter. .numericPad rides along on keypad
        // Enter; .function on some external keyboards' Enter; neither is a
        // user-held modifier, so neither should veto accept.
        (keyCode == 36 || keyCode == 76)
            && modifiers
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad]) == .command
    }
}
