import AwesoMuxConfig
import AppKit
import Carbon.HIToolbox
import SwiftUI

typealias ShortcutEventModifiers = SwiftUI.EventModifiers

struct KeyBinding: Identifiable {
    let id: String
    let action: String
    let key: KeyEquivalent
    let modifiers: ShortcutEventModifiers
    let displaySymbol: String
    let spokenForm: String
    let keyDisplay: String
    private let keySpokenName: String?

    init(
        id: String,
        action: String,
        key: KeyEquivalent,
        modifiers: ShortcutEventModifiers = .command,
        keyDisplay: String,
        // Required for any non-letter key (`[`, `]`, `=`, `-`, `;`, etc.).
        // Letters fall back to `"Key X"` so VoiceOver doesn't read a single
        // glyph as an ambiguous phoneme.
        keySpokenName: String? = nil
    ) {
        self.id = id
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.keyDisplay = keyDisplay
        self.keySpokenName = keySpokenName

        let displays = Self.modifierDisplays(for: modifiers)
        self.displaySymbol = displays.map(\.symbol).joined() + keyDisplay
        let spoken = keySpokenName ?? "Key \(keyDisplay.uppercased())"
        self.spokenForm = (displays.map(\.spokenName) + [spoken]).joined(separator: " ")
    }

    var displayTokens: [String] {
        Self.modifierDisplays(for: modifiers).map(\.symbol) + [keyDisplay]
    }

    var configValue: ShortcutBindingConfig {
        ShortcutBindingConfig(
            key: ShortcutKeyResolver.configKey(for: self),
            modifiers: modifiers.shortcutModifiers
        )
    }

    func applying(_ override: ShortcutBindingConfig?) -> KeyBinding {
        guard let override,
              KeyboardShortcutCatalog.validationMessage(for: override) == nil,
              let resolved = ShortcutKeyResolver.keyEquivalent(for: override.key)
        else {
            return self
        }

        let normalizedModifiers = ShortcutEventModifiers(override.modifiers)
        return KeyBinding(
            id: id,
            action: action,
            key: resolved.key,
            modifiers: normalizedModifiers,
            keyDisplay: resolved.display,
            keySpokenName: resolved.spokenName ?? keySpokenName
        )
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              ShortcutEventMatcher.modifiersMatch(
                expected: modifiers.eventFlags,
                event: event
              )
        else {
            return false
        }

        return ShortcutEventMatcher.matches(key: key, event: event)
    }

    // macOS HIG modifier order: Control, Option, Shift, Command.
    // Do not reorder — display and spoken form both depend on this sequence.
    private static func modifierDisplays(for modifiers: ShortcutEventModifiers) -> [ModifierDisplay] {
        [
            modifiers.contains(.control) ? .control : nil,
            modifiers.contains(.option) ? .option : nil,
            modifiers.contains(.shift) ? .shift : nil,
            modifiers.contains(.command) ? .command : nil
        ].compactMap { $0 }
    }
}

struct KeyboardShortcutEntry: Identifiable {
    let id: String
    let action: String
    let bindings: [KeyBinding]
    let detail: String?
    let keywords: [String]

    init(
        id: String,
        action: String,
        bindings: [KeyBinding],
        detail: String? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.action = action
        self.bindings = bindings
        self.detail = detail
        self.keywords = keywords
    }

    init(
        _ binding: KeyBinding,
        detail: String? = nil,
        keywords: [String] = []
    ) {
        self.init(
            id: binding.id,
            action: binding.action,
            bindings: [binding],
            detail: detail,
            keywords: keywords
        )
    }

    var primaryBinding: KeyBinding? {
        bindings.first
    }

    func matches(query: String, in sectionTitle: String) -> Bool {
        let foldedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !foldedQuery.isEmpty else {
            return true
        }

        let haystacks = [
            sectionTitle,
            action,
            detail
        ].compactMap { $0 }
            + keywords
            + bindings.flatMap { [$0.displaySymbol, $0.spokenForm] }

        return haystacks.contains { haystack in
            haystack
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(foldedQuery)
        }
    }
}

