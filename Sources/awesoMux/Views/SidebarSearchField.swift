import AppKit
import SwiftUI

struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let onMoveFocus: (Int) -> Bool
    let onSubmit: () -> Void
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.textColor = .labelColor
        field.placeholderString = String(localized: "Search sessions")
        field.setAccessibilityLabel(String(localized: "Sidebar search"))
        field.setAccessibilityHelp(
            String(
                localized:
                    "Filters workspaces. Use Up and Down Arrow to focus a result, Return to open it, or Escape to clear."
            )
        )
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            isFocused: $isFocused,
            onMoveFocus: onMoveFocus,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
        field.isEnabled = isEnabled
        if field.stringValue != text {
            field.stringValue = text
        }

        guard isFocused, field.currentEditor() == nil else {
            return
        }
        DispatchQueue.main.async { [weak field] in
            guard let field, field.currentEditor() == nil else {
                return
            }
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            onMoveFocus: onMoveFocus,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var onMoveFocus: (Int) -> Bool
        private var onSubmit: () -> Void
        private var onEscape: () -> Bool

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onMoveFocus: @escaping (Int) -> Bool,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Bool
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onMoveFocus = onMoveFocus
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        func update(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onMoveFocus: @escaping (Int) -> Bool,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Bool
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onMoveFocus = onMoveFocus
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Modified arrows (shift/option/command) never reach here as
            // moveDown:/moveUp: — AppKit's key-binding table maps them to
            // selection/paragraph selectors first — so plain moveDown:/moveUp:
            // need no modifier-flag gate. Gating on NSApp.currentEvent flags
            // previously rejected real hardware arrows, which always carry
            // .function and .numericPad.
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                return onMoveFocus(1)
            case #selector(NSResponder.moveUp(_:)):
                return onMoveFocus(-1)
            case #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return onEscape()
            default:
                return false
            }
        }
    }
}
