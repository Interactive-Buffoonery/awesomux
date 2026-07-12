import AppKit

extension Notification.Name {
    static let awesoMuxKeyboardCheatsheetRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.keyboardCheatsheetRequested"
    )
}

@MainActor
enum KeyboardCheatsheetShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        let matched = isKeyboardCheatsheetChord(event) && !event.isARepeat
        ShortcutDiagnostics.logMatcher(event: event, matched: matched)
        return matched
    }

    static func isRepeat(ofKeyboardCheatsheetChord event: NSEvent) -> Bool {
        isKeyboardCheatsheetChord(event) && event.isARepeat
    }

    static func shouldDismissPanelForUnhandledKey(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        event.type == .keyDown
            && !event.isARepeat
            && !isTextInputResponder(firstResponder)
    }

    static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else {
            return false
        }

        if responder is NSText || responder is NSTextField || responder is NSTextInputClient {
            return true
        }

        return isTextInputResponder(responder.nextResponder)
    }

    private static func isKeyboardCheatsheetChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        return CurrentKeyboardShortcuts.binding(id: KeyboardShortcutCatalog.showKeyboardCheatsheet.id)?
            .matches(event) == true
    }
}
