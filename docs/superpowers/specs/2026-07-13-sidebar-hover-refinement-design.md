# Sidebar Hover Refinement

## Summary

Refine the hidden-sidebar pointer interaction from the original [Sidebar Presentation and Markdown Toggle Alignment](2026-07-13-sidebar-presentation-design.md) design. A pass-through 80-point edge tracking region first provides a visible proximity cue, then temporarily reveals the user's selected rail or full sidebar when the pointer reaches the inner 40 points.

Only pointer-driven transitions animate. Explicit keyboard commands remain immediate and deterministic.

## Goals

- Make the hidden sidebar discoverable before revealing an interactive overlay.
- Increase the pointer target without intercepting terminal clicks, selection, or scrolling.
- Preserve the selected rail/full width while the sidebar is persistently hidden.
- Give the pointer-driven overlay a restrained transition consistent with the existing rail-to-full experience.
- Behave symmetrically on the configured left or right edge.
- Cancel obsolete pointer and animation work cleanly when interaction state changes rapidly.

## Non-goals

- Changing the persistent meaning of Hide/Show Sidebar.
- Animating explicit keyboard, menu, palette, focus, launch-restoration, or settings actions.
- Adding an interactive handle or reserving permanent window space for the proximity cue.
- Changing the real split geometry during a proximity cue or hover reveal.
- Changing the existing rail and full sidebar widths.

## Interaction Design

### Proximity states

When the sidebar is persistently hidden, pointer distance from its configured window edge produces three transient states:

1. **Dormant:** farther than 80 points from the edge. No sidebar cue is visible and the detail area retains the full window width.
2. **Cue:** from 80 points down to, but not including, 40 points from the edge. A 4-point accent strip appears flush with that edge without moving the split divider or detail content.
3. **Revealed:** at or inside 40 points from the edge, or within the temporarily revealed sidebar. The cue transitions into the selected rail or full sidebar as a live overlay above the detail pane. Ghostty and the real split geometry do not move or resize.

Distance is measured inward from the physical edge selected by `appearance.sidebar_position`: from the left window edge for a left sidebar and from the right window edge for a right sidebar. Boundary comparisons must be stable: entering at 80 points activates the cue, and reaching 40 points activates the reveal. Small pointer jitter at a boundary must not cause competing transitions; the presentation model owns the single current proximity state.

The existing short leave grace period continues to cover movement between the trigger and the revealed sidebar. Re-entering either region cancels the pending hide. Once the pointer leaves both the tracking region and sidebar, the temporary reveal closes after the grace period and the cue disappears when the pointer is outside 80 points.

### Accent cue

The cue is a 4-point, non-interactive accent strip using the sidebar/focus accent vocabulary already present in the design system. It overlays the configured window edge and never reserves layout width. It must not participate in hit testing, keyboard focus, accessibility traversal, divider dragging, or width persistence.

While the sidebar is persistently hidden and any session needs attention, the same strip remains visible at the configured reveal edge using the existing needs-attention token and a restrained static glow. This attention state does not pulse or loop; Reduce Motion retains the same static signal. Clearing attention removes the persistent glow, after which ordinary proximity visibility applies again.

The strip's opacity may use a brief transition when it appears or disappears. It must be removed immediately when the sidebar becomes persistently visible, the window becomes inactive in a way that invalidates tracking, or the configured side changes.

### Pointer-driven animation

Crossing from cue to revealed slides the sidebar overlay inward from the configured edge over 140 milliseconds with an ease-in-out timing curve. Leaving slides the overlay back out with the same restrained duration and curve. The animation is compositor-driven and does not animate split geometry, resize Ghostty, or cause terminal reflow. It should feel comparable to the existing rail-to-full transition, without spring overshoot or delayed settling.

Only hover reveal and hover hide animate. `Command-Shift-Backslash` persistently hides or shows the sidebar immediately. Focus Sidebar, position changes, restoration, and other explicit commands also settle immediately.

When Reduce Motion is enabled, the overlay appears and disappears immediately. A very short opacity fade for the 4-point cue is permitted because it does not move content, but the cue must remain legible and must not delay the state transition.

### Width selection while hidden

`Command-Backslash` continues to select between the collapsed rail and full sidebar even while the sidebar is persistently hidden. The command changes the remembered width mode without revealing the sidebar, showing the cue, or moving the divider. The next temporary or persistent reveal uses the newly selected mode.

If `Command-Backslash` is used during a temporary hover reveal, it follows the existing rail/full behavior for a visible sidebar while remaining an overlay. It does not alter persistent hidden state or resize Ghostty.

## Architecture

### Pass-through AppKit tracking region

