import AppKit
import GhosttyKit

extension GhosttySurfaceNSView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else {
            return NSRange()
        }

        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else {
            return NSRange()
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange()
        }
        defer { ghostty_surface_free_text(surface, &text) }

        return NSRange(
            location: Int(text.offset_start),
            length: Int(text.offset_len)
        )
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let attributedString as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributedString)

        case let string as String:
            markedText = NSMutableAttributedString(string: string)

        default:
            markedText = NSMutableAttributedString()
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else {
            return
        }

        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surface, range.length > 0 else {
            return nil
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let surface else {
            return window?.convertToScreen(frame) ?? frame
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection, so
        // detect that case and return the top-left selection point instead
        // of the cursor point. Mirrors Ghostty's `firstRect(forCharacterRange:)`
        // (`SurfaceView_AppKit.swift:1965-2021`) — including the -2/+2 offset,
        // which Ghostty notes is subjective but makes the QuickLook popover
        // look more natural.
        if range.length > 0, range != selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }

        if range.length == 0, width > 0 {
            // Ghostty upstream #8493: a positive width doesn't make sense for
            // the dictation microphone indicator, which passes an empty range.
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }

        let viewRect = NSRect(
            x: x,
            y: bounds.height - y,
            width: width,
            height: max(height, cellSize.height)
        )
        let windowRect = convert(viewRect, to: nil)

        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributedString as NSAttributedString:
            text = attributedString.string

        case let string as String:
            text = string

        default:
            return
        }

        // `keyTextAccumulator` is only non-nil while `keyDown` is actively
        // running `interpretKeyEvents` (see `GhosttySurfaceInputBridge.
        // keyDown`) — that's the ONLY path through which the real system IME
        // resolves its own composition into `text`, and in that path `text`
        // already fully supersedes whatever was marked (Ghostty's own
        // comment: "If insertText is called, our preedit must be over").
        // `keyTextAccumulator == nil` with marked text still present means
        // this call did NOT come from the IME resolving its own composition
        // — e.g. a drag-and-drop drop landing mid-composition
        // (`GhosttySurfaceDragAndDrop.performDragOperation` calls
        // `insertText` directly, outside any keyDown cycle). In that case
        // `text` is unrelated content, and the marked composition would
        // otherwise be silently discarded with zero commit. Commit it first,
        // mirroring the committed-preedit-before-replay handling in
        // `GhosttySurfaceInputBridge.keyDown`.
        let abandonedComposition: String? = keyTextAccumulator == nil && hasMarkedText()
            ? markedText.string
            : nil

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
        } else {
            if let abandonedComposition, !abandonedComposition.isEmpty {
                sendText(abandonedComposition)
            }
            sendText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)):
            performBindingAction("scroll_to_top")

        case #selector(moveToEndOfDocument(_:)):
            performBindingAction("scroll_to_bottom")

        default:
            // `performKeyEquivalent` defers non-binding command/control keys
            // to let AppKit's text-editing responder chain try first (see
            // `GhosttySurfaceKeyEquivalentPolicy.waitForResponderChain`). If
            // that chain lands here with a selector we don't otherwise
            // implement, the key would silently vanish — resend the original
            // event so `performKeyEquivalent` gets one final pass and routes
            // it to the terminal instead. Mirrors Ghostty's `doCommand`
            // (`SurfaceView_AppKit.swift:2053-2064`); Ghostty resets
            // `lastPerformKeyEvent` in the SECOND `performKeyEquivalent` pass
            // (see `GhosttyKeyEquivalentPolicy`'s `.redispatch` case), not
            // here, so we don't touch it in this branch either.
            if let lastPerformKeyEvent,
               let current = NSApp.currentEvent,
               lastPerformKeyEvent == current.timestamp {
                NSApp.sendEvent(current)
            }
        }
    }
}
