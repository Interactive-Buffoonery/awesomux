import AppKit
import SwiftUI

struct KeyboardCheatsheetSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMoveSelection: (Int) -> Void
    let onRunSelected: () -> Void
    let onDismiss: () -> Void
    let onFocusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> KeyboardCheatsheetSearchTextField {
        let field = KeyboardCheatsheetSearchTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.textColor = NSColor.labelColor
        field.placeholderString = "Search shortcuts"
        field.delegate = context.coordinator
        field.onMoveSelection = onMoveSelection
        field.onRunSelected = onRunSelected
        field.onDismiss = onDismiss
        field.onFocusChanged = onFocusChanged
        return field
    }

    func updateNSView(_ nsView: KeyboardCheatsheetSearchTextField, context: Context) {
        context.coordinator.update(text: $text)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onMoveSelection = onMoveSelection
        nsView.onRunSelected = onRunSelected
        nsView.onDismiss = onDismiss
        nsView.onFocusChanged = onFocusChanged

        guard !context.coordinator.hasAutoFocused,
              nsView.currentEditor() == nil else {
            return
        }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.currentEditor() == nil else {
                return
            }
            context.coordinator.hasAutoFocused = true
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        var hasAutoFocused = false

        init(text: Binding<String>) {
            self.text = text
        }

        func update(text: Binding<String>) {
            self.text = text
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
            guard let field = control as? KeyboardCheatsheetSearchTextField,
                  let command = KeyboardCheatsheetSearchCommand.command(for: commandSelector) else {
                return false
            }
            field.perform(command)
            return true
        }
    }
}

final class KeyboardCheatsheetSearchTextField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onRunSelected: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFocusChanged?(true)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onFocusChanged?(false)
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard let command = KeyboardCheatsheetSearchCommand.command(
            for: event,
            firstResponder: currentEditor() ?? self
        ) else {
            super.keyDown(with: event)
            return
        }
        perform(command)
    }

    func perform(_ command: KeyboardCheatsheetSearchCommand) {
        switch command {
        case .move(let delta):
            onMoveSelection?(delta)
        case .runSelected:
            onRunSelected?()
        case .dismiss:
            onDismiss?()
        }
    }
}