Add an AppKit tracking surface owned by the existing split-view/content orchestration described in the original design. It covers the inner 80 points of the configured window edge while the sidebar is persistently hidden. The surface observes pointer movement and entry/exit but is pass-through for hit testing, so terminal input remains owned by the terminal/detail view beneath it.

The implementation must not install a window-wide event monitor or a SwiftUI hit-testing overlay. Tracking is local to the relevant content/split geometry and updates when the window resizes or the sidebar changes sides. Its coordinate conversion computes edge distance from current bounds rather than cached screen coordinates.

Pointer observation reports distance/state changes to the main-actor sidebar presentation model. It must not recreate terminal hosting views, change first responder, synthesize mouse events, or consume clicks, drags, scroll events, contextual clicks, or terminal text selection within the 80-point zone.

### Presentation state

Extend the existing sidebar presentation model with an explicit transient proximity state (`dormant`, `cue`, or `revealed`) rather than deriving multiple independent booleans in views. Persistent hidden preference and remembered width mode remain separate inputs.

The model decides:

- distance-to-state transitions for either physical side;
- whether the accent cue is visible;
- when an overlay reveal/hide animation is requested;
- leave grace-period scheduling and cancellation;
- clearing transient state after explicit commands, resize invalidation, side changes, or loss of a valid host window.

Delayed hides and animation completions carry a generation/token. Any newer pointer, keyboard, resize, position, or lifecycle event invalidates older work so stale completion handlers cannot dismiss a newly shown overlay, resurrect an old cue, or replace an explicit persistent result.

### Interactive sidebar overlay

While the sidebar is persistently hidden, the existing sidebar UI is hosted as a live interactive overlay above the detail pane. It is anchored to the configured left or right edge and uses the remembered rail or full width. The overlay must provide the same sidebar controls, scrolling, pointer interaction, keyboard focus behavior, contextual menus, and accessibility semantics as the persistent sidebar; it is not a screenshot or decorative duplicate.

Ghostty remains at its full hidden-sidebar size throughout cue and overlay states. The real split divider stays in its hidden position and receives no intermediate width updates. Overlay animation uses a compositor transform from fully offscreen to its resting edge-aligned position; it must not recreate or resize the terminal hosting view.

Each new transition cancels the current overlay animator and begins from its current presentation transform toward the newest requested state. Completion normalizes the presentation to the model's current state rather than trusting the state that originally started the animation. Resizing reclamps overlay width and position without changing Ghostty geometry.

`Command-Shift-Backslash` and other explicit persistent show/hide actions cancel transient work and apply the real split result instantly. Showing persistently removes the overlay and reveals the real split sidebar at the selected rail/full width, causing one intentional Ghostty resize rather than an animated sequence of resizes. Hiding persistently collapses the real split instantly; later proximity reveals use overlay mode. The handoff must never render two sidebars, flash an empty frame, or transfer focus to a view that is being removed.

Focus Sidebar while persistently hidden follows the original design's explicit persistent-show behavior rather than focusing a transient peek. Side changes and restoration cancel any active overlay animator and apply their result without animation. Moving the sidebar between left and right clears the cue, pending hide, tracking state, and overlay before rebuilding the tracking region on the new edge.

## Accessibility and Input Preservation

- The 80-point tracking region and 4-point cue are pointer-only and absent from keyboard and accessibility focus order.
- Menu, palette, cheatsheet, shortcut customization, and Focus Sidebar remain the discoverable non-pointer paths.
- Pointer tracking never changes first responder; typing continues to reach the terminal while the cue appears or the overlay slides in. Directly interacting with the revealed sidebar may move keyboard or accessibility focus into it normally.
- A temporary reveal must not steal VoiceOver focus or announce itself as a persistent preference change. Once directly focused or interacted with, the overlay remains available through the existing leave grace behavior so it is not removed from beneath active input.
- Reduce Motion removes overlay movement as described above.
- Explicit hiding transfers focus out of the sidebar using the existing focus-preservation behavior before the instantaneous collapse.

## Right-Side Title Lockup Alignment

When `appearance.sidebar_position` is `right`, the awesoMux icon-and-title lockup in the sidebar titlebar is aligned to the sidebar's trailing/right edge. It retains the same titlebar padding used by the left-side layout, and the icon remains before the title text; only the lockup's horizontal alignment changes.

While the hidden sidebar is temporarily revealing or hiding, the titlebar lockup samples the overlay compositor's live presentation translation. It does not run a second duration-matched animation or wait for the overlay's settled width publication. Reveal, hide, reversal, left/right placement, and Reduce Motion therefore use one authoritative transform and cannot accumulate clock drift.

