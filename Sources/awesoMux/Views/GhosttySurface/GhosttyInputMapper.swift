import AppKit
import GhosttyKit

enum GhosttyInputMapper {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
        }

        return ghostty_input_mods_e(mods)
    }

    /// INT-632: libghostty only wires Shift (not Cmd/Ctrl — the same modifier
    /// already used as its own link-activation modifier, `hover_mods =
    /// ctrlOrSuper` in its default link matcher) to bypass a running
    /// program's mouse-reporting grab. Inject a synthetic Shift bit so Cmd
    /// gets the same bypass Shift already has, when the surface has mouse
    /// reporting captured and Cmd is held.
    ///
    /// Called CONTINUOUSLY from `sendMousePosition` — load-bearing, not an
    /// oversight. libghostty's `cursorPosCallback` unconditionally clears its
    /// `over_link` hover flag on every motion and only re-sets it when Shift
    /// is in the mods, so any uninjected motion between "press ⌘" and "click"
    /// wipes the state the click-time link gate reads. The earlier one-shot
    /// probe design failed live for exactly this reason.
    ///
    /// Accepted trade-off: while ⌘ is held over a captured pane with no
    /// button pressed, motion reports reach the TUI with a fake Shift bit —
    /// byte-identical to what it already sees when the user physically holds
    /// ⌘⇧ (the previous documented workaround), so no new behavior is exposed
    /// to terminal programs. Never inject into KEY events; that would corrupt
    /// kitty-keyboard-protocol modifier reports.
    /// INT-453: `armLinkHover` injects a synthetic Super bit into hover-motion
    /// mods. libghostty's `linkAtPos` detects an OSC 8 hyperlink only when the
    /// mouse mods equal ctrl-or-super exactly (`Surface.zig` `linkAtPos`), so a
    /// plain hover never emits `MOUSE_OVER_LINK` and the peek dwell could never
    /// arm. Callers gate it to button-free motion on an UNCAPTURED surface:
    /// uncaptured motion is never reported to the terminal program, so the
    /// fake bit reaches only libghostty's own link/shape logic — and click-time
    /// link activation is unaffected because `mouseButtonCallback` re-stores
    /// the click's real mods before its link check. Ceiling: plain-hover peek
    /// stays unavailable while a TUI has mouse capture (injecting there would
    /// corrupt motion reports); ⌘-hover still works via the INT-632 path.
    static func mouseModifiers(
        _ flags: NSEvent.ModifierFlags,
        mouseCaptured: Bool,
        armLinkHover: Bool = false
    ) -> ghostty_input_mods_e {
        let base = modifiers(flags)
        if mouseCaptured, flags.contains(.command) {
            return ghostty_input_mods_e(base.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
        }
        if armLinkHover {
            return ghostty_input_mods_e(base.rawValue | GHOSTTY_MODS_SUPER.rawValue)
        }
        return base
    }

    /// INT-632: identifies a `flagsChanged` event as the Cmd (Super) key
    /// specifically, left or right side — matches the keycodes already used
    /// in `flagsChangedAction`'s own switch.
    static func isCommandKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 0x37 || keyCode == 0x36
    }

    static func modifierFlags(
        original: NSEvent.ModifierFlags,
        translatedGhosttyMods: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var translated = original
        let translatedFlags = eventModifierFlags(mods: translatedGhosttyMods)

        for flag in [
            NSEvent.ModifierFlags.shift,
            .control,
            .option,
            .command,
        ] {
            if translatedFlags.contains(flag) {
                translated.insert(flag)
            } else {
                translated.remove(flag)
            }
        }

        return translated
    }

    private static func eventModifierFlags(
        mods: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Decides the press/release action `flagsChanged` should send for a
    /// modifier-key event, distinguishing left vs. right side via the
    /// `NX_DEVICE*KEYMASK` flags. Returns `nil` when `keyCode` isn't a
    /// modifier key at all (caller should ignore the event).
    ///
    /// Ported from Ghostty's `SurfaceView_AppKit.flagsChanged`
    /// (`SurfaceView_AppKit.swift:1399-1444`). The generic modifier flag
    /// (e.g. `.shift`) stays set in `modifierFlags` as long as EITHER side is
    /// held, so on its own it can't tell a right-shift release (while left
    /// shift is still down) apart from a press. The `NX_DEVICE*KEYMASK` bits
    /// disambiguate for the right-side keycodes; left-side keycodes (and
    /// caps lock, which has no side) fall through to "pressed" whenever the
    /// generic flag is set — this is Ghostty's own behavior, not an awesoMux
    /// addition, so it's ported as-is rather than "fixed."
    static func flagsChangedAction(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ghostty_input_action_e? {
        let changedModifier: UInt32
        switch keyCode {
        case 0x39:
            changedModifier = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C:
            changedModifier = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E:
            changedModifier = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D:
            changedModifier = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36:
            changedModifier = GHOSTTY_MODS_SUPER.rawValue
        default:
            return nil
        }

        let mods = modifiers(modifierFlags)
        guard mods.rawValue & changedModifier != 0 else {
            return GHOSTTY_ACTION_RELEASE
        }

        let rawFlags = modifierFlags.rawValue
        let sidePressed: Bool
        switch keyCode {
        case 0x3C:
            sidePressed = rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3E:
            sidePressed = rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3D:
            sidePressed = rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x36:
            sidePressed = rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            sidePressed = true
        }

        return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0:
            GHOSTTY_MOUSE_LEFT
        case 1:
            GHOSTTY_MOUSE_RIGHT
        case 2:
            GHOSTTY_MOUSE_MIDDLE
        case 3:
            GHOSTTY_MOUSE_EIGHT
        case 4:
            GHOSTTY_MOUSE_NINE
        case 5:
            GHOSTTY_MOUSE_SIX
        case 6:
            GHOSTTY_MOUSE_SEVEN
        case 7:
            GHOSTTY_MOUSE_FOUR
        case 8:
            GHOSTTY_MOUSE_FIVE
        case 9:
            GHOSTTY_MOUSE_TEN
        case 10:
            GHOSTTY_MOUSE_ELEVEN
        default:
            GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func scrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        scrollMods(
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            momentumPhase: event.momentumPhase
        )
    }

    static func scrollMods(
        hasPreciseScrollingDeltas: Bool,
        momentumPhase: NSEvent.Phase
    ) -> ghostty_input_scroll_mods_t {
        var value: Int32 = hasPreciseScrollingDeltas ? 1 : 0
        value |= Int32(momentum(momentumPhase).rawValue) << 1
        return value
    }

    static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began:
            GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary:
            GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:
            GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:
            GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:
            GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:
            GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default:
            GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
