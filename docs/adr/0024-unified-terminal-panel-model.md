# 0024 — Unified terminal panel model

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** eD

## Context

awesoMux shipped two terminal-panel controllers: the older
`FloatingPanelController` (per-workspace scratch terminal) and the newer,
GUI-hardened `PopUpTerminalController` (app-wide Terminal Companion, PR #514).
They duplicated window construction, chrome, focus retry, promotion, and
anchoring while diverging only in a few behaviors.

## Decision

One `TerminalPanelController` configured by a `TerminalPanelMode` value type.
The companion invocation adds minimize-to-corner-tab and cross-workspace
persistence; the floating invocation adds per-workspace slots, center
anchoring, and Escape smart-dismiss. Differences are data (`anchor`,
`interceptsBareEscape`, `hasCornerTab`, `persistsAcrossWorkspaces`,
`sizeStoreKey`, `minimumSize`, `defaultSize`), not subclasses. The genuinely
floating-only per-workspace state lives in an owned `FloatingSlotBook`
collaborator, composed in rather than branched through every method. One
`TerminalPanelChromeView` renders both modes. The unified controller forks its
entry path on mode: the companion binds, installs parent observers, and
attaches child windows; the floating panel stays standalone (never a child
window, never observes the parent) with a one-shot show that re-binds its
root view to the active workspace slot every summon. `FloatingPanelController`
is deleted.

Both modes are user-movable (`isMovable` + `isMovableByWindowBackground`) and
user-resizable via the `.titled`-with-stripped-chrome window (borderless-
resizable is a known-dead approach here). A `panelUserPositioned` flag mirrors
`cornerTabUserPositioned`: once the user drags the panel, reanchoring only
clamps it back on-screen instead of resetting it to the anchor; the flag
resets on close/dismiss so a fresh summon re-anchors. Each mode remembers its
size per display bucket via `TerminalPanelSizeStore`.

ADR-0023 remains authoritative for the Escape policy; it is now enforced by
`TerminalPanelMode.interceptsBareEscape` (companion `false`, floating `true`)
and guarded by `TerminalPanelModeTests`.

## Consequences

- Workspace/group destroy confirms now use `isCloseRisk`/`sessionsAtRiskOnClose`
  (a soft close orphans a bridged daemon; reopen mints a fresh id), matching the
  companion's PR #514 close gate; the `⌘Q` quit path keeps `isQuitRisk`. The
  quit-scoped `hasRiskyFloatingSessions` is removed (no callers after the flip).
- The floating panel now centers over and clamps to the PARENT window frame
  (companion behavior), replacing the old fixed 640×480 screen-relative size.
- The companion size store moved from a flat `[Double]` to a per-display
  `[String: [Double]]` under the same key, so the first launch after this change
  resets the remembered companion size once (pre-1.0, intentional — the next
  resize re-seeds it).
- The corner tab shows an explicit "ended" state when a minimized shell exits.
- Shared types still carry `Floating…` names (`FloatingPanelFocusState`,
  `FloatingPanelEventPolicy`, `FloatingPanelDismissConfirmationState`,
  `FloatingPanelStoreFactory`, `FloatingPanelHostingController`,
  `FloatingPanelLayout`), and the presentation enum stays
  `PopUpTerminalPresentation`; renaming them to `TerminalPanel…` is a mechanical
  follow-up left out of the unification diff.
- `DestructivePaneActionConfirmationPolicy` still uses `isQuitRisk` for
  pane-scoped destroys; a close-scope flip there is a tracked follow-up.
