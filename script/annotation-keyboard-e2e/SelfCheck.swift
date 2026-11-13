import AppKit

/// Runs inside the fixture's real NSApplication loop, so the delegate sees the
/// current event. Direct window.sendEvent tests cannot establish that context.
@MainActor
enum AnnotationKeyboardSelfCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    static func mainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func ready<T>(_ name: String, _ lookup: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let value = lookup() { return value }
            await mainTurn()
        }
        throw Failure(description: "Timed out: \(name)")
    }

    static func descendant<T: NSView>(_ type: T.Type, in view: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
        if let found = view as? T, matching(found) { return found }
        for child in view.subviews {
            if let found = descendant(type, in: child, matching: matching) { return found }
        }
        return nil
    }

    static func post(to window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: code == 76 ? "\u{3}" : "\r",
            charactersIgnoringModifiers: code == 76 ? "\u{3}" : "\r", isARepeat: repeated, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor
    final class Probe: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
        struct Command: Codable {
            let selector: String
            let keyCode: UInt16?
            let flags: UInt?
            let repeated: Bool?
            let handled: Bool
        }

        let textDelegate: (any NSTextViewDelegate)?
        let fieldDelegate: (any NSTextFieldDelegate)?
        var commands: [Command] = []
        var deliveredKeys: [UInt16] = []

        init(textDelegate: (any NSTextViewDelegate)? = nil, fieldDelegate: (any NSTextFieldDelegate)? = nil) {
            self.textDelegate = textDelegate
            self.fieldDelegate = fieldDelegate
        }

        private func record(_ selector: Selector, handled: Bool) {
            let event = NSApp.currentEvent
            commands.append(
                Command(
                    selector: NSStringFromSelector(selector), keyCode: event?.keyCode,
                    flags: event?.modifierFlags.rawValue, repeated: event?.isARepeat, handled: handled))
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let handled = textDelegate?.textView?(textView, doCommandBy: selector) ?? false
            record(selector, handled: handled)
            return handled
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let handled = fieldDelegate?.control?(control, textView: textView, doCommandBy: selector) ?? false
            record(selector, handled: handled)
            return handled
        }

        func textDidChange(_ notification: Notification) { textDelegate?.textDidChange?(notification) }
        func textDidBeginEditing(_ notification: Notification) { textDelegate?.textDidBeginEditing?(notification) }
        func textDidEndEditing(_ notification: Notification) { textDelegate?.textDidEndEditing?(notification) }
        func controlTextDidChange(_ notification: Notification) { fieldDelegate?.controlTextDidChange?(notification) }
    }
}
