import AppKit

@MainActor
final class GhosttySurfaceInputState {
    var mouseOverLink: String?
    /// OSC 8 hyperlink peek-preview state (INT-453). See `GhosttySurfaceLinkPeek`.
    /// `peekedLink` is the link the popover is currently presenting (distinct from
    /// `mouseOverLink`, which is only the hovered link — they differ during the
    /// dwell window before a preview appears).
    var linkPeekPopover: NSPopover?
    var linkPeekShowWorkItem: DispatchWorkItem?
    var linkPeekDismissWorkItem: DispatchWorkItem?
    var peekedLink: String?
    /// INT-453: link armed by a PLAIN left press while hovered, opened app-side
    /// on the matching non-dragged release (libghostty's own release-time
    /// activation requires exactly ⌘, so plain clicks must be app-driven).
    /// Snapshotted at press because libghostty can clear `over_link` — and thus
    /// `mouseOverLink` — asynchronously between press and release. ⌘-clicks are
    /// never armed; libghostty handles those, so each click has exactly one
    /// opener.
    ///
    /// ponytail: the snapshot can go stale if terminal output rewrites the cell
    /// under a stationary pointer between hover and click — libghostty re-derives
    /// at release for ⌘-clicks, but exposes no link-at-position query API for the
    /// app to do the same. Every open still routes through the resolve/classify
    /// gates (blocked classes always confirm). Upgrade path: a narrow query API
    /// in the ghostty fork, then re-derive here instead of snapshotting.
    var armedLinkClickValue: String?
    /// Plain-click opens are deferred by `NSEvent.doubleClickInterval` so the
    /// second press of a double-click (word-select inside a hyperlink) cancels
    /// the open instead of racing it — the first press of the pair still has
    /// `clickCount == 1`, so a press-time gate alone can't tell them apart.
    var pendingLinkOpenWorkItem: DispatchWorkItem?
    /// INT-632: computed once at left mouseDown, reused unchanged for the
    /// paired mouseUp. Never recompute at release time — ⌘ can be released
    /// mid-gesture, and a press/release pair that disagreed on the injected
    /// Shift bit would desync libghostty's mouse-report suppression the same
    /// way INT-607 desynced press/release pairing before.
    var leftClickLinkBypassActive = false
    /// The cursor libghostty last requested via `GHOSTTY_ACTION_MOUSE_SHAPE`.
    /// `nil` until the first request arrives, matching Ghostty's own
    /// "ignore unknown shapes" default (see `GhosttyCursorMapper`).
    var terminalCursorShape: NSCursor?
    /// Mirrors Ghostty's `cursorVisible` (`SurfaceView_AppKit.swift:93`). Plain
    /// stored var, not `@Published` — nothing in awesoMux reads this reactively
    /// today; it only feeds `NSCursor.setHiddenUntilMouseMoves`.
    var terminalCursorVisible = true
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var submittedSSHCommandBuffer = ""
    var submittedSSHCommandCaptureDisabled = false
    /// Timestamp of a command/control-modified key deferred by
    /// `performKeyEquivalent` to let AppKit's own responder chain try first.
    /// `doCommand` reads this to know whether to redispatch the event back
    /// through `performKeyEquivalent` instead of silently dropping it — see
    /// `GhosttySurfaceKeyEquivalentPolicy` for the full state machine and
    /// Ghostty's `SurfaceView_AppKit.swift:1246-1276` for why identity has to
    /// be tracked by timestamp rather than by holding the `NSEvent` itself.
    var lastPerformKeyEvent: TimeInterval?

    /// Owns focus-only left-click suppression plus press/release pairing for
    /// all mouse buttons. The AppKit bridge passes a per-surface-incarnation
    /// identity into it so a command-bridge respawn between press and release
    /// cannot send the release to the new surface.
    var mouseButtonPolicy = GhosttySurfaceMouseButtonPolicy<UInt64>()
    /// True after the previous left-button press was intentionally suppressed
    /// because it only transferred pane focus. The next left `mouseDown` consumes
    /// this to decide whether AppKit's `clickCount` proves the physical gesture
    /// is a double-click that needs a synthetic catch-up click for libghostty.
    var hasPendingFocusTransferClick = false
}
