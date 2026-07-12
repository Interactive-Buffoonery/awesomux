import AppKit
import Carbon.HIToolbox
import Observation

@MainActor
@Observable
final class KeyboardCheatsheetModel {
    let sections: [KeyboardShortcutSection]
    var query = "" {
        didSet {
            selectedEntryID = KeyboardCheatsheetSelection.retainedSelection(
                selectedEntryID,
                visibleIDs: visibleEntryIDs
            )
        }
    }
    var selectedEntryID: String?

    init(sections: [KeyboardShortcutSection]) {
        self.sections = sections
    }

    var filteredSections: [KeyboardShortcutSection] {
        sections.compactMap { section in
            let entries = section.entries.filter { entry in
                entry.matches(query: query, in: section.title)
            }
            guard !entries.isEmpty else {
                return nil
            }
            return KeyboardShortcutSection(title: section.title, entries: entries)
        }
    }

    var visibleEntryIDs: [String] {
        filteredSections.flatMap { section in
            section.entries.map(\.id)
        }
    }

    var visibleShortcutCount: Int {
        filteredSections.reduce(0) { count, section in
            count + section.entries.count
        }
    }

    var selectedEntry: KeyboardShortcutEntry? {
        guard let selectedEntryID else {
            return nil
        }

        for section in filteredSections {
            if let entry = section.entries.first(where: { $0.id == selectedEntryID }) {
                return entry
            }
        }

        return nil
    }

    var selectedShortcutCopyText: String? {
        selectedEntry.map(KeyboardCheatsheetCopyText.text)
    }

    func reset() {
        query = ""
        selectedEntryID = nil
    }

    func moveSelection(by delta: Int) {
        selectedEntryID = KeyboardCheatsheetSelection.movedSelection(
            currentID: selectedEntryID,
            visibleIDs: visibleEntryIDs,
            delta: delta
        )
    }
}

enum KeyboardCheatsheetCopyText {
    static func text(for entry: KeyboardShortcutEntry) -> String {
        "\(entry.action) - \(shortcutText(for: entry))"
    }

    private static func shortcutText(for entry: KeyboardShortcutEntry) -> String {
        entry.bindings
            .map { binding in
                binding.displayTokens.joined(separator: " ")
            }
            .joined(separator: " or ")
    }
}

enum KeyboardCheatsheetSelection {
    static func movedSelection(
        currentID: String?,
        visibleIDs: [String],
        delta: Int
    ) -> String? {
        guard !visibleIDs.isEmpty else {
            return nil
        }

        guard let currentID,
              let currentIndex = visibleIDs.firstIndex(of: currentID) else {
            return delta < 0 ? visibleIDs.last : visibleIDs.first
        }

        let targetIndex = min(
            max(currentIndex + delta, visibleIDs.startIndex),
            visibleIDs.index(before: visibleIDs.endIndex)
        )
        return visibleIDs[targetIndex]
    }

    static func retainedSelection(_ currentID: String?, visibleIDs: [String]) -> String? {
        guard let currentID, visibleIDs.contains(currentID) else {
            return nil
        }
        return currentID
    }
}

@MainActor
enum KeyboardCheatsheetCopyCommand {
    static func matches(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard event.type == .keyDown,
              !event.isARepeat,
              normalizedModifiers(event.modifierFlags) == [.command],
              let characters = event.charactersIgnoringModifiers,
              characters.caseInsensitiveCompare("c") == .orderedSame else {
            return false
        }

        return !textInputHasSelection(firstResponder)
    }

    private static func textInputHasSelection(_ firstResponder: NSResponder?) -> Bool {
        if let textView = firstResponder as? NSTextView {
            return textView.selectedRange().length > 0
        }

        if let textField = firstResponder as? NSTextField,
           let editor = textField.currentEditor() {
            return editor.selectedRange.length > 0
        }

        return false
    }

    private static func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
    }
}

enum KeyboardCheatsheetSearchCommand: Equatable {
    case move(Int)
    case runSelected
    case dismiss

    static func command(for selector: Selector) -> KeyboardCheatsheetSearchCommand? {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            .move(1)
        case #selector(NSResponder.moveUp(_:)):
            .move(-1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            .runSelected
        case #selector(NSResponder.cancelOperation(_:)):
            .dismiss
        default:
            nil
        }
    }

    static func command(forKeyCode keyCode: UInt16) -> KeyboardCheatsheetSearchCommand? {
        switch Int(keyCode) {
        case kVK_Escape:
            .dismiss
        case kVK_DownArrow:
            .move(1)
        case kVK_UpArrow:
            .move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            .runSelected
        default:
            nil
        }
    }

    @MainActor
    static func command(for event: NSEvent, firstResponder: NSResponder?) -> KeyboardCheatsheetSearchCommand? {
        guard event.type == .keyDown,
              !event.isARepeat,
              normalizedModifiers(event.modifierFlags).isDisjoint(with: [.command, .option]),
              !hasMarkedText(firstResponder) else {
            return nil
        }

        return command(forKeyCode: event.keyCode)
    }

    @MainActor
    private static func hasMarkedText(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.hasMarkedText()
        }

        if let textField = responder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView {
            return editor.hasMarkedText()
        }

        return false
    }

    private static func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
    }
}
