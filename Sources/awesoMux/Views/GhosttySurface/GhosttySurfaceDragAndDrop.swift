import AppKit

/// The pasteboard fields Ghostty's drag-and-drop handling reads, decoupled
/// from `NSPasteboard`/`NSDraggingInfo` so the drop-content priority logic in
/// `GhosttyDragDropContent` is unit-testable without a live pasteboard
/// server.
struct GhosttyDragPayload: Equatable {
    /// `pasteboard.string(forType: .URL)` — an explicit "this is a URL"
    /// pasteboard entry (e.g. dragging a link out of Safari's address bar).
    var explicitURLString: String?
    /// `.path` of every `NSURL` the pasteboard yields via
    /// `readObjects(forClasses: [NSURL.self])`. Named after Ghostty's own
    /// "file URLs next" comment, but — matching the reference exactly —
    /// not filtered to `isFileURL`, since Ghostty escapes `.path` on
    /// whatever URL objects come back here regardless of scheme.
    var fileURLPaths: [String]
    /// `pasteboard.string(forType: .string)`.
    var plainString: String?
}

/// Chooses what to insert into the terminal for a drag-and-drop payload, and
/// how to escape it. Mirrors the priority order in `performDragOperation`
/// (`vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:2234-2267`):
/// explicit URL string > file/URL objects (space-joined) > plain string >
/// nothing to insert. Explicit URLs and file URLs are shell-escaped as
/// single tokens; plain strings are inserted verbatim because the user may
/// be dragging a command they want to execute as-is.
enum GhosttyDragDropContent {
    static func text(from payload: GhosttyDragPayload) -> String? {
        if let explicitURLString = payload.explicitURLString {
            return TerminalInsertionEscaping.escape(explicitURLString)
        }

        if !payload.fileURLPaths.isEmpty {
            return payload.fileURLPaths
                .map(TerminalInsertionEscaping.escape)
                .joined(separator: " ")
        }

        if let plainString = payload.plainString {
            return plainString
        }

        return nil
    }
}

/// `NSDraggingDestination` conformance for dragging a file, URL, or plain
/// text from Finder/Safari/etc onto a terminal surface. awesoMux previously
/// had zero drag-and-drop support here — only `Cmd+V` paste worked.
///
/// Mirrors Ghostty's `SurfaceView_AppKit.swift:2211-2268`. Deliberately does
/// NOT reuse `GhosttyClipboardBridge`'s `TerminalPasteboardString` for the
/// selection logic itself: that type's priority order (file URLs > text >
/// image > generic URLs) and its image-materialization branch are shaped for
/// `Cmd+V` paste, not Ghostty's drag priority (explicit URL type first, no
/// image handling at all — `NSDraggingInfo` for a Finder drag never carries
/// image bytes the way a screenshot copy does). Both paths do share the
/// actual escaping rule via `TerminalInsertionEscaping`.
extension GhosttySurfaceNSView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // AppKit should only offer us types we registered for, but check
        // anyway rather than trust that guarantee blindly.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // .copy gets the proper "+" cursor icon during the drag.
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // The actual insert happens async below; if the surface is already
        // gone (e.g. the pane closed in the same gesture as the drop), that
        // insert will no-op. Don't tell AppKit the drop succeeded (and play
        // its drop-accepted animation) when there's nothing left to receive it.
        guard surface != nil else {
            return false
        }

        let pasteboard = sender.draggingPasteboard
        let fileURLPaths = ((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? [])
            .map(\.path)
        let payload = GhosttyDragPayload(
            explicitURLString: pasteboard.string(forType: .URL),
            fileURLPaths: fileURLPaths,
            plainString: pasteboard.string(forType: .string)
        )

        guard let content = GhosttyDragDropContent.text(from: payload) else {
            return false
        }

        // Matches Ghostty's dispatch: performDragOperation runs during
        // AppKit's drag-session event handling, and insertText's downstream
        // ghostty_surface_text call expects to run on a normal main-queue
        // turn rather than nested inside that session.
        DispatchQueue.main.async { [weak self] in
            self?.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
    }
}
