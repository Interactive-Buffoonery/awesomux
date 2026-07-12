import AppKit

/// Pure decision logic for the IME/composition branches of `keyDown`, split
/// out from `GhosttyKeyEquivalentPolicy` (a distinct concern: that one
/// governs `performKeyEquivalent`/`doCommand`, this one governs how
/// `interpretKeyEvents` output gets encoded once composition is involved).
/// Extracted for the same reason: `NSEvent.ModifierFlags`/`UInt16`/`String`
/// are plain value types, so the decisions are testable without a live
/// `NSEvent`/AppKit runtime.
enum GhosttySurfaceIMEPolicy {
    /// True when the active keyboard layout changed while `interpretKeyEvents`
    /// was running and we were NOT already composing. Some IMEs swap layouts
    /// mid-keystroke (e.g. temporarily switching to Latin), so a layout
    /// change with no prior marked text means an IME almost certainly
    /// consumed this key — the caller should bail out rather than
    /// double-processing it. Mirrors Ghostty's `SurfaceView_AppKit.keyDown`
    /// (`SurfaceView_AppKit.swift:1153-1156`).
    ///
    /// If we were already composing (`markedTextBefore == true`), a layout
    /// change is expected IME behavior, not a signal to bail.
    static func layoutChangedDuringComposition(
        markedTextBefore: Bool,
        keyboardIdBefore: String?,
        keyboardIdAfter: String?
    ) -> Bool {
        !markedTextBefore && keyboardIdBefore != keyboardIdAfter
    }

    /// True when `key` should be replayed as a real key event after an IME
    /// commits preedit text mid-keystroke. Ported verbatim from Ghostty's
    /// `shouldReplayCommittedPreeditKey` (`SurfaceView_AppKit.swift:1472-1484`):
    /// up/right/down arrows always replay; left-arrow only replays when
    /// modified (plain left-arrow is skipped because AppKit already leaves
    /// the caret in place after Korean IMEs commit preedit text). Everything
    /// else is dropped — it was fully consumed by the composition.
    static func shouldReplayCommittedPreeditKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        switch keyCode {
        case 0x7D, 0x7C, 0x7E: // kVK_DownArrow, kVK_RightArrow, kVK_UpArrow
            true
        case 0x7B: // kVK_LeftArrow
            !modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            false
        }
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal. Ported verbatim from
    /// Ghostty's `shouldSuppressComposingControlInput`
    /// (`SurfaceView_AppKit.swift:2089-2099`).
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}
