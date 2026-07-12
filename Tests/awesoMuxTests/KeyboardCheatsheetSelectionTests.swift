import AppKit
import Carbon.HIToolbox
import Testing
@testable import awesoMux

@MainActor
@Suite("Keyboard cheatsheet selection")
struct KeyboardCheatsheetSelectionTests {
    @Test("arrow down from no selection chooses the first visible row")
    func arrowDownFromNoSelectionChoosesFirstVisibleRow() {
        #expect(KeyboardCheatsheetSelection.movedSelection(
            currentID: nil,
            visibleIDs: ["newWorkspace", "splitRight", "toggleCommandPalette"],
            delta: 1
        ) == "newWorkspace")
    }

    @Test("arrow up from no selection chooses the last visible row")
    func arrowUpFromNoSelectionChoosesLastVisibleRow() {
        #expect(KeyboardCheatsheetSelection.movedSelection(
            currentID: nil,
            visibleIDs: ["newWorkspace", "splitRight", "toggleCommandPalette"],
            delta: -1
        ) == "toggleCommandPalette")
    }

    @Test("arrow navigation clamps at list edges")
    func arrowNavigationClampsAtListEdges() {
        let ids = ["newWorkspace", "splitRight", "toggleCommandPalette"]

        #expect(KeyboardCheatsheetSelection.movedSelection(
            currentID: "newWorkspace",
            visibleIDs: ids,
            delta: -1
        ) == "newWorkspace")
        #expect(KeyboardCheatsheetSelection.movedSelection(
            currentID: "toggleCommandPalette",
            visibleIDs: ids,
            delta: 1
        ) == "toggleCommandPalette")
    }

    @Test("filtering drops selections that are no longer visible")
    func filteringDropsSelectionsThatAreNoLongerVisible() {
        #expect(KeyboardCheatsheetSelection.retainedSelection(
            "splitRight",
            visibleIDs: ["newWorkspace", "toggleCommandPalette"]
        ) == nil)
        #expect(KeyboardCheatsheetSelection.retainedSelection(
            "splitRight",
            visibleIDs: ["newWorkspace", "splitRight"]
        ) == "splitRight")
    }

    @Test("search field maps arrow and escape commands")
    func searchFieldMapsArrowAndEscapeCommands() {
        #expect(KeyboardCheatsheetSearchCommand.command(for: #selector(NSResponder.moveDown(_:))) == .move(1))
        #expect(KeyboardCheatsheetSearchCommand.command(for: #selector(NSResponder.moveUp(_:))) == .move(-1))
        #expect(KeyboardCheatsheetSearchCommand.command(for: #selector(NSResponder.insertNewline(_:))) == .runSelected)
        #expect(KeyboardCheatsheetSearchCommand.command(
            for: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        ) == .runSelected)
        #expect(KeyboardCheatsheetSearchCommand.command(for: #selector(NSResponder.cancelOperation(_:))) == .dismiss)
        #expect(KeyboardCheatsheetSearchCommand.command(forKeyCode: UInt16(kVK_DownArrow)) == .move(1))
        #expect(KeyboardCheatsheetSearchCommand.command(forKeyCode: UInt16(kVK_UpArrow)) == .move(-1))
        #expect(KeyboardCheatsheetSearchCommand.command(forKeyCode: UInt16(kVK_Return)) == .runSelected)
        #expect(KeyboardCheatsheetSearchCommand.command(forKeyCode: UInt16(kVK_ANSI_KeypadEnter)) == .runSelected)
        #expect(KeyboardCheatsheetSearchCommand.command(forKeyCode: UInt16(kVK_Escape)) == .dismiss)
    }

    @Test("search key events ignore modified return and arrows")
    func searchKeyEventsIgnoreModifiedReturnAndArrows() throws {
        let commandReturn = try #require(makeKeyEvent(
            modifierFlags: [.command],
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: UInt16(kVK_Return)
        ))
        let optionUp = try #require(makeKeyEvent(
            modifierFlags: [.option],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: UInt16(kVK_UpArrow)
        ))

        #expect(KeyboardCheatsheetSearchCommand.command(for: commandReturn, firstResponder: nil) == nil)
        #expect(KeyboardCheatsheetSearchCommand.command(for: optionUp, firstResponder: nil) == nil)
    }

    @Test("copy text uses readable shortcut tokens")
    func copyTextUsesReadableShortcutTokens() {
        #expect(
            KeyboardCheatsheetCopyText.text(for: KeyboardShortcutCatalog.showKeyboardCheatsheetEntry)
                == "Keyboard Shortcuts - ⌘ /"
        )
    }

    @Test("model exposes copy text only for the selected visible row")
    func modelExposesCopyTextOnlyForSelectedVisibleRow() {
        let model = KeyboardCheatsheetModel(sections: KeyboardShortcutCatalog.settingsSections)
        #expect(model.selectedShortcutCopyText == nil)

        model.selectedEntryID = "showKeyboardCheatsheet"
        #expect(model.selectedShortcutCopyText == "Keyboard Shortcuts - ⌘ /")

        model.query = "split"
        #expect(model.selectedShortcutCopyText == nil)
    }

    @Test("copy command preserves native text selection copy")
    func copyCommandPreservesNativeTextSelectionCopy() throws {
        let event = try #require(makeKeyEvent(
            modifierFlags: .command,
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 0x08
        ))
        let textView = NSTextView()
        textView.string = "selected search text"

        textView.setSelectedRange(NSRange(location: 0, length: 8))
        #expect(!KeyboardCheatsheetCopyCommand.matches(event, firstResponder: textView))

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(KeyboardCheatsheetCopyCommand.matches(event, firstResponder: textView))
    }

    @Test("copy command ignores nearby chords")
    func copyCommandIgnoresNearbyChords() throws {
        let shiftedCopy = try #require(makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "C",
            charactersIgnoringModifiers: "c",
            keyCode: 0x08
        ))
        let plainCopy = try #require(makeKeyEvent(
            modifierFlags: [],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 0x08
        ))

        #expect(!KeyboardCheatsheetCopyCommand.matches(shiftedCopy, firstResponder: nil))
        #expect(!KeyboardCheatsheetCopyCommand.matches(plainCopy, firstResponder: nil))
    }
}

private func makeKeyEvent(
    type: NSEvent.EventType = .keyDown,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String,
    charactersIgnoringModifiers: String,
    isARepeat: Bool = false,
    keyCode: UInt16
) -> NSEvent? {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: isARepeat,
        keyCode: keyCode
    )
}