enum KeyboardShortcutCatalog {
    static let newWorkspace = KeyBinding(
        id: "newWorkspace",
        action: "New Workspace",
        key: "n",
        keyDisplay: "N"
    )

    static let newWorkspaceInCurrentDirectory = KeyBinding(
        id: "newWorkspaceInCurrentDirectory",
        action: "New Workspace in Current Directory",
        key: "n",
        modifiers: [.command, .option],
        keyDisplay: "N"
    )

    static let newWorkspaceGroup = KeyBinding(
        id: "newWorkspaceGroup",
        action: "New Workspace Group…",
        key: "n",
        modifiers: [.command, .control],
        keyDisplay: "N"
    )

    static let openMarkdownFile = KeyBinding(
        id: "openMarkdownFile",
        action: "Open Markdown File…",
        key: "o",
        keyDisplay: "O"
    )

    // Document tab cycling. `⌃⌘` brackets are clear: `⌘⌥[/]` is pane focus and
    // `⌘⇧[/]` is workspace switching, so each bracket family keeps one modifier
    // set. App-level commands per ADR-0020 — never Ghostty keybindings.
    static let previousDocumentTab = KeyBinding(
        id: "previousDocumentTab",
        action: "Previous Document Tab",
        key: "[",
        modifiers: [.command, .control],
        keyDisplay: "[",
        keySpokenName: "Left Bracket"
    )

    static let nextDocumentTab = KeyBinding(
        id: "nextDocumentTab",
        action: "Next Document Tab",
        key: "]",
        modifiers: [.command, .control],
        keyDisplay: "]",
        keySpokenName: "Right Bracket"
    )

    // The strip's per-tab close X refuses first responder (INT-562), so
    // keyboard users need an app-level close. `⌃⌘W` extends the close family
    // (⌘W pane, ⇧⌘W workspace) with the document-tab modifier set.
    static let closeDocumentTab = KeyBinding(
        id: "closeDocumentTab",
        action: "Close Document Tab",
        key: "w",
        modifiers: [.command, .control],
        keyDisplay: "W"
    )

    static let renameWorkspace = KeyBinding(
        id: "renameWorkspace",
        action: "Rename Workspace",
        key: "r",
        modifiers: [.command, .shift],
        keyDisplay: "R"
    )

    static let renamePane = KeyBinding(
        id: "renamePane",
        action: "Rename Pane",
        key: "r",
        modifiers: [.command, .option],
        keyDisplay: "R"
    )

    static let closeWorkspace = KeyBinding(
        id: "closeWorkspace",
        action: "Close Workspace",
        key: "w",
        modifiers: [.command, .shift],
        keyDisplay: "W"
    )

    // Option layer on the close-workspace chord: soft close (⇧⌘W) is
    // undoable via reopen, clear (⌥⇧⌘W) is permanent — INT-282.
    static let clearWorkspace = KeyBinding(
        id: "clearWorkspace",
        action: "Clear Workspace",
        key: "w",
        modifiers: [.command, .shift, .option],
        keyDisplay: "W"
    )

    static let reopenClosedWorkspace = KeyBinding(
        id: "reopenClosedWorkspace",
        action: "Reopen Closed Workspace",
        key: "t",
        modifiers: [.command, .shift],
        keyDisplay: "T"
    )

    static let splitRight = KeyBinding(
        id: "splitRight",
        action: "Split Right",
        key: "d",
        keyDisplay: "D"
    )

    static let splitDown = KeyBinding(
        id: "splitDown",
        action: "Split Down",
        key: "d",
        modifiers: [.command, .shift],
        keyDisplay: "D"
    )

    static let closePane = KeyBinding(
        id: "closePane",
        action: "Close Pane",
        key: "w",
        keyDisplay: "W"
    )

