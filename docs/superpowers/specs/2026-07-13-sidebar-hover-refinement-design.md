# Sidebar Hover Refinement

## Summary

Refine the hidden-sidebar pointer interaction from the original [Sidebar Presentation and Markdown Toggle Alignment](2026-07-13-sidebar-presentation-design.md) design. A pass-through 40-point edge tracking region first provides a visible proximity cue, then temporarily reveals the user's selected rail or full sidebar when the pointer reaches the inner 16 points.

Only pointer-driven transitions animate. Explicit keyboard commands remain immediate and deterministic.

## Goals

- Make the hidden sidebar discoverable before it shifts the workspace layout.
- Increase the pointer target without intercepting terminal clicks, selection, or scrolling.
- Preserve the selected rail/full width while the sidebar is persistently hidden.
- Give a large pointer-driven layout shift a restrained transition consistent with the existing rail-to-full experience.
- Behave symmetrically on the configured left or right edge.
- Cancel obsolete pointer and animation work cleanly when interaction state changes rapidly.

## Non-goals

- Changing the persistent meaning of Hide/Show Sidebar.
- Animating explicit keyboard, menu, palette, focus, launch-restoration, or settings actions.
- Adding an interactive handle or reserving permanent window space for the proximity cue.
- Overlaying the revealed sidebar over terminal content.
- Changing the existing rail and full sidebar widths.

## Interaction Design

### Proximity states

When the sidebar is persistently hidden, pointer distance from its configured window edge produces three transient states:

1. **Dormant:** farther than 40 points from the edge. No sidebar cue is visible and the detail area retains the full window width.
2. **Cue:** from 40 points through 16 points from the edge. A 4-point accent strip appears flush with that edge without moving the split divider or detail content.
3. **Revealed:** closer than 16 points to the edge, or within the temporarily revealed sidebar. The cue transitions into the selected rail or full sidebar and the detail pane shifts to make room.

Distance is measured inward from the physical edge selected by `appearance.sidebar_position`: from the left window edge for a left sidebar and from the right window edge for a right sidebar. Boundary comparisons must be stable: entering at 40 points activates the cue, and moving inside 16 points activates the reveal. Small pointer jitter at a boundary must not cause competing transitions; the presentation model owns the single current proximity state.

The existing short leave grace period continues to cover movement between the trigger and the revealed sidebar. Re-entering either region cancels the pending hide. Once the pointer leaves both the tracking region and sidebar, the temporary reveal closes after the grace period and the cue disappears when the pointer is outside 40 points.

### Accent cue

The cue is a 4-point, non-interactive accent strip using the sidebar/focus accent vocabulary already present in the design system. It overlays the configured window edge and never reserves layout width. It must not participate in hit testing, keyboard focus, accessibility traversal, divider dragging, or width persistence.

The strip's opacity may use a brief transition when it appears or disappears. It must be removed immediately when the sidebar becomes persistently visible, the window becomes inactive in a way that invalidates tracking, or the configured side changes.

### Pointer-driven animation

Crossing from cue to revealed animates the split divider to the selected sidebar width over 140 milliseconds with an ease-in-out timing curve. Leaving reverses that pointer-driven movement with the same restrained duration and curve. The animation should feel comparable to the existing rail-to-full transition, without spring overshoot or delayed settling.

Only hover reveal and hover hide animate. `Command-Shift-Backslash` persistently hides or shows the sidebar immediately. Focus Sidebar, position changes, restoration, and other explicit commands also settle immediately.

When Reduce Motion is enabled, pointer-driven divider movement is immediate. A very short opacity fade for the 4-point cue is permitted because it does not move content, but the cue must remain legible and must not delay the state transition.

### Width selection while hidden

`Command-Backslash` continues to select between the collapsed rail and full sidebar even while the sidebar is persistently hidden. The command changes the remembered width mode without revealing the sidebar, showing the cue, or moving the divider. The next temporary or persistent reveal uses the newly selected mode.

If `Command-Backslash` is used during a temporary hover reveal, it follows the existing rail/full behavior for a visible sidebar. That width transition may retain the existing rail-to-full animation behavior; it is not the new hover animation and does not alter persistent hidden state.

## Architecture

### Pass-through AppKit tracking region

Add an AppKit tracking surface owned by the existing split-view/content orchestration described in the original design. It covers the inner 40 points of the configured window edge while the sidebar is persistently hidden. The surface observes pointer movement and entry/exit but is pass-through for hit testing, so terminal input remains owned by the terminal/detail view beneath it.

The implementation must not install a window-wide event monitor or a SwiftUI hit-testing overlay. Tracking is local to the relevant content/split geometry and updates when the window resizes or the sidebar changes sides. Its coordinate conversion computes edge distance from current bounds rather than cached screen coordinates.

Pointer observation reports distance/state changes to the main-actor sidebar presentation model. It must not recreate terminal hosting views, change first responder, synthesize mouse events, or consume clicks, drags, scroll events, contextual clicks, or terminal text selection within the 40-point zone.

