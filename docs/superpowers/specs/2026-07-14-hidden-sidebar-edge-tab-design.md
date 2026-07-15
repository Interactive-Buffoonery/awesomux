# Hidden Sidebar Edge Tab Design

## Goal

Replace the unreliable hidden-sidebar proximity glow with a concrete edge tab that clearly communicates where the sidebar is and that moving toward it will reveal more.

## Interaction

- Persistent hidden mode keeps the existing sidebar-side attraction field covering one third of the content width.
- Entering that field shows a solid highlight-color strip at the configured edge. The strip slides inward about 10pt and carries a vertically centered chevron pointing toward the hidden sidebar.
- The strip does not brighten, widen, pulse, or otherwise vary with pointer distance.
- Crossing the existing 40pt reveal threshold replaces the strip with the existing full sidebar overlay animation. Ghostty remains stationary.
- Leaving the sidebar uses the existing leave grace. If the pointer remains in the attraction field when the overlay closes, the strip returns; otherwise it slides away.
- Right-side mode mirrors the strip, transition, and chevron direction.
- The edge tab is a visual cue only. It is not clickable, focusable, exposed as an accessibility element, or involved in hit testing.

## Attention

When a hidden session needs attention and the pointer is outside the attraction field, a static strip remains visible using the existing needs-attention color. It has no chevron. Entering the attraction field changes it to the ordinary highlight-color strip with the directional chevron.

## Implementation

- Reuse the existing `.dormant`, `.cue`, and `.revealed` proximity state machine, one-third tracking region, 40pt reveal threshold, leave grace, corrected AppKit tracking lifecycle, and transient overlay host.
- Replace `SidebarProximityCue` glow/intensity rendering with one fixed edge-tab component.
- Remove the proximity intensity curve and its state/plumbing once no consumer remains.
- Preserve the independent narrow-window overlay sizing fix: transient overlays cap only to the host extent, while persistent splits continue reserving `terminalMinimumWidth` for Ghostty.
- Use the existing highlight and needs-attention design tokens. Add no setting, dependency, or second sidebar presentation state.
- Respect Reduce Motion by showing and hiding the strip without translation while retaining the same state transitions.

## Verification

- Unit-test cue, attention-only, and revealed rendering policy.
- Test left/right mirroring and chevron direction.
- Assert the tab remains noninteractive and accessibility-hidden.
- Remove or rewrite intensity-specific tests so no dead intensity API remains.
- Retain regression coverage for stale tracking-area exits, clipped tracking geometry, both narrow-window overlay sides, and persistent terminal-width clamping.
- Dogfood entry and exit across the attraction field, overlay replacement, attention state, small windows, both sidebar positions, Reduce Motion, and ordinary terminal cursor behavior.
