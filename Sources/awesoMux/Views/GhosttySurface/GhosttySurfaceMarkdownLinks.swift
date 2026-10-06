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

        guard
            GhosttyMarkdownClickProbe.isCurrent(
                press: mousePosition(for: event), reported: inputState.reportedMousePosition,
                surface: surfaceIdentity, reportedSurface: inputState.reportedMouseSurfaceIdentity)
        else { return nil }

        let nativeLink = nativeMouseLink.withLock { $0 }
        guard !nativeLink.isUpdatingPosition else { return nil }
        if let value = nativeLink.value, RemoteMarkdownReference.isPotentialPayload(value) {
            return GhosttySurfaceMarkdownClick(value: value, origin: origin, surfaceIdentity: surfaceIdentity)
        }
        guard !nativeLink.isLink else { return nil }

        // Read current terminal text; asynchronous hover callbacks can still
        // describe a different filename even when the pointer is current.
        var word = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &word) else { return nil }
        defer { ghostty_surface_free_text(surface, &word) }
        guard word.text_len > 0, word.text_len <= 2048, let pointer = word.text else { return nil }
        let selectedWord = String(
            decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(word.text_len)),
            as: UTF8.self)
        let size = ghostty_surface_size(surface)
        guard
            let value = GhosttyMarkdownClickProbe.filename(
                selectedWord, start: UInt64(word.offset_start), length: UInt64(word.offset_len),
                columns: UInt64(size.columns), rows: UInt64(size.rows), visible: word.tl_px_x >= 0 && word.tl_px_y >= 0,
                hasNativeLink: nativeLink.isLink,
                readCell: { self.markdownCell(at: $0, columns: UInt64(size.columns), surface: surface) })
        else { return nil }
        return GhosttySurfaceMarkdownClick(value: value, origin: origin, surfaceIdentity: surfaceIdentity)
    }

    private func markdownCell(at cell: UInt64, columns: UInt64, surface: ghostty_surface_t) -> String? {
        var point = ghostty_point_s()
        point.tag = GHOSTTY_POINT_VIEWPORT
        point.coord = GHOSTTY_POINT_COORD_EXACT
        point.x = UInt32(cell % columns)
        point.y = UInt32(cell / columns)
        var selection = ghostty_selection_s()
        selection.top_left = point
        selection.bottom_right = point
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len <= 16, let pointer = text.text else { return nil }
        return String(
            decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)),
            as: UTF8.self)
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
