# 0003 — Acknowledge workspace notifications after selection dwell

- **Status:** Accepted
- **Date:** 2026-05-03
- **Deciders:** eD

## Context

Workspace notification acknowledgement used to happen directly in `selectedSessionID.didSet`. Any selection change immediately cleared unread counts and moved a workspace from `.needsAttention` back to `.running`.

That made fast keyboard cycling destructive to notification state. A user pressing `Cmd-Shift-]` through several workspaces could silently acknowledge every workspace they passed, even if they never stopped to inspect the one that needed attention.

## Decision

Acknowledgement is gated by selection dwell. When selection changes, `SessionStore` schedules acknowledgement for the selected workspace after 500 ms. If selection changes again before the dwell interval elapses, the pending acknowledgement is cancelled.

Explicit acknowledgement commands still clear immediately:

- `acknowledgeSession(id:)`
- `acknowledgeAllSessions()`
- The "Mark Workspace Read" menu command (`Cmd-Shift-K`)
- The per-row "Mark as Read" sidebar context menu item

## Why 500 ms

500 ms is short enough that intentional landing on a workspace doesn't feel laggy (the badge clears as the user starts reading) and long enough to keyboard-cycle through several workspaces without acknowledging any of them. Faster (250 ms): keyboard repeat through 5+ workspaces could ack the early ones before the user lands. Slower (1 s): clearing-on-read feels broken — the user has been on the workspace for a noticeable beat with the badge still visible. We did not test 100 ms boundaries empirically; if the value needs to move, the tests inject a custom duration, so the production constant can be revisited cheaply.

Alternatives considered and rejected for v0:

- **Explicit-only acknowledgement** (no selection-driven ack at all). Cleanest semantically — selection is navigation, ack is a separate gesture — but pushes too much friction onto the user, who would have to consciously dismiss every notification they've already seen. The "Mark Workspace Read" / "Mark as Read" commands provide this path for users who want it without making it the default.
- **Terminal focus or scroll as the ack trigger.** These remain passive actions that do not prove the user responded. Direct terminal input is now an acknowledgement trigger because the libghostty input bridge exists and can identify the active pane precisely.
- **Distinguishing mouse click from keyboard arrow at the SwiftUI layer.** Tempting, since a deliberate click reads more like an explicit pick than arrow-key cycling does. SwiftUI's `List(selection:)` binding is the same write path for both, with no exposed input modality. Detecting at the NSEvent level is fragile and would need to live below the SwiftUI tree. Instead, keyboard users get parity via `Cmd-Shift-K`, and mouse users have the per-row "Mark as Read" context menu — both faster than waiting for the dwell.

## Amendment — per-pane attention scope (INT-504, 2026-06-19)

INT-504 relocated agent attention state from `TerminalSession` down to each `TerminalPane`, so a split workspace can have one pane needing input while a sibling is calm. The dwell mechanism and the 500 ms gate are **unchanged**; only the *scope* of what a single dwell clears narrows:

- **Selection dwell acknowledges the ACTIVE pane only.** The dwell baseline now captures the active pane's identity and its unread count (not the session total). If a sibling pane still has `attentionReason != nil`, the workspace row stays loud until you visit that pane — which is what makes the side-by-side pane peek (INT-538) load-bearing.
- **The baseline cancels if the active pane changes mid-dwell.** Because the dwell baselines on `activePaneID`, switching panes before the interval elapses skips the ack (the captured pane is no longer active), mirroring how switching *workspaces* already cancels it.
- **`acknowledgeAllSessions()` / `Cmd-Shift-K` still clear every pane** in the workspace — the explicit escape hatch is unchanged.
- **`acknowledgeSession(id:)` and the per-row "Mark as Read"** now clear the active pane rather than the whole session, consistent with the dwell.

This amends, and does not supersede, the decision above: selection-dwell acknowledgement remains the model; it simply acts at pane granularity now that attention is per pane.

## Amendment — direct terminal input (2026-08-31)

Terminal input acknowledges the active pane immediately. This includes typing,
accepted paste actions, text drops, dictation, chrome-driven sends, and captured
terminal mouse input. Focus and scrolling remain passive and continue to use the
selection dwell.

Input clears the pane's unread count even when the pane is quietly `.waiting`.
If a permission or user-input prompt is still active, the same action also clears
that attention state. This keeps keyboard cycling non-destructive while ensuring
that a user who has started responding does not continue to see an unread badge.

## Consequences

- Cycling past a workspace no longer marks it read.
- Landing on a workspace for the dwell interval preserves the existing "selection eventually acknowledges" model.
- Direct sidebar clicks also acknowledge after dwell rather than immediately. This is intentional: the click is treated as selection (same code path as arrow-key navigation), and ack-on-read is the dwell. Users who want instant ack reach for `Cmd-Shift-K` or the row context menu — both are explicit signals that bypass the dwell.
- Direct terminal input acknowledges the active pane immediately; focus and scrolling alone do not.
- New notifications arriving during the dwell window are preserved. The pending ack only clears the workspace if its unread count has not grown since the dwell was scheduled.
- The dwell duration is injectable in tests so production behavior stays at 500 ms without slowing the test suite.