    static let find = KeyBinding(
        id: "find",
        action: "Find in Pane",
        key: "f",
        keyDisplay: "F"
    )

    static let scrollbackDump = KeyBinding(
        id: "scrollbackDump",
        action: "Show Scrollback",
        key: "f",
        modifiers: [.command, .shift],
        keyDisplay: "F"
    )

    static let previousPane = KeyBinding(
        id: "previousPane",
        action: "Previous Pane",
        key: "[",
        modifiers: [.command, .option],
        keyDisplay: "[",
        keySpokenName: "Left Bracket"
    )

    static let nextPane = KeyBinding(
        id: "nextPane",
        action: "Next Pane",
        key: "]",
        modifiers: [.command, .option],
        keyDisplay: "]",
        keySpokenName: "Right Bracket"
    )

    static let growActivePane = KeyBinding(
        id: "growActivePane",
        action: "Grow Active Pane",
        key: "=",
        modifiers: [.command, .option],
        keyDisplay: "=",
        keySpokenName: "Equals"
    )

    static let shrinkActivePane = KeyBinding(
        id: "shrinkActivePane",
        action: "Shrink Active Pane",
        key: "-",
        modifiers: [.command, .option],
        keyDisplay: "-",
        keySpokenName: "Minus"
    )

    // Pane MOVE family. `⌘⌥` arrows are clear globally: the only arrow-key
    // bindings in the app are the divider's keyboard resize, which is
    // focus-scoped (`.onKeyPress` fires only while the divider holds focus),
    // so it can't collide with these app-level command chords.
    static let movePaneUp = KeyBinding(
        id: "movePaneUp",
        action: "Move Pane Up",
        key: .upArrow,
        modifiers: [.command, .option],
        keyDisplay: "↑",
        keySpokenName: "Up Arrow"
    )

    static let movePaneDown = KeyBinding(
        id: "movePaneDown",
        action: "Move Pane Down",
        key: .downArrow,
        modifiers: [.command, .option],
        keyDisplay: "↓",
        keySpokenName: "Down Arrow"
    )

    static let movePaneLeft = KeyBinding(
        id: "movePaneLeft",
        action: "Move Pane Left",
        key: .leftArrow,
        modifiers: [.command, .option],
        keyDisplay: "←",
        keySpokenName: "Left Arrow"
    )

    static let movePaneRight = KeyBinding(
        id: "movePaneRight",
        action: "Move Pane Right",
        key: .rightArrow,
        modifiers: [.command, .option],
        keyDisplay: "→",
        keySpokenName: "Right Arrow"
    )

    // Pane SWAP. `⌘⌥S` is free: the only other `s` chord is Focus Sidebar
    // (`⌃⌘S`), and `⌘⌥` is the pane-family modifier (move/focus already live
    // there), so swap reads as part of the same group. Keyboard parity for the
    // center-zone drag-swap (WCAG 2.1.1).
    static let swapPaneWithNext = KeyBinding(
        id: "swapPaneWithNext",
        action: "Swap Pane With Next",
        key: "s",
        modifiers: [.command, .option],
        keyDisplay: "S"
    )

    static let focusPaneBindings: [KeyBinding] = (1...9).map { index in
        let key = String(index)
        return KeyBinding(
            id: "focusPane\(index)",
            action: "Focus Pane \(index)",
            key: KeyEquivalent(Character(key)),
            modifiers: [.command, .option],
            keyDisplay: key,
            keySpokenName: key
        )
    }

    static let acknowledgeWorkspace = KeyBinding(
        id: "acknowledgeWorkspace",
        action: "Acknowledge Workspace",
        key: "k",
        modifiers: [.command, .shift],
        keyDisplay: "K"
    )