### Presentation state

Extend the existing sidebar presentation model with an explicit transient proximity state (`dormant`, `cue`, or `revealed`) rather than deriving multiple independent booleans in views. Persistent hidden preference and remembered width mode remain separate inputs.

The model decides:

- distance-to-state transitions for either physical side;
- whether the accent cue is visible;
- when a hover reveal/hide animation is requested;
- leave grace-period scheduling and cancellation;
- clearing transient state after explicit commands, resize invalidation, side changes, or loss of a valid host window.

Delayed hides and animation completions carry a generation/token. Any newer pointer, keyboard, resize, position, or lifecycle event invalidates older work so stale completion handlers cannot collapse a newly shown sidebar or resurrect an old cue.

### Split-view animation

The existing semantic sidebar/detail roles remain the source of divider calculations. Hover animation changes the sidebar role's presented width between hidden and the remembered rail/full width, using position-aware divider coordinates. Persistence is never updated with intermediate animation widths or zero.

Each new transition cancels the current animator and begins from the divider's current presentation width toward the newest requested state. Completion normalizes the split layout to the model's current state rather than trusting the state that originally started the animation. Resizing reclamps the current and target widths, cancels invalid geometry work, and settles or restarts toward the newest request without leaving a partial-width sidebar.

Explicit Hide/Show, Focus Sidebar, side changes, and restoration cancel any active hover animator and apply their result without animation. Moving the sidebar between left and right clears the cue, pending hide, tracking state, and hover animation before rebuilding the tracking region on the new edge.

## Accessibility and Input Preservation

- The 40-point tracking region and 4-point cue are pointer-only and absent from keyboard and accessibility focus order.
- Menu, palette, cheatsheet, shortcut customization, and Focus Sidebar remain the discoverable non-pointer paths.
- Pointer tracking never changes first responder; typing continues to reach the terminal while the cue appears or while a temporary reveal animates.
- A temporary reveal must not steal VoiceOver focus or announce itself as a persistent preference change.
- Reduce Motion removes content-moving hover animation as described above.
- Explicit hiding transfers focus out of the sidebar using the existing focus-preservation behavior before the instantaneous collapse.

## Failure and Interruption Behavior

- **Rapid reversal:** cancel the active animator, use its current visual width as the new starting point, and settle at the newest pointer state.
- **Stale leave timer:** generation validation makes the completion a no-op after re-entry or any explicit state change.
- **Window resize:** refresh tracking geometry, recalculate edge distance, clamp targets, and never persist an intermediate width.
- **Position change:** clear all transient left/right state before installing tracking on the new side; no cue may remain on the old edge.
- **Keyboard during hover:** `Command-Shift-Backslash` cancels hover state and applies the persistent result instantly; `Command-Backslash` changes rail/full selection without accidentally changing hidden persistence.
- **Tracking unavailable:** remain safely hidden with keyboard/menu commands functional; do not install a broader input monitor as fallback.
- **Narrow window:** use existing width policy and semantic split roles to choose a valid revealed width, then return fully hidden after hover.
- **Inactive or detached host:** cancel delayed work and animation and remove the cue rather than retaining stale pointer state.

## Test Plan

Follow test-driven development and extend the existing sidebar presentation and split-controller coverage:

1. Presentation-model tests for the exact 40-point cue and 16-point reveal boundaries, dormant/cue/revealed transitions, jitter, leave grace, stale-token rejection, and symmetric left/right distance mapping.
2. Tracking-view tests proving its hit test passes through and pointer reporting follows resized local bounds on both sides without changing first responder.
3. Hidden width-mode tests proving `Command-Backslash` toggles rail/full selection without revealing, displaying a cue, moving the divider, or changing hidden persistence, and that the next reveal uses the selected width.
4. Command tests proving `Command-Shift-Backslash`, Focus Sidebar, and position changes cancel transient state and active hover animation and settle instantly.
5. Split-controller tests for 140-millisecond hover reveal/hide requests, correct left/right divider targets, interrupted reversal from current presentation width, completion-token invalidation, resize reclamping, and no intermediate-width persistence.
6. Reduce Motion tests proving divider changes are immediate while any cue opacity transition remains independent.
7. Regression tests for cold launch while persistently hidden, terminal first-responder retention, divider dragging, remembered expanded width, and existing visible rail/full behavior.
8. Live verification in the worktree app for cue clarity, 40/16-point thresholds, left/right placement, terminal clicking/dragging/scrolling within the tracking zone, rapid pointer reversal, resizing mid-animation, hidden width selection, keyboard immediacy, and Reduce Motion.

## Integration Notes

This document refines only the hidden-sidebar edge interaction in the original design. The original persistence, command routing, semantic split roles, position setting, titlebar behavior, peek direction, and Markdown alignment decisions remain authoritative unless this document explicitly supersedes them.

Before publishing, refresh open pull-request overlap because the implementation continues to touch central content, command-routing, and sidebar layout surfaces.
