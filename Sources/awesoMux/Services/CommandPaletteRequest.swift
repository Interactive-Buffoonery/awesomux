import AppKit

extension Notification.Name {
    static let awesoMuxCommandPaletteRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.commandPaletteRequested"
    )
}

@MainActor
enum CommandPaletteShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        let matched = isCommandPaletteChord(event) && !event.isARepeat
        ShortcutDiagnostics.logMatcher(event: event, matched: matched)
        return matched
    }

    static func isRepeat(ofCommandPaletteChord event: NSEvent) -> Bool {
        isCommandPaletteChord(event) && event.isARepeat
    }

    private static func isCommandPaletteChord(_ event: NSEvent) -> Bool {
        CurrentKeyboardShortcuts.binding(id: KeyboardShortcutCatalog.toggleCommandPalette.id)?.matches(event) == true
    }
}
