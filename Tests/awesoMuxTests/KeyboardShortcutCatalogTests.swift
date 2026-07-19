import AppKit
import AwesoMuxConfig
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import awesoMux

@Suite("KeyboardShortcutCatalog")
struct KeyboardShortcutCatalogTests {
    @Test("focus sidebar uses control command s")
    func focusSidebarUsesControlCommandS() {
        let binding = KeyboardShortcutCatalog.focusSidebar

        #expect(binding.key == "s")
        #expect(binding.modifiers == [.control, .command])
        #expect(binding.displaySymbol == "⌃⌘S")
    }

    @Test("toggle sidebar width uses command backslash")
    func toggleSidebarWidthUsesCommandBackslash() {
        let binding = KeyboardShortcutCatalog.toggleSidebarWidth

        #expect(binding.id == "toggleSidebarWidth")
        #expect(binding.action == "Collapse/Expand Sidebar")
        #expect(binding.key == "\\")
        #expect(binding.modifiers == [.command])
        #expect(binding.displaySymbol == "⌘\\")
        #expect(binding.spokenForm == "Command Backslash")
    }

    @Test("toggle sidebar visibility uses shift command backslash")
    func toggleSidebarVisibilityUsesShiftCommandBackslash() {
        let binding = KeyboardShortcutCatalog.toggleSidebarVisibility
        #expect(binding.id == "toggleSidebarVisibility")
        #expect(binding.action == "Hide/Show Sidebar")
        #expect(binding.key == "\\")
        #expect(binding.modifiers == [.command, .shift])
        #expect(binding.displaySymbol == "⇧⌘\\")
        #expect(binding.spokenForm == "Shift Command Backslash")
    }

    @Test("sidebar commands appear in shortcut settings")
    func sidebarCommandsAppearInShortcutSettings() throws {
        let workspaces = try #require(KeyboardShortcutCatalog.settingsSections.first { $0.title == "Workspaces" })
        let bindings = Dictionary(uniqueKeysWithValues: workspaces.entries.flatMap(\.bindings).map { ($0.id, $0) })
        #expect(bindings["toggleSidebarWidth"]?.action == "Collapse/Expand Sidebar")
        #expect(bindings["toggleSidebarWidth"]?.displaySymbol == "⌘\\")
        #expect(bindings["toggleSidebarVisibility"]?.action == "Hide/Show Sidebar")
        #expect(bindings["toggleSidebarVisibility"]?.displaySymbol == "⇧⌘\\")
    }

    @Test("custom shortcut config overrides catalog binding")
    func customShortcutConfigOverridesCatalogBinding() throws {
        let keyboard = KeyboardConfig(
            shortcuts: [
                KeyboardShortcutCatalog.toggleFloatingPanel.id: ShortcutBindingConfig(
                    key: ";",
                    modifiers: [.command, .option]
                )
            ]
        )
        let binding = try #require(
            KeyboardShortcutCatalog.resolvedBinding(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id,
                keyboard: keyboard
            ))