    /// Moves keyboard/VoiceOver focus TO the active remote permission prompt —
    /// the one deliberate, user-initiated focus move the accessibility contract
    /// requires (arrival never steals focus, so we must provide the route back).
    /// Default ⌘⇧A ("Authorize"); user-rebindable like every catalog entry.
    static let focusPermissionPrompt = KeyBinding(
        id: "focusPermissionPrompt",
        action: "Focus Permission Prompt",
        key: "a",
        modifiers: [.command, .shift],
        keyDisplay: "A"
    )

    static let togglePinWorkspace = KeyBinding(
        id: "togglePinWorkspace",
        action: "Pin or Unpin Workspace",
        key: "p",
        modifiers: [.command, .option],
        keyDisplay: "P"
    )

    static let toggleCommandPalette = KeyBinding(
        id: "toggleCommandPalette",
        action: "Command Palette",
        key: "k",
        keyDisplay: "K"
    )

    static let showKeyboardCheatsheet = KeyBinding(
        id: "showKeyboardCheatsheet",
        action: "Keyboard Shortcuts",
        key: "/",
        keyDisplay: "/",
        keySpokenName: "Slash"
    )

    static let focusSidebar = KeyBinding(
        id: "focusSidebar",
        action: "Focus Sidebar",
        key: "s",
        modifiers: [.command, .control],
        keyDisplay: "S"
    )

    static let sessionManager = KeyBinding(
        id: "sessionManager",
        action: "Session Manager",
        key: "s",
        modifiers: [.command, .shift],
        keyDisplay: "S"
    )

    static let toggleSidebarWidth = KeyBinding(
        id: "toggleSidebarWidth",
        action: "Collapse/Expand Sidebar",
        key: "\\",
        keyDisplay: "\\",
        keySpokenName: "Backslash"
    )

    static let jumpWorkspaces: [KeyBinding] = (1...9).map { index in
        let key = String(index)
        return KeyBinding(
            id: "jumpWorkspace\(index)",
            action: "Jump to Workspace \(index)",
            key: KeyEquivalent(Character(key)),
            keyDisplay: key,
            keySpokenName: key
        )
    }

    static let toggleFloatingPanel = KeyBinding(
        id: "toggleFloatingPanel",
        action: "Toggle Floating Panel",
        key: "'",
        keyDisplay: "'",
        keySpokenName: "Apostrophe"
    )

    static let togglePopUpTerminal = KeyBinding(
        id: "togglePopUpTerminal",
        action: "Toggle Terminal Companion",
        key: "'",
        modifiers: [.command, .shift],
        keyDisplay: "'",
        keySpokenName: "Apostrophe"
    )

    static let previousWorkspace = KeyBinding(
        id: "previousWorkspace",
        action: "Previous Workspace",
        key: "[",
        modifiers: [.command, .shift],
        keyDisplay: "[",
        keySpokenName: "Left Bracket"
    )

    static let nextWorkspace = KeyBinding(
        id: "nextWorkspace",
        action: "Next Workspace",
        key: "]",
        modifiers: [.command, .shift],
        keyDisplay: "]",
        keySpokenName: "Right Bracket"
    )

    static let showKeyboardCheatsheetEntry = KeyboardShortcutEntry(
        showKeyboardCheatsheet,
        detail: "Show all keyboard shortcuts",
        keywords: ["cheatsheet", "help", "shortcuts"]
    )

    static var settingsSections: [KeyboardShortcutSection] {
        settingsSections(keyboard: .defaultValue)
    }