The existing left-side titlebar behavior remains unchanged. This alignment follows the configured sidebar position for persistent and temporary presentations, including rail/full selection and hover reveal, without introducing a separate preference or animation.

## Failure and Interruption Behavior

- **Rapid reversal:** cancel the active animator, use its current presentation transform as the new starting point, and settle at the newest pointer state.
- **Stale leave timer:** generation validation makes the completion a no-op after re-entry or any explicit state change.
- **Window resize:** refresh tracking geometry, recalculate edge distance, and reclamp the overlay frame without resizing Ghostty or persisting an intermediate width.
- **Position change:** clear all transient left/right state before installing tracking on the new side; no cue may remain on the old edge.
- **Keyboard during hover:** `Command-Shift-Backslash` cancels hover state and applies the real split result instantly, with one intentional Ghostty resize when showing; `Command-Backslash` changes the overlay's rail/full selection without changing hidden persistence or terminal geometry.
- **Tracking unavailable:** remain safely hidden with keyboard/menu commands functional; do not install a broader input monitor as fallback.
- **Narrow window:** clamp the overlay using the existing width policy without changing the real split, then return fully hidden after hover.
- **Inactive or detached host:** cancel delayed work and animation and remove the cue rather than retaining stale pointer state.
- **Overlay-to-split handoff:** remove the transient host and reveal the persistent sidebar atomically enough to avoid duplicate UI, flashes, lost sidebar state, or focus landing on a detached view.
- **Sidebar interaction during leave:** cancel pending dismissal while pointer, keyboard focus, accessibility focus, menus, or active sidebar interaction requires the overlay; resume grace-based dismissal once interaction ends and the pointer is outside both regions.

## Test Plan

Follow test-driven development and extend the existing sidebar presentation and split-controller coverage:

1. Presentation-model tests for the exact 80-point cue and 40-point reveal boundaries, dormant/cue/revealed transitions, jitter, leave grace, stale-token rejection, and symmetric left/right distance mapping.
2. Tracking-view tests proving its hit test passes through and pointer reporting follows resized local bounds on both sides without changing first responder.
3. Hidden width-mode tests proving `Command-Backslash` toggles rail/full selection without revealing, displaying a cue, moving the divider, resizing Ghostty, or changing hidden persistence, and that the next overlay uses the selected width.
4. Command tests proving `Command-Shift-Backslash`, Focus Sidebar, and position changes cancel transient state and active overlay animation and settle the real split instantly.
5. Overlay-host tests for 140-millisecond left/right reveal and hide transforms, correct rail/full frames, interrupted reversal from the current presentation transform, completion-token invalidation, resize reclamping, and pass-through behavior outside the sidebar itself.
6. Handoff tests proving persistent show removes the overlay and exposes the real split sidebar with one geometry update, without duplicate sidebar hosts, lost model state, stale focus, or intermediate terminal resizes.
7. Reduce Motion tests proving overlay presentation is immediate while any cue opacity transition remains independent.
8. Regression tests for cold launch while persistently hidden, terminal first-responder retention during passive reveal, intentional sidebar focus and interaction, contextual menus, accessibility focus, divider dragging, remembered expanded width, and existing visible rail/full behavior.
9. Titlebar layout tests proving the lockup uses leading alignment for a left sidebar and trailing alignment for a right sidebar, while preserving padding and icon-before-text order in both rail and full presentations.
10. Live verification in the worktree app for cue clarity, 80/40-point thresholds, smooth overlay motion without Ghostty resize or reflow, left/right placement, terminal clicking/dragging/scrolling within the tracking zone, direct sidebar interaction, leave grace, rapid pointer reversal, resizing mid-animation, hidden width selection, overlay-to-split keyboard handoff, keyboard immediacy, and Reduce Motion.
11. Focused titlebar live QA at representative narrow and wide window sizes: left placement remains unchanged; right placement anchors the complete awesoMux lockup to the sidebar's trailing edge with matching padding; icon/text order, rail/full modes, persistent show, and hover overlay remain visually correct.

## Integration Notes

This document refines the hidden-sidebar edge interaction and explicitly supersedes both the original split-shifting hover reveal and this document's earlier real-divider hover animation. Proximity reveal is an overlay; only explicit persistent presentation uses the real split. It also supersedes the original titlebar alignment only for the right-side awesoMux lockup. The original persistence, command routing, semantic split roles, position setting, other titlebar behavior, peek direction, and Markdown alignment decisions remain authoritative unless this document explicitly supersedes them.

Before publishing, refresh open pull-request overlap because the implementation continues to touch central content, command-routing, and sidebar layout surfaces.
