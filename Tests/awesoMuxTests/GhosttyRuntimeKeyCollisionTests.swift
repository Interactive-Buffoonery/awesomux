import AppKit
import AwesoMuxConfig
import Carbon.HIToolbox
import GhosttyKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Menu/binding collision detection")
struct GhosttyRuntimeKeyCollisionTests {
    @Test("no collisions reported when nothing configured collides")
    func noCollisionsByDefault() {
        // Default libghostty config has no bindings that collide with
        // awesoMux's ⌘-prefixed menu shortcuts (verified: they're disjoint
        // by construction per INT-589's own description).
        let collisions = GhosttyRuntime.detectMenuBindingCollisions(
            catalogBindings: KeyboardShortcutCatalog.allBindings()
        ) { _ in false } // stub: nothing is a binding
        #expect(collisions.isEmpty)
    }

    @Test("reports the action name and chord when a catalog entry collides")
    func reportsCollidingActionNameAndChord() throws {
        let bindings = KeyboardShortcutCatalog.allBindings()
        let target = try #require(bindings.first)
        let collisions = GhosttyRuntime.detectMenuBindingCollisions(
            catalogBindings: bindings
        ) { binding in binding.id == target.id }
        #expect(collisions == ["\(target.action) (\(target.displaySymbol))"])
    }

