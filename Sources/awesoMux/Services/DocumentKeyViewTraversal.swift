import AppKit

@MainActor
enum DocumentKeyViewTraversal {
    static func direction(for event: NSEvent) -> Bool? {
        guard event.type == .keyDown, event.keyCode == 48 else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .control || modifiers == [.control, .shift] else { return nil }
        return modifiers.contains(.shift)
    }

    @discardableResult
    static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let backwards = direction(for: event), let window else { return false }
        if backwards {
            window.selectPreviousKeyView(nil)
        } else {
            window.selectNextKeyView(nil)
        }
        return true
    }
}
