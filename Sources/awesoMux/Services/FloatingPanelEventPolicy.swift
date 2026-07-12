import AppKit
import Carbon.HIToolbox

enum FloatingPanelEventPolicy {
    private static let escapeKeyCode = UInt16(kVK_Escape)
    private static let returnKeyCodes = Set<UInt16>([
        UInt16(kVK_Return),
        UInt16(kVK_ANSI_KeypadEnter)
    ])

    /// Matches pointer events that should re-key a non-key panel.
    static func isReclickActivation(type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .scrollWheel:
            return true
        default:
            return false
        }
    }

    /// Matches bare Escape key-down events that should dismiss the panel.
    static func isDismissChord(
        type: NSEvent.EventType,
        keyCode: UInt16,
        isARepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard type == .keyDown, !isARepeat else {
            return false
        }

        return keyCode == escapeKeyCode
            && normalizedModifiers(modifiers).isEmpty
    }

    static func isCloseChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !event.isARepeat,
              normalizedModifiers(event.modifierFlags) == [.command],
              let characters = event.charactersIgnoringModifiers else {
            return false
        }

        return characters == "w" || characters == "W"
    }

    static func isPromoteChord(
        type: NSEvent.EventType,
        keyCode: UInt16,
        isARepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        type == .keyDown
            && !isARepeat
            && returnKeyCodes.contains(keyCode)
            && normalizedModifiers(modifiers) == [.command]
    }

    static func canPromoteFloatingPanel(hasAttachedSheet: Bool) -> Bool {
        !hasAttachedSheet
    }

    static func isGlobalWorkspaceJumpChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !event.isARepeat,
              normalizedModifiers(event.modifierFlags) == [.command],
              let characters = event.charactersIgnoringModifiers else {
            return false
        }

        return characters.count == 1 && ("1"..."9").contains(characters)
    }

    private static func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers
            .intersection(.deviceIndependentFlagsMask)
            // .numericPad rides along on every keypad key (keypad Enter, keypad
            // digits); .function/.capsLock ride along on some layouts. None is a
            // user-held modifier, so none should block an exact-equality chord
            // match — otherwise ⌘ + keypad Enter can never promote. Mirrors the
            // accept-monitor subtraction set in GhosttyClipboardBridge's
            // unsafe-paste confirmation.
            .subtracting([.capsLock, .function, .numericPad])
    }
}
