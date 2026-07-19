import AppKit
import CoreText
import GhosttyKit

/// NSAccessibility content + selection surface for VoiceOver, mirroring
/// Ghostty's own `SurfaceView_AppKit.swift:2270-2370`.
///
/// `accessibilityLabel()` and `isAccessibilityElement`/`setAccessibilityElement`
/// are awesoMux's own layering (kept in `GhosttySurfaceNSView.swift` — do not
/// duplicate here); this file fills in the base content/selection accessors
/// VoiceOver needs to actually read and navigate terminal output, which were
/// entirely absent before this file existed.
///
/// Ghostty caches its screen-contents read for 500ms (`CachedValue`,
/// `SurfaceView_AppKit.swift:2372-...`) because several of its accessors
/// (value/numberOfCharacters/visibleCharacterRange/line/string) all pull from
/// the same cached snapshot. `terminalAccessibilityScreenContents()` below
/// mirrors that via `GhosttySurfaceAccessibilityScreenContentsCache`:
/// `ghostty_surface_read_text` for `GHOSTTY_POINT_SCREEN` is a full-scrollback
/// read that locks the same mutex the render thread needs (see that type's
/// doc comment), and VoiceOver routinely fans a single navigation step out
/// across 4+ of these accessors — without a cache, one arrow-key press could
/// trigger 4+ full-scrollback mutex-locked dumps on the main thread.
extension GhosttySurfaceNSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        // The terminal surface is an editable-looking text area: the user
        // reads output and types commands into the same view.
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        terminalAccessibilityScreenContents()
    }

    /// Range of text currently selected in the terminal. Delegates to the
    /// existing `NSTextInputClient.selectedRange()`
    /// (`GhosttySurfaceTextInputClient.swift:17`) rather than re-reading
    /// `ghostty_surface_read_selection` a second time — same underlying call,
    /// one call site.
    ///
    /// KNOWN GAP (investigated, not fixed — needs a libghostty C-API change):
    /// `selectedRange()`'s offsets come from `ghostty_text_s.offset_start`/
    /// `offset_len`, which libghostty computes as a linear cell offset
    /// (`row * viewportCols + col`) within the current VIEWPORT
    /// (`Surface.zig`'s `dumpTextLocked`, via `pointFromPin(.viewport, ...)`)
    /// — always relative to the viewport's top-left, regardless of what
    /// selection *scope* (`GHOSTTY_POINT_VIEWPORT`/`SCREEN`/etc.) was passed
    /// to the read call, and explicitly documented upstream as approximate
    /// ("wrong if there is a partially visible selection"). Meanwhile
    /// `accessibilityValue()` (`terminalAccessibilityScreenContents()` below)
    /// reads the FULL scrollback via `GHOSTTY_POINT_SCREEN` and
    /// `accessibilityString(for:)` indexes into that string with real
    /// UTF-16 character offsets. The two coordinate spaces don't line up —
    /// this range under-indexes into that string by however much scrollback
    /// precedes the viewport, and there's no C API to translate between
    /// them: no exported function returns a viewport-to-screen offset
    /// (`ghostty_point_s` is read-only *input* to `ghostty_surface_read_text`,
    /// never returned), and passing a `GHOSTTY_POINT_SCREEN` selection to
    /// `ghostty_surface_read_text` does not make its `offset_start` relative
    /// to the screen — the offset computation is hardcoded to
    /// `.viewport` regardless of the requested read scope. Needs new
    /// libghostty surface: either a screen-relative offset variant of
    /// `Text.Viewport`, or a standalone point-conversion function.
    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let surface else {
            return nil
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected = String(cString: text.text)
        return selected.isEmpty ? nil : selected
    }

    // NSAccessibility's character counts/ranges are UTF-16 code-unit based
    // (confirmed by `accessibilityString(for:)` below, which relies on
    // `Range(_:in:)`'s UTF-16 semantics) — `String.count` is grapheme-cluster
    // based and undercounts as soon as content has an emoji or other
    // multi-UTF-16-unit character, which routinely shows up in real terminal
    // output (CLI status emoji, git output, etc.).
    override func accessibilityNumberOfCharacters() -> Int {
        terminalAccessibilityScreenContents().utf16.count
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: terminalAccessibilityScreenContents().utf16.count)
    }

    override func accessibilityLine(for index: Int) -> Int {
        GhosttySurfaceAccessibilityPolicy.lineIndex(
            forCharacterIndex: index,
            in: terminalAccessibilityScreenContents()
        )
    }

    override func accessibilityString(for range: NSRange) -> String? {
        GhosttySurfaceAccessibilityPolicy.substring(
            for: range,
            in: terminalAccessibilityScreenContents()
        )
    }

    /// Styling here is font-only, matching Ghostty's own note at
    /// `SurfaceView_AppKit.swift:2349-2351`: libghostty doesn't expose
    /// per-cell style (bold/color/etc.) to the embedder yet, so that's the
    /// ceiling until core grows that API.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface,
              let plainString = accessibilityString(for: range) else {
            return nil
        }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // ghostty_surface_quicklook_font hands back a retained CTFont copy;
        // Swift auto-retains the unretained value stashed in the attributes
        // dict, so release the original here rather than leaking it. Mirrors
        // Ghostty's identical comment/pattern at `SurfaceView_AppKit.swift:2361-2365`.
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            // Balances the +1 the C call above handed back — not redundant,
            // don't delete: `takeUnretainedValue()` didn't consume that
            // reference, it only added Swift's own ARC retain on top of it.
            font.release()
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }

    /// Debounced VoiceOver `.selectedTextChanged` announcement, driven by
    /// libghostty's `GHOSTTY_ACTION_SELECTION_CHANGED` (wired in
    /// `GhosttyRuntime.action`). Mirrors Ghostty's own 100ms debounce
    /// (`SurfaceView_AppKit.swift:292-300`) so a drag selection settles
    /// before VoiceOver announces once, instead of once per intermediate
    /// selection tick.
    @MainActor
    func scheduleAccessibilitySelectionChangeAnnouncement() {
        // Matches every other accessor in this file: don't do surface work
        // (or schedule a work item that outlives it) once the surface is
        // gone. The 100ms dispatch below hops through `Task { @MainActor
        // in ... }` at the call site, so real time passes and teardown
        // (`disposeNativeSurface()`) can beat a stray call here.
        guard surface != nil else {
            return
        }

        // Invalidate immediately (not after the debounce settles) so any
        // accessor calls that land before the debounced post still see fresh
        // content — this is the one push signal awesoMux has for "something
        // about this surface changed" today. See
        // `GhosttySurfaceAccessibilityScreenContentsCache.invalidate()`.
        terminalAccessibilityScreenContentsCache.invalidate()

        accessibilitySelectionChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accessibilitySelectionChangeWorkItem = nil
                NSAccessibility.post(element: self, notification: .selectedTextChanged)
            }
        }
        accessibilitySelectionChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }

    /// Debounced VoiceOver `.valueChanged` announcement, driven by the
    /// passive visible-state sampler (`sampleAgentStateFromVisibleText()`,
    /// `GhosttySurfaceTerminalEvents.swift`) noticing that the visible
    /// terminal content changed since the last sample. This is the only
    /// signal awesoMux has for "new PTY output arrived" — a command
    /// finishing, an agent streaming a response — without it a VoiceOver
    /// user has no proactive cue to re-navigate to the terminal.
    ///
    /// Caller-side scoping: `sampleAgentStateFromVisibleText()` only calls
    /// this for the FOCUSED pane (see its `terminalIsFocused` guard) — a
    /// background pane streaming output must not interrupt VoiceOver
    /// reading a different, focused pane.
    ///
    /// Uses the cancel-then-reschedule `DispatchWorkItem` pattern from
    /// `scheduleAccessibilitySelectionChangeAnnouncement()` above, but with
    /// `accessibilityValueChangeDebounceWindow` (900ms) instead of that
    /// method's 100ms: PTY output can stream continuously for as long as a
    /// command runs, and 100ms is shorter than the gap between sampler
    /// ticks, so it wouldn't debounce a sustained stream at all — every
    /// tick would fire its own notification instead of collapsing into one.
    /// See `accessibilityValueChangeDebounceWindow`'s doc comment for the
    /// derivation.
    @MainActor
    func scheduleAccessibilityValueChangeAnnouncement() {
        // Matches scheduleAccessibilitySelectionChangeAnnouncement(): don't
        // do surface work, or schedule a work item that outlives it, once
        // the surface is gone.
        guard surface != nil else {
            return
        }

        // Invalidate immediately so any accessor calls that land before the
        // debounced post still see fresh content — same reasoning as the
        // selection-change path above.
        terminalAccessibilityScreenContentsCache.invalidate()

        terminalEventState.accessibilityValueChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.terminalEventState.accessibilityValueChangeWorkItem = nil
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
        terminalEventState.accessibilityValueChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.accessibilityValueChangeDebounceWindow,
            execute: workItem
        )
    }

    /// Cached full-screen text read, scoped to `GHOSTTY_POINT_SCREEN`
    /// top-left to bottom-right — the same selection descriptor Ghostty's
    /// `cachedScreenContents` fetch closure uses
    /// (`SurfaceView_AppKit.swift:244-263`). All six accessors that need
    /// screen content (`accessibilityValue`, `accessibilityNumberOfCharacters`,
    /// `accessibilityVisibleCharacterRange`, `accessibilityLine(for:)`,
    /// `accessibilityString(for:)`, and `accessibilityAttributedString(for:)`
    /// via `accessibilityString(for:)`) route through this single call site,
    /// so a burst of accessor calls within one VoiceOver navigation step
    /// shares one `ghostty_surface_read_text` read instead of issuing one
    /// each. See `GhosttySurfaceAccessibilityScreenContentsCache`.
    private func terminalAccessibilityScreenContents() -> String {
        terminalAccessibilityScreenContentsCache.get {
            guard let surface else {
                return ""
            }

            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0,
                    y: 0
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0,
                    y: 0
                ),
                rectangle: false
            )
            guard ghostty_surface_read_text(surface, selection, &text) else {
                return ""
            }
            defer { ghostty_surface_free_text(surface, &text) }

            return String(cString: text.text)
        }
    }
}
