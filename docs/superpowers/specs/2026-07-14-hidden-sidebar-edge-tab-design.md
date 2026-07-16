# Hidden Sidebar Edge Tab Design

## Goal

Replace the unreliable hidden-sidebar proximity glow with a concrete edge tab that clearly communicates where the sidebar is and that moving toward it will reveal more.

## Interaction

- Persistent hidden mode keeps the existing sidebar-side attraction field covering one third of the content width.
- The native host keeps a window-local mouse-moved monitor as the AppKit delivery fallback for that field. The monitor is intentionally retained, but it restores the owning window's previous `acceptsMouseMovedEvents` value whenever it is disabled, transferred, detached, or finalized.
- Entering that field shows a solid highlight-color strip at the configured edge. The strip slides inward about 10pt and carries a vertically centered chevron pointing toward the hidden sidebar.
- The strip does not brighten, widen, pulse, or otherwise vary with pointer distance.
- Crossing the existing 40pt reveal threshold replaces the strip with the existing full sidebar overlay animation. Ghostty remains stationary.
- Leaving the sidebar uses the existing leave grace. If the pointer remains in the attraction field when the overlay closes, the strip returns; otherwise it slides away.
- Right-side mode mirrors the strip, transition, and chevron direction.
- Pointer-driven reveal and dismissal use the normal hover animation. An explicit side change reconciles immediately after the native host moves, even if the proximity state itself does not change.
- A side change collapses passive pointer-only presentation and any in-flight hide to stable hidden ownership. If keyboard, menu, or accessibility interaction is active, the overlay instead remains mounted, visible, and focus-safe while it mirrors to the new edge; after that interaction ends, ordinary leave grace controls dismissal.
- The edge tab is a visual cue only. It is not clickable, focusable, exposed as an accessibility element, or involved in hit testing.
- The cue belongs to the terminal content region: it begins below any `NeedsInputBar` or bridge permission banner and stops above the bottom terminal action/path bar. Those actionable chrome surfaces mask the decorative cue structurally rather than by z-index compensation. The full revealed sidebar overlay still spans the split host and covers that chrome normally.
- When no session is selected, the cue may span the full empty-workspace detail because no terminal banner or path bar is present.

## Attention

When a hidden session needs attention and the pointer is outside the attraction field, a static strip remains visible using the existing needs-attention color. It has no chevron. Entering the attraction field changes it to the ordinary highlight-color strip with the directional chevron. Both colors are contrast-tuned against the surface beneath the cue: the live Ghostty terminal background for a selected session, or the app terminal-surface token for the empty detail.

## Titlebar

The sidebar body slides during temporary presentation, but the titlebar brand lockup stays in place and fades. A partially presented or fully hidden lockup is absent from accessibility. On the left, titlebar workgroup reservation is capped to the brand footprint only when the selected presentation width can render that lockup; the 60-point rail reserves its actual visible width so temporary and persistent rail states line up without a snap.

## Implementation

- Reuse the existing `.dormant`, `.cue`, and `.revealed` proximity state machine, one-third tracking region, 40pt reveal threshold, leave grace, corrected AppKit tracking lifecycle, and transient overlay host.
- Replace `SidebarProximityCue` glow/intensity rendering with one fixed edge-tab component.
- Remove the proximity intensity curve and its state/plumbing once no consumer remains.
- Preserve the independent narrow-window overlay sizing fix: transient overlays cap only to the host extent, while persistent splits continue reserving `terminalMinimumWidth` for Ghostty.
- Use the existing highlight and needs-attention design tokens, contrast-tuned against the actual terminal content surface. Add no setting, dependency, or second sidebar presentation state.
- Respect Reduce Motion by showing and hiding the strip without translation while retaining the same state transitions.
- Host the cue on `TerminalPaneView` inside `SessionDetailView` so the top banners and bottom path bar are outside its render region by construction. Remove the temporary footer-height cue inset; preserve the existing footer-height callback because the pop-up terminal still consumes it independently.
- Keep the empty-workspace cue on `EmptyWorkspaceView`. Do not shorten the attraction field or native sidebar overlay host.

## Verification

- Unit-test cue, attention-only, and revealed rendering policy.
- Test left/right mirroring and chevron direction.
- Assert the tab remains noninteractive and accessibility-hidden.
- Assert the session cue is hosted on `TerminalPaneView`, the empty-workspace cue remains available, and no measured top/footer inset drives cue geometry.
- Preserve the existing footer-height callback for its unrelated pop-up-terminal consumer.
- Remove or rewrite intensity-specific tests so no dead intensity API remains.
- Retain regression coverage for stale tracking-area exits, clipped tracking geometry, both narrow-window overlay sides, and persistent terminal-width clamping.
- Retain the local mouse-moved fallback and cover restoration of each owning window's prior `acceptsMouseMovedEvents` value across disable, transfer, detach, and finalization.
- Cover rail-width titlebar reservation parity and keep partially presented titlebar branding out of accessibility.
- Dogfood entry and exit across the attraction field, overlay replacement, attention state, small windows, both sidebar positions, Reduce Motion, and ordinary terminal cursor behavior.