    @MainActor
    @Test("physical-key Ghostty config bindings match catalog events with keycodes")
    func physicalKeyConfigBindingMatchesCatalogEventWithKeycode() throws {
        try #require(GhosttyRuntime.initializeProcess())

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }

        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask,
            confirmClipboardRead: true,
            copyOnSelect: .inherit,
            terminalAppearance: .defaultValue
        )
        try #require(manager.loadConfigContents(
            "keybind = super+shift+BracketLeft=new_tab\n",
            into: config,
            filePrefix: "test-physical-keybind",
            failureMode: .failRuntime
        ))
        ghostty_config_finalize(config)

        let binding = KeyboardShortcutCatalog.previousWorkspace
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = GhosttyInputMapper.modifiers([.command, .shift])
        keyEvent.keycode = UInt32(kVK_ANSI_LeftBracket)
        keyEvent.unshifted_codepoint = UInt32(binding.key.character.unicodeScalars.first?.value ?? 0)

        let text = String(binding.key.character)
        let matchesWithKeycode = text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_config_key_is_binding(config, keyEvent)
        }

        #expect(matchesWithKeycode)
    }

    @Test("physical keycode table maps every catalog character to its US-ANSI virtual keycode")
    func catalogPhysicalKeyCodeTableEntries() {
        // Raw virtual-keycode values from Carbon's Events.h, written as hex
        // literals (not kVK_* constants) so a wrong constant in the
        // production table can't self-verify.
        let expected: [Character: UInt32] = [
            "[": 0x21, "]": 0x1E, "=": 0x18, "-": 0x1B, "'": 0x27, "\\": 0x2A,
            KeyEquivalent.upArrow.character: 0x7E,
            KeyEquivalent.downArrow.character: 0x7D,
            KeyEquivalent.leftArrow.character: 0x7B,
            KeyEquivalent.rightArrow.character: 0x7C,
        ]
        #expect(GhosttyRuntime.catalogPhysicalKeyCodes == expected)
    }

    @Test("does not log when there are no collisions")
    func noLogWhenEmpty() {
        #expect(GhosttyRuntime.shouldLogCollisions([], lastLogged: []) == false)
    }

    @Test("logs the first time a collision set appears")
    func logsFirstAppearance() {
        #expect(GhosttyRuntime.shouldLogCollisions(["Split Right"], lastLogged: []) == true)
    }

    @Test("does not re-log an unchanged collision set")
    func noRelogWhenUnchanged() {
        #expect(GhosttyRuntime.shouldLogCollisions(["Split Right"], lastLogged: ["Split Right"]) == false)
    }

    @Test("logs again when the collision set changes")
    func logsWhenSetChanges() {
        #expect(GhosttyRuntime.shouldLogCollisions(["Split Right", "Split Down"], lastLogged: ["Split Right"]) == true)
    }

    @Test("logs again when collisions clear and then reappear")
    func logsAfterClearAndReappear() {
        // A single fire-once Bool guard (like `didLogConfigEnvironment`)
        // would permanently latch after the first hit. `lastLogged` must be
        // updated on every computation — even empty ones — so a set that
        // clears and later reappears is treated as new, not "already seen."
        var lastLogged: Set<String> = []

        let collisions: [Set<String>] = [["Split Right"], ["Split Right"], [], ["Split Right"]]
        let didLog = collisions.map { current -> Bool in
            let shouldLog = GhosttyRuntime.shouldLogCollisions(current, lastLogged: lastLogged)
            lastLogged = current
            return shouldLog
        }

        #expect(didLog == [true, false, false, true])
    }

    @Test("claims known Ghostty application actions without routing them")
    func claimsKnownGhosttyApplicationActions() {
        let ignoredAppActions: [ghostty_action_tag_e] = [
            GHOSTTY_ACTION_QUIT,
            GHOSTTY_ACTION_NEW_WINDOW,
            GHOSTTY_ACTION_NEW_TAB,
            GHOSTTY_ACTION_CLOSE_TAB,
            GHOSTTY_ACTION_NEW_SPLIT,
            GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
            GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
            GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
            GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
            GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
            GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
            GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
            GHOSTTY_ACTION_TOGGLE_VISIBILITY,
            GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
            GHOSTTY_ACTION_MOVE_TAB,
            GHOSTTY_ACTION_GOTO_TAB,
            GHOSTTY_ACTION_GOTO_SPLIT,
            GHOSTTY_ACTION_GOTO_WINDOW,
            GHOSTTY_ACTION_RESIZE_SPLIT,
            GHOSTTY_ACTION_EQUALIZE_SPLITS,
            GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
            GHOSTTY_ACTION_PRESENT_TERMINAL,
            GHOSTTY_ACTION_RESET_WINDOW_SIZE,
            GHOSTTY_ACTION_INITIAL_SIZE,
            GHOSTTY_ACTION_INSPECTOR,
            GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
            GHOSTTY_ACTION_RENDER_INSPECTOR,
            GHOSTTY_ACTION_OPEN_CONFIG,
            GHOSTTY_ACTION_RELOAD_CONFIG,
            GHOSTTY_ACTION_CONFIG_CHANGE,
            GHOSTTY_ACTION_CLOSE_WINDOW,
            GHOSTTY_ACTION_FLOAT_WINDOW,
            GHOSTTY_ACTION_UNDO,
            GHOSTTY_ACTION_REDO,
            GHOSTTY_ACTION_CHECK_FOR_UPDATES,
            GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
            GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD,
        ]

        for action in ignoredAppActions {
            #expect(GhosttyRuntime.shouldClaimIgnoredGhosttyApplicationAction(action))
        }
    }

    @Test("does not claim terminal-surface actions handled elsewhere")
    func doesNotClaimTerminalSurfaceActions() {
        let surfaceActions: [ghostty_action_tag_e] = [
            GHOSTTY_ACTION_SET_TITLE,
            GHOSTTY_ACTION_PWD,
            GHOSTTY_ACTION_OPEN_URL,
            GHOSTTY_ACTION_COMMAND_FINISHED,
            GHOSTTY_ACTION_START_SEARCH,
            GHOSTTY_ACTION_SEARCH_TOTAL,
            GHOSTTY_ACTION_SHOW_CHILD_EXITED,
            GHOSTTY_ACTION_SECURE_INPUT,
            GHOSTTY_ACTION_KEY_SEQUENCE,
            GHOSTTY_ACTION_KEY_TABLE,
            GHOSTTY_ACTION_READONLY,
        ]

        for action in surfaceActions {
            #expect(!GhosttyRuntime.shouldClaimIgnoredGhosttyApplicationAction(action))
        }
    }

    @Test("decodes every secure input callback mode")
    func decodesSecureInputModes() {
        #expect(GhosttyRuntime.secureInputMode(GHOSTTY_SECURE_INPUT_ON) == .on)
        #expect(GhosttyRuntime.secureInputMode(GHOSTTY_SECURE_INPUT_OFF) == .off)
        #expect(GhosttyRuntime.secureInputMode(GHOSTTY_SECURE_INPUT_TOGGLE) == .toggle)
    }
}
