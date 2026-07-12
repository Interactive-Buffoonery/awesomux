import AppKit
import GhosttyKit
import Testing
@testable import awesoMux

@Suite("GhosttyInputMapper")
struct GhosttyInputMapperTests {
    @Test("maps keyboard modifier flags to Ghostty bitset")
    func mapsKeyboardModifiers() {
        let mods = GhosttyInputMapper.modifiers([.shift, .control, .option, .command])

        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test("translated modifiers replace text-affecting flags")
    func translatedModifiersReplaceTextAffectingFlags() {
        let original: NSEvent.ModifierFlags = [.option, .command]
        let translatedMods = ghostty_input_mods_e(
            GHOSTTY_MODS_ALT.rawValue
                | GHOSTTY_MODS_SHIFT.rawValue
        )

        let translated = GhosttyInputMapper.modifierFlags(
            original: original,
            translatedGhosttyMods: translatedMods
        )

        #expect(translated.contains(.option))
        #expect(translated.contains(.shift))
        #expect(!translated.contains(.command))
        #expect(!translated.contains(.control))
    }

    @Test("translated modifiers preserve hidden AppKit bits")
    func translatedModifiersPreserveHiddenAppKitBits() {
        let hiddenRightShift = NSEvent.ModifierFlags(
            rawValue: UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let original: NSEvent.ModifierFlags = [.shift, hiddenRightShift]

        let translated = GhosttyInputMapper.modifierFlags(
            original: original,
            translatedGhosttyMods: GHOSTTY_MODS_NONE
        )

        #expect(!translated.contains(.shift))
        #expect(translated.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0)
    }

    @Test("maps right-side keyboard modifier flags")
    func mapsRightSideKeyboardModifiers() {
        let rawValue = UInt(NX_DEVICERSHIFTKEYMASK)
            | UInt(NX_DEVICERCTLKEYMASK)
            | UInt(NX_DEVICERALTKEYMASK)
            | UInt(NX_DEVICERCMDKEYMASK)
        let flags = NSEvent.ModifierFlags(rawValue: rawValue)
        let mods = GhosttyInputMapper.modifiers(flags)

        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL_RIGHT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER_RIGHT.rawValue != 0)
    }

    @Test("non-modifier keycodes are ignored")
    func flagsChangedActionIgnoresNonModifierKeys() {
        #expect(GhosttyInputMapper.flagsChangedAction(keyCode: 0x00, modifierFlags: [.shift]) == nil)
    }

    @Test("left shift down is a press")
    func flagsChangedActionLeftShiftPress() {
        let action = GhosttyInputMapper.flagsChangedAction(keyCode: 0x38, modifierFlags: [.shift])
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("left shift up (no shift flags at all) is a release")
    func flagsChangedActionLeftShiftRelease() {
        let action = GhosttyInputMapper.flagsChangedAction(keyCode: 0x38, modifierFlags: [])
        #expect(action == GHOSTTY_ACTION_RELEASE)
    }

    @Test("right shift down (device mask set) is a press")
    func flagsChangedActionRightShiftPress() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let action = GhosttyInputMapper.flagsChangedAction(keyCode: 0x3C, modifierFlags: flags)
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("right shift released while left shift still held is a release")
    func flagsChangedActionRightShiftReleaseWhileLeftHeld() {
        // Generic .shift flag stays set (left shift still down), but the
        // device-specific right-shift mask bit is gone — the right-shift
        // keyCode event should still resolve to RELEASE for that side.
        let flags: NSEvent.ModifierFlags = [.shift]
        let action = GhosttyInputMapper.flagsChangedAction(keyCode: 0x3C, modifierFlags: flags)
        #expect(action == GHOSTTY_ACTION_RELEASE)
    }

    @Test("caps lock down is a press")
    func flagsChangedActionCapsLockPress() {
        let action = GhosttyInputMapper.flagsChangedAction(keyCode: 0x39, modifierFlags: [.capsLock])
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("maps extra mouse buttons using Ghostty order")
    func mapsMouseButtons() {
        #expect(GhosttyInputMapper.mouseButton(0) == GHOSTTY_MOUSE_LEFT)
        #expect(GhosttyInputMapper.mouseButton(2) == GHOSTTY_MOUSE_MIDDLE)
        #expect(GhosttyInputMapper.mouseButton(7) == GHOSTTY_MOUSE_FOUR)
        #expect(GhosttyInputMapper.mouseButton(999) == GHOSTTY_MOUSE_UNKNOWN)
    }

    @Test("maps precise scroll and momentum into Ghostty scroll flags")
    func mapsScrollFlags() {
        let mods = GhosttyInputMapper.scrollMods(
            hasPreciseScrollingDeltas: true,
            momentumPhase: .changed
        )

        #expect(mods & 1 == 1)
        #expect(mods >> 1 == GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
    }

    // INT-632: mouseModifiers injects a synthetic Shift bit ONLY when both
    // mouseCaptured and Cmd are present — never on its own, never for other
    // modifiers. It runs on every position report, so the not-captured and
    // no-Cmd cases below are what keep normal shells and plain motion
    // byte-identical to the pre-INT-632 behavior.
    @Test("mouseModifiers injects Shift when Cmd is held and mouse is captured")
    func mouseModifiersInjectsShiftWhenCapturedAndCommandHeld() {
        let mods = GhosttyInputMapper.mouseModifiers([.command], mouseCaptured: true)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test("mouseModifiers does not inject Shift when not captured")
    func mouseModifiersNoInjectionWhenNotCaptured() {
        let mods = GhosttyInputMapper.mouseModifiers([.command], mouseCaptured: false)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test("mouseModifiers does not inject Shift when Cmd is not held")
    func mouseModifiersNoInjectionWithoutCommand() {
        let mods = GhosttyInputMapper.mouseModifiers([.control], mouseCaptured: true)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
    }

    @Test("mouseModifiers is a no-op bitwise-OR when real Shift is already held")
    func mouseModifiersRealShiftAlreadyHeldStaysSet() {
        let mods = GhosttyInputMapper.mouseModifiers([.command, .shift], mouseCaptured: true)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
    }

    @Test("isCommandKeyCode matches left and right Cmd keycodes only")
    func isCommandKeyCodeMatchesOnlyCommandKeys() {
        #expect(GhosttyInputMapper.isCommandKeyCode(0x37))
        #expect(GhosttyInputMapper.isCommandKeyCode(0x36))
        #expect(!GhosttyInputMapper.isCommandKeyCode(0x38))
        #expect(!GhosttyInputMapper.isCommandKeyCode(0x00))
    }
}
