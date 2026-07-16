# 0025 — Sidebar single-host presentation

- **Status:** Accepted
- **Date:** 2026-07-16
- **Deciders:** eD

## Context

The sidebar/detail divider is a real `NSSplitView` divider hosted in a plain
`NSViewController` (INT-535). Reveal-on-hover and the `⌘\` toggle both need to
show and hide the sidebar without the libghostty Metal surface tearing at the
seam.

The earlier presentation carried two candidate homes for the sidebar view and
moved it between them: a split-pane home and a root-level "overlay" home, with a
reparenting handoff (`moveSidebarHost`), a slimmed presentation-state machine,
and an application-focus recovery web to survive the view leaving and re-entering
the tree. That machinery existed to avoid a suspected Metal "shimmer" during
animated reveal, and to keep focus intact across the reparent.

INT-845 revisited whether the two-home design was still justified.

## Decision

The sidebar has **one permanent host**: the root-level container (formerly named
"overlay", renamed to "sidebar host" — see the rename in this branch). The
sidebar view mounts there full-time and never moves. The split-pane slot is an
**empty width reservation** — a spacer that reserves layout width for the
detail/terminal pane so the divider math and reclamp policy stay unchanged.
Reveal is a **layer slide** of the permanent host, not a reparent.

Reparenting, `moveSidebarHost`, the atomic show/hide handoff, and most of the
supporting instrumentation are deleted.

### Step-0 experiment

Before committing to the single-host design we animated the real `NSSplitView`
divider directly. Frame capture showed the divider animation is smooth
(11–14 frames over a 216ms leg) — the "shimmer" that motivated the old
two-home overlay architecture does not occur. That premise is **falsified**.

Animating the divider for every reveal was still rejected: a per-frame divider
animation drives a per-frame terminal resize, and resizing the terminal every
frame rewraps multi-pane content. So hover-reveal stays an overlap-style layer
slide over a stationary detail pane rather than a live divider animation. The
one-shot `⌘\` toggle keeps its single, non-animated resize.

### Why the split-pane home was inverted

The originating issue proposed keeping the sidebar in the split pane and sliding
the whole split view (or a snapshot of it). Both were rejected during
implementation:

- Sliding the whole split view moves the terminal with it, so the terminal is no
  longer stationary and rewraps during the slide.
- A snapshot slides cleanly but is not interactive.

The permanent host is therefore the **root container**, and the split pane is the
**spacer** — the inverse of the issue's parenthetical.

## Consequences

- **Focus-recovery web stays (mostly).** The claim that the focus infrastructure
  existed "only because the view leaves the tree" was falsified during
  implementation. It is live application-activation and cross-window focus
  infrastructure (the Settings window's "hide now, repair later" path, and
  surface-mount timing), pinned by behavioral tests that require retry-until-
  success. Only the redundant `didBecomeActive` trigger was safe to delete.
  Deeper removal requires an explicit product/accessibility decision and is not
  taken here.

- **The command mailbox stays.** The issue asked whether the presentation-command
  mailbox could be replaced by a plain optional plus `onChange`. Implementation
  evidence showed it cannot: the mailbox encodes toggle-parity against the
  pending target, deferred-command persistence across host replacement, and
  rejection semantics that a plain optional cannot represent. Resolved: keep it.

- **Titlebar lockstep stays.** The issue assumed the titlebar brand lockup would
  "move for free" with the sidebar. Under every candidate design it does not: the
  lockup is SwiftUI titlebar chrome, not part of the sidebar `NSView`, so it is
  driven in lockstep rather than carried by the host. Moving the lockup into the
  sidebar view is deferred future work (~250–400 lines) that re-opens the
  INT-790 titlebar-inset coordinate mapping; gate it on a control experiment.

- **The test suite was renamed, not rewritten.** Review found the prior
  ~3,968-line suite was roughly 95% behavioral at rewrite time, so the projected
  large line-count reduction rested on a misclassification. It was renamed to
  `SidebarPresentationBehaviorTests.swift` with surgical edits (mechanism-only
  assertions removed), and the behavioral bulk kept passing throughout.

- Because the sidebar never leaves the view tree, the reveal path no longer
  depends on reparent timing, and the animation runs against a single stable
  layer.

## Limitations

- Hover-reveal is an overlap slide, not a divider animation, specifically to
  avoid per-frame terminal rewrap. If a future change makes per-frame terminal
  resize cheap enough, the divider-animation path is available again (Step-0
  proved it is smooth).
- The titlebar lockup lockstep remains until the deferred move lands.
