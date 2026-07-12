import Carbon

/// The active keyboard input source's identifier, used to detect the layout
/// swaps some IMEs perform mid-keystroke (e.g. temporarily switching to a
/// Latin layout while composing, then back). Mirrors Ghostty's
/// `Helpers/KeyboardLayout.swift`.
enum GhosttyKeyboardLayout {
    static var id: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }

        return unsafeBitCast(sourceIdPointer, to: CFString.self) as String
    }
}
