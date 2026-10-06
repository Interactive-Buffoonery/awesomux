import AppKit
import GhosttyKit

struct GhosttySurfaceMarkdownClick {
    let value: String
    let origin: RemoteMarkdownReadOrigin
    let surfaceIdentity: UInt64
}

extension GhosttySurfaceNSView {
    func markdownClick(at event: NSEvent) -> GhosttySurfaceMarkdownClick? {
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
            let surface, let surfaceIdentity = currentMouseSurfaceIdentity,
            let origin = RemoteMarkdownReadRouting.origin(sessionID: sessionID, paneID: paneID, store: sessionStore),
            origin.remoteFileContext != nil,
            event.modifierFlags.intersection([.control, .option, .shift]).isEmpty
        else { return nil }

        // Preserve explicit hyperlinks and native path matches before probing
        // bare filenames. Native command-click otherwise resolves relative paths
        // against the local shell before our remote routing sees them.
        if let value = inputState.mouseOverLink {
            guard RemoteMarkdownReference.isPotentialPayload(value) else { return nil }
            return GhosttySurfaceMarkdownClick(value: value, origin: origin, surfaceIdentity: surfaceIdentity)
        }

        var word = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &word) else { return nil }
        defer { ghostty_surface_free_text(surface, &word) }
        guard word.text_len > 0, word.text_len <= 2048, let pointer = word.text else { return nil }
        let selectedWord = String(
            decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(word.text_len)),
            as: UTF8.self)
        let value = MarkdownLinkIntercept.strippingTrailingSentencePunctuation(selectedWord)
        guard Self.isStandaloneMarkdownWord(value),
            hasStandaloneMarkdownBoundaries(word, surface: surface)
        else { return nil }
        return GhosttySurfaceMarkdownClick(value: value, origin: origin, surfaceIdentity: surfaceIdentity)
    }

    private static func isStandaloneMarkdownWord(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                    || "._-/~".unicodeScalars.contains($0)
            }),
            !MarkdownLinkIntercept.containsUnsafePathScalars(value),
            RemoteMarkdownReference.isPotentialPayload(value),
            let path = RemoteMarkdownReference.remotePath(from: value)
        else { return false }
        return path == value
    }

    private func hasStandaloneMarkdownBoundaries(_ word: ghostty_text_s, surface: ghostty_surface_t) -> Bool {
        let size = ghostty_surface_size(surface)
        let columns = UInt64(size.columns)
        let cells = columns * UInt64(size.rows)
        let start = UInt64(word.offset_start)
        let end = start + UInt64(word.offset_len)
        guard columns > 0, cells > 0, start < cells, end < cells,
            word.tl_px_x >= 0, word.tl_px_y >= 0
        else { return false }

        // These native offsets count grid cells, not bytes or Swift characters.
        // Neighbor reads retain Ghostty's wide-cell, combining and wrap handling.
        // A selection cut by the viewport has unreliable offsets; require both
        // delimiters to be visible rather than opening a possible partial name.
        guard start > 0, end + 1 < cells else { return false }
        return isMarkdownDelimiter(at: start - 1, columns: columns, surface: surface)
            && isMarkdownDelimiter(at: end + 1, columns: columns, surface: surface)
    }

    private func isMarkdownDelimiter(at cell: UInt64, columns: UInt64, surface: ghostty_surface_t) -> Bool {
        var point = ghostty_point_s()
        point.tag = GHOSTTY_POINT_VIEWPORT
        point.coord = GHOSTTY_POINT_COORD_EXACT
        point.x = UInt32(cell % columns)
        point.y = UInt32(cell / columns)
        var selection = ghostty_selection_s()
        selection.top_left = point
        selection.bottom_right = point
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len <= 16, let pointer = text.text else { return false }
        let value = String(
            decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)),
            as: UTF8.self)
        return value.isEmpty
            || value.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || "'\"`;,()[]{}<>|".unicodeScalars.contains($0)
            }
    }

    func deferMarkdownClick(_ click: GhosttySurfaceMarkdownClick) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inputState.pendingLinkOpenWorkItem = nil
            Task { @MainActor [weak self] in
                guard let self, self.window != nil,
                    self.currentMouseSurfaceIdentity == click.surfaceIdentity,
                    RemoteMarkdownReadRouting.current(click.origin, store: self.sessionStore) == click.origin
                else { return }
                await GhosttyRuntime.openURLAction(OpenURLAction(click.value), from: self, capturedOrigin: click.origin)
            }
        }
        inputState.pendingLinkOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