    static func settingsSections(keyboard: KeyboardConfig) -> [KeyboardShortcutSection] {
        let newWorkspace = resolved(Self.newWorkspace, keyboard: keyboard)
        let newWorkspaceInCurrentDirectory = resolved(Self.newWorkspaceInCurrentDirectory, keyboard: keyboard)
        let newWorkspaceGroup = resolved(Self.newWorkspaceGroup, keyboard: keyboard)
        let openMarkdownFile = resolved(Self.openMarkdownFile, keyboard: keyboard)
        let previousDocumentTab = resolved(Self.previousDocumentTab, keyboard: keyboard)
        let nextDocumentTab = resolved(Self.nextDocumentTab, keyboard: keyboard)
        let closeDocumentTab = resolved(Self.closeDocumentTab, keyboard: keyboard)
        let renameWorkspace = resolved(Self.renameWorkspace, keyboard: keyboard)
        let renamePane = resolved(Self.renamePane, keyboard: keyboard)
        let closeWorkspace = resolved(Self.closeWorkspace, keyboard: keyboard)
        let clearWorkspace = resolved(Self.clearWorkspace, keyboard: keyboard)
        let reopenClosedWorkspace = resolved(Self.reopenClosedWorkspace, keyboard: keyboard)
        let splitRight = resolved(Self.splitRight, keyboard: keyboard)
        let splitDown = resolved(Self.splitDown, keyboard: keyboard)
        let closePane = resolved(Self.closePane, keyboard: keyboard)
        let find = resolved(Self.find, keyboard: keyboard)
        let scrollbackDump = resolved(Self.scrollbackDump, keyboard: keyboard)
        let previousPane = resolved(Self.previousPane, keyboard: keyboard)
        let nextPane = resolved(Self.nextPane, keyboard: keyboard)
        let growActivePane = resolved(Self.growActivePane, keyboard: keyboard)
        let shrinkActivePane = resolved(Self.shrinkActivePane, keyboard: keyboard)
        let movePaneUp = resolved(Self.movePaneUp, keyboard: keyboard)
        let movePaneDown = resolved(Self.movePaneDown, keyboard: keyboard)
        let movePaneLeft = resolved(Self.movePaneLeft, keyboard: keyboard)
        let movePaneRight = resolved(Self.movePaneRight, keyboard: keyboard)
        let swapPaneWithNext = resolved(Self.swapPaneWithNext, keyboard: keyboard)
        let focusPermissionPrompt = resolved(Self.focusPermissionPrompt, keyboard: keyboard)
        let focusPaneBindings = resolved(Self.focusPaneBindings, keyboard: keyboard)
        let acknowledgeWorkspace = resolved(Self.acknowledgeWorkspace, keyboard: keyboard)
        let togglePinWorkspace = resolved(Self.togglePinWorkspace, keyboard: keyboard)
        let toggleCommandPalette = resolved(Self.toggleCommandPalette, keyboard: keyboard)
        let showKeyboardCheatsheet = resolved(Self.showKeyboardCheatsheet, keyboard: keyboard)
        let focusSidebar = resolved(Self.focusSidebar, keyboard: keyboard)
        let sessionManager = resolved(Self.sessionManager, keyboard: keyboard)
        let toggleSidebarWidth = resolved(Self.toggleSidebarWidth, keyboard: keyboard)
        let jumpWorkspaces = resolved(Self.jumpWorkspaces, keyboard: keyboard)
        let toggleFloatingPanel = resolved(Self.toggleFloatingPanel, keyboard: keyboard)
        let togglePopUpTerminal = resolved(Self.togglePopUpTerminal, keyboard: keyboard)
        let previousWorkspace = resolved(Self.previousWorkspace, keyboard: keyboard)
        let nextWorkspace = resolved(Self.nextWorkspace, keyboard: keyboard)

        let showKeyboardCheatsheetEntry = KeyboardShortcutEntry(
            showKeyboardCheatsheet,
            detail: "Show all keyboard shortcuts",
            keywords: ["cheatsheet", "help", "shortcuts"]
        )

        return [
        KeyboardShortcutSection(
            title: "General",
            entries: [
                KeyboardShortcutEntry(newWorkspace, detail: "Create a new workspace"),
                KeyboardShortcutEntry(
                    newWorkspaceInCurrentDirectory,
                    detail: "Create a workspace from the selected workspace directory",
                    keywords: ["cwd"]
                ),
                KeyboardShortcutEntry(newWorkspaceGroup, detail: "Create a sidebar workspace group"),
                KeyboardShortcutEntry(openMarkdownFile, detail: "Open a Markdown file in a document pane"),
                KeyboardShortcutEntry(previousDocumentTab, detail: "Switch to the previous document tab", keywords: ["document", "tab"]),
                KeyboardShortcutEntry(nextDocumentTab, detail: "Switch to the next document tab", keywords: ["document", "tab"]),
                KeyboardShortcutEntry(closeDocumentTab, detail: "Close the selected document tab", keywords: ["document", "tab"]),
                KeyboardShortcutEntry(renameWorkspace, detail: "Rename the selected workspace"),
                KeyboardShortcutEntry(closeWorkspace, detail: "Close the selected workspace"),
                KeyboardShortcutEntry(clearWorkspace, detail: "Permanently close the selected workspace — no reopen", keywords: ["clear", "permanent", "delete"]),
                KeyboardShortcutEntry(reopenClosedWorkspace, detail: "Restore the most recent eligible workspace")
            ]
        ),
        KeyboardShortcutSection(
            title: "Workspaces",
            entries: [
                KeyboardShortcutEntry(acknowledgeWorkspace, detail: "Clear attention on the active workspace"),
                KeyboardShortcutEntry(focusSidebar, detail: "Move keyboard focus to sidebar search"),
                KeyboardShortcutEntry(toggleSidebarWidth, detail: "Collapse or expand the sidebar"),
            ] + jumpWorkspaces.map {
                KeyboardShortcutEntry($0, detail: "Jump by flattened sidebar order")
            } + [
                KeyboardShortcutEntry(previousWorkspace, detail: "Move to the previous workspace"),
                KeyboardShortcutEntry(nextWorkspace, detail: "Move to the next workspace"),
                KeyboardShortcutEntry(togglePinWorkspace, detail: "Pin or unpin the selected workspace in the sidebar", keywords: ["pin", "favorite"])
            ]
        ),
        KeyboardShortcutSection(
            title: "Panes",
            entries: [
                KeyboardShortcutEntry(splitRight, detail: "Create a vertical split"),
                KeyboardShortcutEntry(splitDown, detail: "Create a horizontal split"),
                KeyboardShortcutEntry(renamePane, detail: "Pin a custom active pane title"),
                KeyboardShortcutEntry(closePane, detail: "Close or restart the active pane; may prompt when activity is at risk"),
                KeyboardShortcutEntry(find, detail: "Search terminal scrollback"),
                KeyboardShortcutEntry(scrollbackDump, detail: "Open scrollback in a text sheet"),
                KeyboardShortcutEntry(previousPane, detail: "Move focus within the pane tree"),
                KeyboardShortcutEntry(nextPane, detail: "Move focus within the pane tree"),
                KeyboardShortcutEntry(growActivePane, detail: "Resize the active split larger"),
                KeyboardShortcutEntry(shrinkActivePane, detail: "Resize the active split smaller"),
                KeyboardShortcutEntry(movePaneUp, detail: "Move the active pane toward the workspace edge"),
                KeyboardShortcutEntry(movePaneDown, detail: "Move the active pane toward the workspace edge"),
                KeyboardShortcutEntry(movePaneLeft, detail: "Move the active pane toward the workspace edge"),
                KeyboardShortcutEntry(movePaneRight, detail: "Move the active pane toward the workspace edge"),
                KeyboardShortcutEntry(swapPaneWithNext, detail: "Swap with the next pane in depth-first order"),
                KeyboardShortcutEntry(focusPermissionPrompt, detail: "Move focus to the active remote permission prompt", keywords: ["permission", "allow", "deny", "remote", "agent", "prompt"])
            ] + focusPaneBindings.map {
                KeyboardShortcutEntry($0, detail: "Focus pane by depth-first order")
            }
        ),
        KeyboardShortcutSection(
            title: "Terminal Panels",
            entries: [
                KeyboardShortcutEntry(toggleFloatingPanel, detail: "Show or hide the workspace floating panel"),
                KeyboardShortcutEntry(togglePopUpTerminal, detail: "Show or minimize the Terminal Companion")
            ]
        ),
        KeyboardShortcutSection(
            title: "Search",
            entries: [
                KeyboardShortcutEntry(toggleCommandPalette, detail: "Search workspaces and actions"),
                showKeyboardCheatsheetEntry
            ]
        ),
        KeyboardShortcutSection(
            title: "Misc",
            entries: [
                KeyboardShortcutEntry(sessionManager, detail: "Open background session management")
            ]
        )
        ]
    }

