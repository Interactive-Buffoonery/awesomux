# 0002 — Window-close keybinding model (`Cmd-W` / `Cmd-Shift-W`)

- **Status:** Accepted (amended 2026-07-14: last-pane `Cmd-W` closes the workspace — see Amendment)
- **Date:** 2026-05-01
- **Deciders:** eD

## Context

A pre-merge accessibility review flagged the current `Cmd-W` / `Cmd-Shift-W` / `Cmd-D` bindings as a critical issue (INT-13): they appear to shadow 40-year-old macOS HIG conventions for "close window" / "close all windows."

Reviewing the bindings against the macOS HIG for **tabbed apps** (Safari, Terminal.app, Chrome) — rather than the HIG for single-window apps — flips the analysis. In tabbed apps the convention is:

- `Cmd-W` closes the innermost container (the tab).
- `Cmd-Shift-W` closes the enclosing window.

awesoMux is a single-window app whose user-visible top-level container is **the session** (sidebar entry), and whose innermost container is **the pane**. Once you accept that mapping, the existing bindings are HIG-compliant for the tabbed-app idiom — and they happen to match iTerm2 and cmux user muscle memory simultaneously.

The actual a11y bug the review surfaced is real, but it's not about the binding *choice*: it's about the silent fall-through where `closeActivePane()` calls `closeSelectedSession()` when only one pane remains, with no announcement, making behavior non-deterministic from the user's POV. That's a separate fix, not a binding decision.

## Decision

We adopt the **session-as-window** mental model and lock in iTerm/cmux-parity bindings:

| Binding / Trigger | Action | Mental model |
|---|---|---|
| `Cmd-W` (user-initiated, session selected) | Close pane. If this would leave the session empty, **silent recycle**: terminate the current shell, spawn a fresh one in the same slot. No prompt, no hold state — user's intent is explicit. Session always has at least one pane. | "close tab" |
| `Cmd-W` (no session selected — empty welcome state) | Close the app window via `NSWindow.performClose:`. App stays in the Dock. | "close window" — only path available when there's no pane to close |
| `Cmd-Shift-W` | Close the session. | "close window" |
| `Cmd-Q` | Quit the app, which closes the actual `NSWindow`. | "close app window" |
| `Cmd-D` / `Cmd-Shift-D` | Split right / split down. | iTerm + cmux parity |
| Shell exit / `Ctrl-D` / process crash in the only pane of a session | Close the session/workspace through the same last-pane close path used by pane removal. The closed workspace is eligible for `Cmd-Shift-T` reopen when it passes the recently-closed quality gate. | Ghostty tab close behavior |

The key-window exception for compact terminal surfaces is recorded in
[ADR-0023](0023-compact-terminal-dismissal-key-model.md): `Cmd-W` hides either
surface, but Escape is reserved for the terminal in Terminal Companion and
remains the quick dismiss action for the workspace-scoped Floating Panel.

The destructive fall-through is removed. `Cmd-W` does one thing — it closes the pane — and the never-empty-session invariant is upheld for user-initiated pane close by silent recycle. Shell-exit-driven last-pane close intentionally exits the workspace instead.

### Trigger distinction (user-initiated vs shell-exit)

The two paths have different failure modes and deserve different UX:

- **User-initiated** (`Cmd-W`, menu, etc.): the user has signalled clear intent. Surfacing an exit code or asking them to confirm is friction. Silent recycle is correct.
- **Shell-exit-driven** (process exits, `Ctrl-D`, crash): match Ghostty's terminal/tab close behavior. In a multi-pane workspace only the exited pane closes; when the last pane exits, the workspace closes and the recently-closed path handles recovery where there is meaningful state to preserve.

This distinction is what reconciles ADR-0002 with the concern raised in INT-20 (user-initiated pane close on the only pane silently vanishing the workspace) while preserving Ghostty parity for process exit.

The trade-off is explicit: single-pane process exit, including an agent process exiting with an error, closes the workspace. Recovery relies on `Cmd-Shift-T` / recently-closed reopen when the workspace passes that quality gate. awesoMux does not preserve the final scrollback in a held terminal state on this path.

User-facing terminology stays `pane` / `session` / `workspace`. The outermost `NSWindow` is referred to in implementation discussions as "**app window**" or "**shell**." We deliberately do **not** introduce a new user-facing term ("canvas" was considered and rejected for collision with Slack/Figma/drawing-app meanings).

## Consequences

- INT-13 closes as resolved by reframing rather than rebinding. Users keep iTerm/cmux muscle memory; a11y review's "non-deterministic close behavior" concern is addressed by removing the fall-through, not by moving the bindings.
- INT-8 (a11y polish) is unblocked — the previously-flagged keybinding hijack is no longer in scope for that bucket.
- Pane recycling on the **user-initiated path** has a destructive edge today: a user with a long-running foreground process (build, `vim`, `top`) in the only pane can lose state on `Cmd-W`. **Mitigation:**
  - **Short-term**: when recycling a pane that has a non-shell foreground process (or unsaved-state hint), show a Warp-style warning toast before terminating. iTerm-style modal prompts are explicitly *not* the model — toast over modal.
  - **Long-term**: the planned session-resume feature (tmux session-restore semantics, no plugin) makes recycling effectively non-destructive — the recycled pane re-attaches to the prior shell state. Once that lands, the toast becomes informational rather than protective.
- The **shell-exit path** does not need the foreground-process toast — by definition, the foreground process has already exited.
- The dynamic menu copy bug (`Cmd-W` showing "Close Pane" when it would actually close the workspace) goes away because `Cmd-W` no longer ever closes the workspace. Menu copy stays "Close Pane" while a session is selected. In the empty welcome state (no sessions), the menu copy flips to "Close Window" so the visible label matches what the chord will actually do — a disabled button there would silently swallow Cmd-W (SwiftUI claims the chord even when disabled), which is a worse outcome than briefly retitling.
- ADR-0001's heuristic ("would someone a year from now ask 'why did we do it this way?'") squarely applies here. The bindings will look wrong to anyone reading the HIG without context — this ADR is the answer.

## Open follow-ups

- Implementation tickets for: removing the fall-through, recycle-on-empty-session, the foreground-process warning toast, and `Ctrl-D` parity.

## Amendment — 2026-07-14: last-pane `Cmd-W` closes the workspace

- **Deciders:** eD

The "silent recycle" behavior for user-initiated `Cmd-W` on a session's last
pane is superseded. In practice most workspaces are single-pane, so the
dominant experience of `Cmd-W` was "my terminal got wiped" — reading as a
refresh, destroying scrollback, and matching no other mac app's `Cmd-W`.

New behavior: `Cmd-W` on the last pane routes through the same soft-close
funnel as the sidebar close button — confirmation gate when activity is at
risk, recently-closed capture, `Cmd-Shift-T` reopen. The close-confirmation
gate became trustworthy for bridged panes once daemon-spawned shells gained
shell integration (OSC-133 prompt marks), which is what makes this safe as a
default: an idle workspace closes silently, a busy one confirms.

Multi-pane `Cmd-W` still closes the innermost container (the pane); the
"close tab" mental model is preserved. The `Cmd-Shift-W` binding is unchanged
and now redundant with `Cmd-W` only in the single-pane case — an accepted
redundancy, mirroring tabbed-app behavior where closing the last tab closes
the window. Explicit shell restart remains available as its own command with
its own confirmation. Visible command titles (File menu, Workspace menu,
command palette, shortcut cheatsheet) follow the live pane count so no
surface claims "Close Pane" when the workspace would close.