        #expect(binding.key == ";")
        #expect(binding.modifiers == [.command, .option])
        #expect(binding.displaySymbol == "⌥⌘;")
        #expect(binding.spokenForm == "Option Command Semicolon")
    }

    @Test("custom shortcut collision reports existing action")
    func customShortcutCollisionReportsExistingAction() throws {
        let collision = try #require(
            KeyboardShortcutCatalog.collision(
                for: KeyboardShortcutCatalog.splitRight.configValue,
                assigning: KeyboardShortcutCatalog.toggleFloatingPanel.id,
                keyboard: .defaultValue
            ))

        #expect(collision.id == KeyboardShortcutCatalog.splitRight.id)
        #expect(collision.action == KeyboardShortcutCatalog.splitRight.action)
    }

    @Test("reserved and invalid shortcuts are rejected")
    func reservedAndInvalidShortcutsAreRejected() {
        #expect(
            KeyboardShortcutCatalog.validationMessage(
                for: ShortcutBindingConfig(
                    key: "q",
                    modifiers: [.command]
                )) == "That shortcut is reserved by macOS.")
        #expect(
            KeyboardShortcutCatalog.validationMessage(
                for: ShortcutBindingConfig(
                    key: "x",
                    modifiers: []
                )) == "Shortcuts must include the Command key.")
    }

    @Test("resetting an override restores the default binding")
    func resetOverrideRestoresDefaultBinding() throws {
        let overridden = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.toggleFloatingPanel.id: ShortcutBindingConfig(
                key: ";",
                modifiers: [.command, .option]
            )
        ])

        let changed = try #require(
            KeyboardShortcutCatalog.resolvedBinding(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id,
                keyboard: overridden
            ))
        let reset = try #require(
            KeyboardShortcutCatalog.resolvedBinding(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id,
                keyboard: .defaultValue
            ))

        #expect(changed.displaySymbol == "⌥⌘;")
        #expect(reset.displaySymbol == "⌘'")
    }

    @Test("event matcher follows cached override and reset")
    @MainActor
    func eventMatcherFollowsCachedOverrideAndReset() throws {
        let originalKeyboard = CurrentKeyboardShortcuts.keyboard
        defer { CurrentKeyboardShortcuts.keyboard = originalKeyboard }

        let defaultEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command],
                characters: "'",
                charactersIgnoringModifiers: "'",
                keyCode: 0x27
            ))
        let overrideEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .option],
                characters: ";",
                charactersIgnoringModifiers: ";",
                keyCode: 0x29
            ))

        CurrentKeyboardShortcuts.keyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.toggleFloatingPanel.id: ShortcutBindingConfig(
                key: ";",
                modifiers: [.command, .option]
            )
        ])
        let overridden = try #require(
            CurrentKeyboardShortcuts.binding(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id
            ))

        #expect(overridden.matches(overrideEvent))
        #expect(!overridden.matches(defaultEvent))

        CurrentKeyboardShortcuts.keyboard = .defaultValue
        let reset = try #require(
            CurrentKeyboardShortcuts.binding(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id
            ))

        #expect(reset.matches(defaultEvent))
        #expect(!reset.matches(overrideEvent))
    }

    @Test("shortcut capture cancels only for bare escape")
    func shortcutCaptureCancelsOnlyForBareEscape() throws {
        let bareEscape = try #require(
            makeKeyEvent(
                modifierFlags: [],
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                keyCode: UInt16(kVK_Escape)
            ))
        let commandEscape = try #require(
            makeKeyEvent(
                modifierFlags: [.command],
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                keyCode: UInt16(kVK_Escape)
            ))

        #expect(ShortcutCapture.shouldCancel(bareEscape))
        #expect(!ShortcutCapture.shouldCancel(commandEscape))
    }

    @Test("shortcut capture normalizes equal shifted punctuation fields")
    func shortcutCaptureNormalizesEqualShiftedPunctuationFields() throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "|",
                charactersIgnoringModifiers: "|",
                keyCode: 0x2A))

        let captured = try #require(ShortcutCapture.capturedBinding(from: event))

        #expect(captured.key == "\\")
        #expect(captured.modifiers == [.shift, .command])
    }

    @Test("settings data use an override")
    func settingsDataUseOverride() throws {
        let keyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.previousDocumentTab.id: ShortcutBindingConfig(
                key: ",",
                modifiers: [.command, .control]
            )
        ])
        let general = try #require(
            KeyboardShortcutCatalog.settingsSections(keyboard: keyboard)
                .first { $0.title == "General" }
        )
        let binding = try #require(
            general.entries.flatMap(\.bindings)
                .first { $0.id == KeyboardShortcutCatalog.previousDocumentTab.id }
        )

        #expect(binding.displaySymbol == "⌃⌘,")
    }

    @Test("command palette uses command k")
    func commandPaletteUsesCommandK() {
        let binding = KeyboardShortcutCatalog.toggleCommandPalette

        #expect(binding.key == "k")
        #expect(binding.modifiers == [.command])
        #expect(binding.displaySymbol == "⌘K")
        #expect(binding.spokenForm == "Command Key K")
    }

    @Test("command palette display symbol follows custom binding")
    func commandPaletteDisplaySymbolFollowsCustomBinding() {
        let keyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.toggleCommandPalette.id: ShortcutBindingConfig(
                key: "p",
                modifiers: [.command, .option]
            )
        ])

        #expect(KeyboardShortcutCatalog.commandPaletteDisplaySymbol(keyboard: keyboard) == "⌥⌘P")
    }

    @Test("open markdown file uses command o")
    func openMarkdownFileUsesCommandO() {
        let binding = KeyboardShortcutCatalog.openMarkdownFile

        #expect(binding.id == "openMarkdownFile")
        #expect(binding.action == "Open Markdown File…")
        #expect(binding.key == "o")
        #expect(binding.modifiers == [.command])
        #expect(binding.displaySymbol == "⌘O")
        #expect(binding.spokenForm == "Command Key O")
    }

    @Test("open markdown file ships in the General settings section")
    func openMarkdownFileAppearsInGeneralSection() throws {
        let general = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "General" }
        )

        #expect(general.entries.flatMap(\.bindings).map(\.id).contains("openMarkdownFile"))
    }

    @Test("workspace jump shortcuts use command digits one through nine")
    func workspaceJumpShortcutsUseCommandDigits() {
        let bindings = KeyboardShortcutCatalog.jumpWorkspaces

        #expect(bindings.count == 9)
        for (offset, binding) in bindings.enumerated() {
            let digit = String(offset + 1)
            #expect(binding.id == "jumpWorkspace\(digit)")
            #expect(binding.action == "Jump to Workspace \(digit)")
            #expect(binding.key == KeyEquivalent(Character(digit)))
            #expect(binding.modifiers == [.command])
            #expect(binding.displaySymbol == "⌘\(digit)")
            #expect(binding.spokenForm == "Command \(digit)")
        }
    }

    @Test("focus pane shortcuts use option command digits one through nine")
    func focusPaneShortcutsUseOptionCommandDigits() {
        let bindings = KeyboardShortcutCatalog.focusPaneBindings

        #expect(bindings.count == 9)
        for (offset, binding) in bindings.enumerated() {
            let digit = String(offset + 1)
            #expect(binding.id == "focusPane\(digit)")
            #expect(binding.action == "Focus Pane \(digit)")
            #expect(binding.key == KeyEquivalent(Character(digit)))
            #expect(binding.modifiers == [.command, .option])
            #expect(binding.displaySymbol == "⌥⌘\(digit)")
            #expect(binding.spokenForm == "Option Command \(digit)")
        }
    }

    @Test("focus pane shortcuts ship in the Panes settings section")
    func focusPaneShortcutsAppearInPanesSection() throws {
        let panes = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "Panes" }
        )
        let ids = panes.entries.flatMap(\.bindings).map(\.id)
        for index in 1...9 {
            #expect(ids.contains("focusPane\(index)"))
        }
    }

    @Test("move pane shortcuts use option command arrows")
    func movePaneShortcutsUseOptionCommandArrows() {
        let cases: [(KeyBinding, KeyEquivalent, String, String)] = [
            (KeyboardShortcutCatalog.movePaneUp, .upArrow, "⌥⌘↑", "Move Pane Up"),
            (KeyboardShortcutCatalog.movePaneDown, .downArrow, "⌥⌘↓", "Move Pane Down"),
            (KeyboardShortcutCatalog.movePaneLeft, .leftArrow, "⌥⌘←", "Move Pane Left"),
            (KeyboardShortcutCatalog.movePaneRight, .rightArrow, "⌥⌘→", "Move Pane Right"),
        ]
        for (binding, key, display, action) in cases {
            #expect(binding.key == key)
            #expect(binding.modifiers == [.command, .option])
            #expect(binding.displaySymbol == display)
            #expect(binding.action == action)
        }
    }

    @Test("move pane shortcuts ship in the Panes settings section")
    func movePaneShortcutsAppearInPanesSection() throws {
        let panes = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "Panes" }
        )
        let ids = panes.entries.flatMap(\.bindings).map(\.id)
        #expect(ids.contains("movePaneUp"))
        #expect(ids.contains("movePaneDown"))
        #expect(ids.contains("movePaneLeft"))
        #expect(ids.contains("movePaneRight"))
    }

    @Test("swap pane with next uses option command s")
    func swapPaneWithNextUsesOptionCommandS() {
        let binding = KeyboardShortcutCatalog.swapPaneWithNext

        #expect(binding.key == "s")
        #expect(binding.modifiers == [.command, .option])
        #expect(binding.displaySymbol == "⌥⌘S")
        #expect(binding.action == "Swap Pane With Next")
    }

    @Test("swap pane with next ships in the Panes settings section")
    func swapPaneWithNextAppearsInPanesSection() throws {
        let panes = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "Panes" }
        )
        let ids = panes.entries.flatMap(\.bindings).map(\.id)
        #expect(ids.contains("swapPaneWithNext"))
    }

    @Test("find shortcuts use command f and command shift f")
    func findShortcutsUseCommandFPair() {
        let find = KeyboardShortcutCatalog.find
        let dump = KeyboardShortcutCatalog.scrollbackDump

        #expect(find.key == "f")
        #expect(find.modifiers == [.command])
        #expect(find.displaySymbol == "⌘F")
        #expect(find.action == "Find in Pane")

        #expect(dump.key == "f")
        #expect(dump.modifiers == [.command, .shift])
        #expect(dump.displaySymbol == "⇧⌘F")
        #expect(dump.action == "Show Scrollback")
    }

    @Test("find shortcuts ship in the Panes settings section")
    func findShortcutsAppearInPanesSection() throws {
        let panes = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "Panes" }
        )
        let ids = panes.entries.flatMap(\.bindings).map(\.id)

        #expect(ids.contains("find"))
        #expect(ids.contains("scrollbackDump"))
    }

    @Test("command palette ships in its settings section")
    func commandPaletteAppearsInSettingsSection() throws {
        let search = try #require(
            KeyboardShortcutCatalog.settingsSections.first { $0.title == "Search" }
        )
        #expect(search.entries.map(\.id) == ["toggleCommandPalette", "showKeyboardCheatsheet"])
    }

    @Test("keyboard cheatsheet uses command slash")
    func keyboardCheatsheetUsesCommandSlash() throws {
        let entry = try #require(
            KeyboardShortcutCatalog.settingsSections
                .flatMap(\.entries)
                .first { $0.id == "showKeyboardCheatsheet" }
        )

        #expect(entry.bindings.map(\.id) == ["showKeyboardCheatsheet"])
        #expect(entry.bindings.map(\.displaySymbol) == ["⌘/"])
        #expect(entry.bindings[0].spokenForm == "Command Slash")
    }

    @Test("settings shortcuts have unique chords")
    func settingsShortcutsHaveUniqueChords() throws {
        let bindings = KeyboardShortcutCatalog.settingsSections
            .flatMap(\.entries)
            .flatMap(\.bindings)
        var seen: [String: String] = [:]

        for binding in bindings {
            let chord = "\(binding.modifiers.rawValue):\(binding.key)"
            let existingAction = seen[chord]

            #expect(
                existingAction == nil,
                "Duplicate shortcut \(binding.displaySymbol) for \(existingAction ?? "unknown") and \(binding.action)"
            )
            seen[chord] = binding.action
        }
    }

    @Test("pop-up terminal uses shifted floating-panel shortcut")
    func popUpTerminalUsesShiftedFloatingPanelShortcut() {
        let binding = KeyboardShortcutCatalog.togglePopUpTerminal
        #expect(binding.key == "'")
        #expect(binding.modifiers == [.command, .shift])
        #expect(binding.displaySymbol == "⇧⌘'")
        #expect(binding.spokenForm == "Shift Command Apostrophe")
    }

    @Test("terminal companion settings show its custom shortcut")
    func terminalCompanionSettingsShowCustomShortcut() throws {
        let keyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.togglePopUpTerminal.id: ShortcutBindingConfig(
                key: ";",
                modifiers: [.command, .control]
            )
        ])
        let panels = try #require(
            KeyboardShortcutCatalog.settingsSections(keyboard: keyboard)
                .first { $0.title == "Terminal Panels" }
        )
        let binding = try #require(
            panels.entries.flatMap(\.bindings)
                .first { $0.id == KeyboardShortcutCatalog.togglePopUpTerminal.id }
        )

        #expect(binding.displaySymbol == "⌃⌘;")
    }

    // Pins the HIG modifier order (Control, Option, Shift, Command) end to end.
    // No real catalog binding uses all four modifiers today, so this constructs
    // one directly rather than depending on a live binding that could vanish.
    @Test("full modifier chord follows HIG order in both display and spoken form")
    func fullModifierChordFollowsHIGOrder() {
        let binding = KeyBinding(
            id: "allModifiersFixture",
            action: "All Modifiers Fixture",
            key: "x",
            modifiers: [.control, .option, .shift, .command],
            keyDisplay: "X"
        )

        #expect(binding.displaySymbol == "⌃⌥⇧⌘X")
        #expect(binding.displayTokens == ["⌃", "⌥", "⇧", "⌘", "X"])
        #expect(binding.spokenForm == "Control Option Shift Command Key X")
    }

    @Test("all settings shortcut ids are unique")
    func allSettingsShortcutIdsAreUnique() {
        let ids = KeyboardShortcutCatalog.settingsSections
            .flatMap(\.entries)
            .flatMap(\.bindings)
            .map(\.id)
        var seen: Set<String> = []
        var duplicates: Set<String> = []

        for id in ids {
            if !seen.insert(id).inserted {
                duplicates.insert(id)
            }
        }

        #expect(duplicates.isEmpty, "Duplicate KeyBinding ids: \(duplicates.sorted())")
    }

    @Test("all settings entry ids are unique")
    func allSettingsEntryIdsAreUnique() {
        let ids = KeyboardShortcutCatalog.settingsSections
            .flatMap(\.entries)
            .map(\.id)
        var seen: Set<String> = []
        var duplicates: Set<String> = []

        for id in ids {
            if !seen.insert(id).inserted {
                duplicates.insert(id)
            }
        }

        #expect(duplicates.isEmpty, "Duplicate KeyboardShortcutEntry ids: \(duplicates.sorted())")
    }

    @Test("all settings section ids are unique")
    func allSettingsSectionIdsAreUnique() {
        let ids = KeyboardShortcutCatalog.settingsSections.map(\.id)
        var seen: Set<String> = []
        var duplicates: Set<String> = []

        for id in ids {
            if !seen.insert(id).inserted {
                duplicates.insert(id)
            }
        }

        #expect(duplicates.isEmpty, "Duplicate KeyboardShortcutSection ids: \(duplicates.sorted())")
    }

    @Test("shortcut matcher recognizes focus sidebar chord")
    @MainActor
    func shortcutMatcherRecognizesFocusSidebarChord() {
        let event = makeKeyEvent()

        #expect(event != nil)
        #expect(SidebarFocusShortcut.matches(event!))
    }

    @Test("shortcut matcher ignores caps lock and function noise")
    @MainActor
    func shortcutMatcherIgnoresCapsLockAndFunctionNoise() {
        let event = makeKeyEvent(modifierFlags: [.command, .control, .capsLock, .function])

        #expect(event != nil)
        #expect(SidebarFocusShortcut.matches(event!))
    }

    @Test("shortcut matcher follows menu character instead of hardware keycode")
    @MainActor
    func shortcutMatcherFollowsMenuCharacterInsteadOfHardwareKeycode() {
        let nonAnsiSEvent = makeKeyEvent(
            characters: "s",
            charactersIgnoringModifiers: "s",
            keyCode: 0x2D
        )
        let ansiSWithWrongCharacterEvent = makeKeyEvent(
            characters: "n",
            charactersIgnoringModifiers: "n",
            keyCode: 0x01
        )

        #expect(nonAnsiSEvent != nil)
        #expect(ansiSWithWrongCharacterEvent != nil)
        #expect(SidebarFocusShortcut.matches(nonAnsiSEvent!))
        #expect(!SidebarFocusShortcut.matches(ansiSWithWrongCharacterEvent!))
    }

    @Test("shortcut matcher preserves supplied non-ANSI logical characters")
    func shortcutMatcherPreservesSuppliedNonANSILogicalCharacters() throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .control, .shift],
                characters: "s",
                charactersIgnoringModifiers: "s",
                keyCode: 0x2D))

        #expect(ShortcutEventMatcher.matches(key: "s", event: event))
    }

    @Test("shortcut matcher aligns with catalog chord")
    @MainActor
    func shortcutMatcherAlignsWithCatalogChord() {
        let binding = KeyboardShortcutCatalog.focusSidebar
        let event = makeKeyEvent(modifierFlags: binding.modifiers.eventFlags)

        #expect(binding.key == "s")
        #expect(event != nil)
        #expect(SidebarFocusShortcut.matches(event!))
    }

    @Test("sidebar width toggle matcher aligns with catalog chord")
    @MainActor
    func sidebarWidthToggleMatcherAlignsWithCatalogChord() {
        let binding = KeyboardShortcutCatalog.toggleSidebarWidth
        let event = makeKeyEvent(
            modifierFlags: binding.modifiers.eventFlags,
            characters: "\\",
            charactersIgnoringModifiers: "\\",
            keyCode: 0x2A
        )

        #expect(binding.key == "\\")
        #expect(event != nil)
        #expect(SidebarWidthToggleShortcut.matches(event!))
    }

    @Test("sidebar width toggle matcher ignores nearby chords")
    @MainActor
    func sidebarWidthToggleMatcherIgnoresNearbyChords() {
        let controlCommandEvent = makeKeyEvent(
            modifierFlags: [.command, .control],
            characters: "\\",
            charactersIgnoringModifiers: "\\",
            keyCode: 0x2A
        )
        let wrongKeyEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "]",
            charactersIgnoringModifiers: "]",
            keyCode: 0x1E
        )
        let repeatEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "\\",
            charactersIgnoringModifiers: "\\",
            isARepeat: true,
            keyCode: 0x2A
        )

        #expect(controlCommandEvent != nil)
        #expect(wrongKeyEvent != nil)
        #expect(repeatEvent != nil)
        #expect(!SidebarWidthToggleShortcut.matches(controlCommandEvent!))
        #expect(!SidebarWidthToggleShortcut.matches(wrongKeyEvent!))
        #expect(!SidebarWidthToggleShortcut.matches(repeatEvent!))
        #expect(SidebarWidthToggleShortcut.isRepeat(ofToggleSidebarWidthChord: repeatEvent!))
    }

    @Test("sidebar visibility toggle matcher follows cached binding")
    @MainActor
    func sidebarVisibilityToggleMatcherFollowsCachedBinding() throws {
        let originalKeyboard = CurrentKeyboardShortcuts.keyboard
        defer { CurrentKeyboardShortcuts.keyboard = originalKeyboard }
        let defaultEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "|",
                charactersIgnoringModifiers: "\\",
                keyCode: 0x2A
            ))
        let overrideEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .option],
                characters: ";",
                charactersIgnoringModifiers: ";",
                keyCode: 0x29
            ))
        CurrentKeyboardShortcuts.keyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.toggleSidebarVisibility.id: ShortcutBindingConfig(key: ";", modifiers: [.command, .option])
        ])
        #expect(SidebarVisibilityToggleShortcut.matches(overrideEvent))
        #expect(!SidebarVisibilityToggleShortcut.matches(defaultEvent))
    }

    @Test("sidebar visibility toggle matcher ignores repeats")
    @MainActor
    func sidebarVisibilityToggleMatcherIgnoresRepeats() throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "|",
                charactersIgnoringModifiers: "\\",
                isARepeat: true,
                keyCode: 0x2A
            ))
        #expect(!SidebarVisibilityToggleShortcut.matches(event))
        #expect(SidebarVisibilityToggleShortcut.isRepeat(ofToggleSidebarVisibilityChord: event))
    }

    @Test("sidebar visibility toggle normalizes equal shifted punctuation fields")
    @MainActor
    func sidebarVisibilityToggleNormalizesEqualShiftedPunctuationFields() throws {
        let originalKeyboard = CurrentKeyboardShortcuts.keyboard
        defer { CurrentKeyboardShortcuts.keyboard = originalKeyboard }
        CurrentKeyboardShortcuts.keyboard = .defaultValue
        let initialEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "|",
                charactersIgnoringModifiers: "|",
                keyCode: 0x2A))
        let repeatEvent = try #require(
            makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "|",
                charactersIgnoringModifiers: "|",
                isARepeat: true,
                keyCode: 0x2A))

        #expect(SidebarVisibilityToggleShortcut.matches(initialEvent))
        #expect(!SidebarVisibilityToggleShortcut.matches(repeatEvent))
        #expect(
            SidebarVisibilityToggleShortcut.isRepeat(
                ofToggleSidebarVisibilityChord: repeatEvent))
    }

    @Test("command palette menu shortcut follows keyboard configuration")
    func commandPaletteMenuShortcutFollowsKeyboardConfiguration() {
        let defaultBinding = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.toggleCommandPalette,
            keyboard: .defaultValue
        )
        let remappedKeyboard = KeyboardConfig(shortcuts: [
            KeyboardShortcutCatalog.toggleCommandPalette.id: ShortcutBindingConfig(
                key: "p",
                modifiers: [.command, .option]
            )
        ])
        let remappedBinding = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.toggleCommandPalette,
            keyboard: remappedKeyboard
        )

        #expect(defaultBinding.key == "k")
        #expect(defaultBinding.modifiers == [.command])
        #expect(remappedBinding.key == "p")
        #expect(remappedBinding.modifiers == [.command, .option])
    }

    @Test("keyboard cheatsheet matcher aligns with command slash catalog chord")
    @MainActor
    func keyboardCheatsheetMatcherAlignsWithCommandSlashCatalogChord() {
        let binding = KeyboardShortcutCatalog.showKeyboardCheatsheet
        let event = makeKeyEvent(
            modifierFlags: binding.modifiers.eventFlags,
            characters: "/",
            charactersIgnoringModifiers: "/",
            keyCode: 0x2C
        )

        #expect(binding.key == "/")
        #expect(event != nil)
        #expect(KeyboardCheatsheetShortcut.matches(event!))
    }

    @Test("keyboard cheatsheet matcher tracks repeat state")
    @MainActor
    func keyboardCheatsheetMatcherTracksRepeatState() {
        let repeatEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "/",
            charactersIgnoringModifiers: "/",
            isARepeat: true,
            keyCode: 0x2C
        )

        #expect(repeatEvent != nil)
        #expect(!KeyboardCheatsheetShortcut.matches(repeatEvent!))
        #expect(KeyboardCheatsheetShortcut.isRepeat(ofKeyboardCheatsheetChord: repeatEvent!))
    }

    @Test("keyboard cheatsheet panel dismissal preserves search typing")
    @MainActor
    func keyboardCheatsheetPanelDismissalPreservesSearchTyping() {
        let textEvent = makeKeyEvent(
            modifierFlags: [],
            characters: "s",
            charactersIgnoringModifiers: "s",
            keyCode: 0x01
        )
        let repeatEvent = makeKeyEvent(
            modifierFlags: [],
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: true,
            keyCode: 0x01
        )

        #expect(textEvent != nil)
        #expect(repeatEvent != nil)
        #expect(
            KeyboardCheatsheetShortcut.shouldDismissPanelForUnhandledKey(
                textEvent!,
                firstResponder: nil
            ))
        #expect(
            !KeyboardCheatsheetShortcut.shouldDismissPanelForUnhandledKey(
                textEvent!,
                firstResponder: NSTextView()
            ))
        #expect(
            !KeyboardCheatsheetShortcut.shouldDismissPanelForUnhandledKey(
                repeatEvent!,
                firstResponder: nil
            ))
    }

    @Test("floating panel policy catches close chord")
    @MainActor
    func floatingPanelPolicyCatchesCloseChord() {
        let closeEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "w",
            charactersIgnoringModifiers: "w",
            keyCode: 0x0D
        )
        let repeatEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: true,
            keyCode: 0x0D
        )

        #expect(closeEvent != nil)
        #expect(repeatEvent != nil)
        #expect(FloatingPanelEventPolicy.isCloseChord(closeEvent!))
        #expect(!FloatingPanelEventPolicy.isCloseChord(repeatEvent!))
    }

    @Test("floating panel policy suppresses global workspace jumps")
    @MainActor
    func floatingPanelPolicySuppressesGlobalWorkspaceJumps() {
        let jumpEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "1",
            charactersIgnoringModifiers: "1",
            keyCode: 0x12
        )
        let zeroEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "0",
            charactersIgnoringModifiers: "0",
            keyCode: 0x1D
        )
        let shiftedEvent = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "1",
            charactersIgnoringModifiers: "1",
            keyCode: 0x12
        )
        // Keypad digits carry the .numericPad device flag; the shared normalizer
        // subtracts it so these match the character-based jump binding. "1" and
        // "9" bound the accepted range; keypad "0" stays outside it.
        let keypadJumpEvent = makeKeyEvent(
            modifierFlags: [.command, .numericPad],
            characters: "1",
            charactersIgnoringModifiers: "1",
            keyCode: 0x53  // kVK_ANSI_Keypad1
        )
        let keypadNineEvent = makeKeyEvent(
            modifierFlags: [.command, .numericPad],
            characters: "9",
            charactersIgnoringModifiers: "9",
            keyCode: 0x5C  // kVK_ANSI_Keypad9
        )
        let keypadZeroEvent = makeKeyEvent(
            modifierFlags: [.command, .numericPad],
            characters: "0",
            charactersIgnoringModifiers: "0",
            keyCode: 0x52  // kVK_ANSI_Keypad0
        )

        #expect(jumpEvent != nil)
        #expect(zeroEvent != nil)
        #expect(shiftedEvent != nil)
        #expect(keypadJumpEvent != nil)
        #expect(keypadNineEvent != nil)
        #expect(keypadZeroEvent != nil)
        #expect(FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(jumpEvent!))
        #expect(!FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(zeroEvent!))
        #expect(!FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(shiftedEvent!))
        #expect(FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(keypadJumpEvent!))
        #expect(FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(keypadNineEvent!))
        #expect(!FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(keypadZeroEvent!))
    }

    @Test("workspace command gate blocks while command palette is visible")
    func workspaceCommandGateBlocksWhileCommandPaletteIsVisible() {
        #expect(
            WorkspaceCommandShortcutPolicy.canRun(
                isAnySheetPresented: false,
                isCommandPaletteVisible: false,
                hasTarget: true
            ))
        #expect(
            !WorkspaceCommandShortcutPolicy.canRun(
                isAnySheetPresented: true,
                isCommandPaletteVisible: false,
                hasTarget: true
            ))
        #expect(
            !WorkspaceCommandShortcutPolicy.canRun(
                isAnySheetPresented: false,
                isCommandPaletteVisible: true,
                hasTarget: true
            ))
        #expect(
            !WorkspaceCommandShortcutPolicy.canRun(
                isAnySheetPresented: false,
                isCommandPaletteVisible: false,
                hasTarget: false
            ))
    }

    @Test("shortcut matcher does not recognize nearby focus sidebar chords")
    @MainActor
    func shortcutMatcherDoesNotRecognizeNearbyFocusSidebarChords() {
        let shiftedEvent = makeKeyEvent(
            modifierFlags: [.command, .control, .shift],
            characters: "S",
            charactersIgnoringModifiers: "S"
        )
        let optionEvent = makeKeyEvent(modifierFlags: [.command, .control, .option])
        let wrongKeyEvent = makeKeyEvent(characters: "n", charactersIgnoringModifiers: "n")
        let keyUpEvent = makeKeyEvent(type: .keyUp)
        let flagsChangedEvent = makeKeyEvent(type: .flagsChanged)
        let repeatEvent = makeKeyEvent(isARepeat: true)

        #expect(shiftedEvent != nil)
        #expect(optionEvent != nil)
        #expect(wrongKeyEvent != nil)
        #expect(keyUpEvent != nil)
        #expect(flagsChangedEvent != nil)
        #expect(repeatEvent != nil)
        #expect(!SidebarFocusShortcut.matches(shiftedEvent!))
        #expect(!SidebarFocusShortcut.matches(optionEvent!))
        #expect(!SidebarFocusShortcut.matches(wrongKeyEvent!))
        #expect(!SidebarFocusShortcut.matches(keyUpEvent!))
        #expect(!SidebarFocusShortcut.matches(flagsChangedEvent!))
        #expect(!SidebarFocusShortcut.matches(repeatEvent!))
        #expect(SidebarFocusShortcut.isRepeat(ofFocusSidebarChord: repeatEvent!))
    }
}

private func makeKeyEvent(
    type: NSEvent.EventType = .keyDown,
    modifierFlags: NSEvent.ModifierFlags = [.command, .control],
    characters: String = "s",
    charactersIgnoringModifiers: String = "s",
    isARepeat: Bool = false,
    keyCode: UInt16 = 0x01
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

private extension SwiftUI.EventModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) {
            flags.insert(.command)
        }
        if contains(.control) {
            flags.insert(.control)
        }
        if contains(.option) {
            flags.insert(.option)
        }
        if contains(.shift) {
            flags.insert(.shift)
        }
        return flags
    }
}