    static func resolved(_ binding: KeyBinding, keyboard: KeyboardConfig) -> KeyBinding {
        binding.applying(keyboard.shortcuts[binding.id])
    }

    static func resolved(_ bindings: [KeyBinding], keyboard: KeyboardConfig) -> [KeyBinding] {
        bindings.map { resolved($0, keyboard: keyboard) }
    }

    static func commandPaletteDisplaySymbol(keyboard: KeyboardConfig) -> String {
        resolved(toggleCommandPalette, keyboard: keyboard).displaySymbol
    }

    static func resolvedBinding(id: String, keyboard: KeyboardConfig) -> KeyBinding? {
        defaultBindingsByID[id].map {
            resolved($0, keyboard: keyboard)
        }
    }

    static func allBindings() -> [KeyBinding] {
        allBindings(keyboard: .defaultValue)
    }

    static func allBindings(keyboard: KeyboardConfig) -> [KeyBinding] {
        settingsSections(keyboard: keyboard)
            .flatMap(\.entries)
            .flatMap(\.bindings)
    }

    static func collision(
        for candidate: ShortcutBindingConfig,
        assigning bindingID: String,
        keyboard: KeyboardConfig
    ) -> KeyBinding? {
        guard let defaultBinding = defaultBindingsByID[bindingID] else {
            return nil
        }
        let candidateBinding = defaultBinding.applying(candidate)
        return allBindings(keyboard: keyboard).first { binding in
            binding.id != bindingID
                && binding.key == candidateBinding.key
                && binding.modifiers == candidateBinding.modifiers
        }
    }

    static func validationMessage(for candidate: ShortcutBindingConfig) -> String? {
        guard ShortcutKeyResolver.keyEquivalent(for: candidate.key) != nil else {
            return "That key can't be used as a shortcut."
        }
        guard candidate.modifiers.contains(.command) else {
            return "Shortcuts must include the Command key."
        }
        guard !isReservedSystemShortcut(candidate) else {
            return "That shortcut is reserved by macOS."
        }
        return nil
    }

    private static func isReservedSystemShortcut(_ candidate: ShortcutBindingConfig) -> Bool {
        let modifiers = Set(candidate.modifiers)
        guard modifiers == [.command] else { return false }
        return ["h", "m", "q"].contains(candidate.key.lowercased())
    }

    private static let defaultBindingsByID = Dictionary(
        uniqueKeysWithValues: settingsSections
            .flatMap(\.entries)
            .flatMap(\.bindings)
            .map { ($0.id, $0) }
    )
}

struct KeyboardShortcutSection: Identifiable {
    let title: String
    let entries: [KeyboardShortcutEntry]

    var id: String { title }
}

extension View {
    func keyboardShortcut(_ binding: KeyBinding) -> some View {
        keyboardShortcut(binding.key, modifiers: binding.modifiers)
    }
}

@MainActor
enum CurrentKeyboardShortcuts {
    static var keyboard = KeyboardConfig.defaultValue {
        didSet {
            bindingsByID = resolvedBindings(for: keyboard)
        }
    }

    private static var bindingsByID = resolvedBindings(for: .defaultValue)

    static func binding(id: String) -> KeyBinding? {
        bindingsByID[id]
    }

    private static func resolvedBindings(for keyboard: KeyboardConfig) -> [String: KeyBinding] {
        Dictionary(
            uniqueKeysWithValues: KeyboardShortcutCatalog.allBindings(keyboard: keyboard)
                .map { ($0.id, $0) }
        )
    }
}

enum ShortcutKeyResolver {
    static func keyEquivalent(for storedKey: String) -> (key: KeyEquivalent, display: String, spokenName: String?)? {
        switch storedKey {
        case "↑", "up_arrow":
            return (.upArrow, "↑", "Up Arrow")
        case "↓", "down_arrow":
            return (.downArrow, "↓", "Down Arrow")
        case "←", "left_arrow":
            return (.leftArrow, "←", "Left Arrow")
        case "→", "right_arrow":
            return (.rightArrow, "→", "Right Arrow")
        case " ":
            return (.space, "Space", "Space")
        case "\u{1b}", "escape":
            return (.escape, "Esc", "Escape")
        default:
            guard let character = storedKey.first, storedKey.count == 1 else {
                return nil
            }
            let display = String(character).uppercased()
            return (KeyEquivalent(character), display, spokenName(for: display))
        }
    }

    static func configKey(for binding: KeyBinding) -> String {
        switch binding.key {
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .space:
            return " "
        case .escape:
            return "\u{1b}"
        default:
            let key = String(binding.key.character)
            return key.count == 1 ? key.lowercased() : binding.keyDisplay
        }
    }

    static func configKey(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_Space:
            return " "
        case kVK_Escape:
            return "\u{1b}"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let character = characters.first
            else {
                return nil
            }
            return String(character).lowercased()
        }
    }

    private static func spokenName(for display: String) -> String? {
        switch display {
        case "/": "Slash"
        case "?": "Question Mark"
        case "\\": "Backslash"
        case "'": "Apostrophe"
        case "[": "Left Bracket"
        case "]": "Right Bracket"
        case "=": "Equals"
        case "-": "Minus"
        case ";": "Semicolon"
        case ",": "Comma"
        case ".": "Period"
        case "`": "Grave Accent"
        default: nil
        }
    }
}

enum ShortcutEventMatcher {
    static func normalizedModifierFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
    }

    static func matches(key: KeyEquivalent, event: NSEvent) -> Bool {
        switch key {
        case .upArrow:
            return event.keyCode == UInt16(kVK_UpArrow)
        case .downArrow:
            return event.keyCode == UInt16(kVK_DownArrow)
        case .leftArrow:
            return event.keyCode == UInt16(kVK_LeftArrow)
        case .rightArrow:
            return event.keyCode == UInt16(kVK_RightArrow)
        case .space:
            return event.keyCode == UInt16(kVK_Space)
        case .escape:
            return event.keyCode == UInt16(kVK_Escape)
        default:
            if key.character == "?" {
                return event.characters == "?"
                    || event.charactersIgnoringModifiers == "?"
            }
            guard let characters = event.charactersIgnoringModifiers else {
                return false
            }
            let expected = String(key.character)
            return characters.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    static func modifiersMatch(
        expected: NSEvent.ModifierFlags,
        event: NSEvent
    ) -> Bool {
        let actual = normalizedModifierFlags(for: event)
        return actual == expected
    }
}

extension ShortcutEventModifiers {
    var shortcutModifiers: [ShortcutModifier] {
        [
            contains(.control) ? .control : nil,
            contains(.option) ? .option : nil,
            contains(.shift) ? .shift : nil,
            contains(.command) ? .command : nil
        ].compactMap { $0 }
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    init(_ modifiers: [ShortcutModifier]) {
        self = []
        for modifier in modifiers {
            switch modifier {
            case .control: insert(.control)
            case .option: insert(.option)
            case .shift: insert(.shift)
            case .command: insert(.command)
            }
        }
    }
}

private enum ModifierDisplay {
    case control
    case option
    case shift
    case command

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    var spokenName: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        }
    }
}
