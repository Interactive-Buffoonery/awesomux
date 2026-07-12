# 0007 - Agent waiting semantic state

## Status

Accepted, amended by INT-293, INT-599, and INT-650.

## Context

`AgentState` previously had no quiet state for "the agent is alive and waiting
for the next user turn." `running` covered that case as a catch-all, which made
the UI less precise and left future adapter work without a stable semantic
target.

A prior approach considered inferring this state from Ghostty viewport text.
That direction is not accepted here: passive visible-text sampling has already
been a regression-prone integration point, and expanding
`ghostty_surface_read_text` polling would make the semantic contract depend on
fragile terminal rendering details.

## Decision

Add `waiting` as a first-class semantic state only:

- `AgentState.waiting` and `AwState.waiting`.
- Quiet priority between `output` and `running`.
- No notifications, unread increments, or quit-risk prompt.
- A vertical block-cursor glyph (the "awaiting input" terminal cursor) in status
  dots and agent badges so the state does not rely on color alone. A horizontal
  caret (`>`) was rejected: it shares the rightward-wedge silhouette of
  `running`'s play triangle, and `waiting`/`running` sit on the
  tritanopia-adjacent blue/sapphire pair — so the shape, not the hue, has to
  carry the distinction. A vertical bar is maximally distinct from a horizontal
  triangle.
- Pause remains reserved for a future explicit paused/suspended/interrupted
  state if the runtime can produce that signal.
- Preserve persisted `waiting` snapshots on restore instead of clamping them to
  `idle`.

This branch does not implement live Claude Code detection. Reliable runtime
integration is deferred to INT-350 through a side channel such as hooks,
statusline output, or another explicit adapter contract.

## Consequences

UI and policy code can now distinguish "alive but awaiting the user" from
`idle`, `running`, and `output` without adding detector behavior. The state is
safe to render and persist before every agent adapter can produce it.

The sidebar footer intentionally does not expose `waiting` as a filter chip.
It is quiet background context, and making it a footer filter would add
keyboard and VoiceOver navigation weight for a state that does not need
attention.

The app includes a DEBUG-only manual smoke test:

- Menu path: Workspace -> Debug: Set Active Workspace Waiting.
- Implementation: `AwesoMuxApp` updates the selected session through
  `SessionStore.setDebugAgentState(id:agentState:clearsAttention:)` with `.waiting`.
- No unread delta is passed, so the notification tracker should stay quiet.
- The item is guarded by `#if DEBUG`; the default `./script/build_and_run.sh`
  path builds release for day-to-day performance, so use `./script/build_and_run.sh debug`
  or stage a debug binary into `dist/awesoMux.app` when testing this visual
  state without lldb.

Future runtime work must not add broad live viewport polling as the source of
truth for this state. INT-185 added the explicit runtime side-channel transport
that can carry `waiting`; opt-in Claude Code configuration and agent-specific
adapters remain follow-up work under INT-350 and its adapter issues.
OpenCode and Pi are additionally gated by
[ADR 0010](0010-opencode-pi-opt-in-agent-integrations.md): their runtime events
are applied only when the matching provider is currently enabled, even if a
plugin or extension file is already present on disk.

The visible-text detector explicitly drops `.waiting` (`applyDetectedAgentState`
early-returns when the detected state is `.waiting`), so only the runtime side
channel may mark a pane as prompt-ready. Heuristic UI cues like a trailing `?`
prompt are too noisy to drive this state and would conflict with the explicit
adapter signal.

## Amendment (INT-293 and turn-complete lifecycle)

The original decision routed both turn-end (`Stop`) and a fresh, never-prompted
session (`SessionStart`) through the quiet blue `waiting` state. In practice
that blurred two different moments: a brand-new agent session the user has not
started yet, and a completed turn that the user should notice.

The accepted lifecycle separates **attention overlay**, **resting execution
state**, and **unread completion events**:

- `attentionReason != nil` projects the visible tile to `needsAttention`.
- `agentExecutionState` is the current resting truth when there is no attention
  overlay.
- A normal turn-end rests directly on waiting: `Stop` should carry
  `executionState: .waiting` with no `attentionReason`. It displays as the blue
  pause immediately because pause is the primary "agent is waiting for your next
  turn" semantic.
- If a normal turn-end happens while the terminal is not focused, the pane still
  increments unread / notifies. That alert is event metadata, not a peach
  attention overlay.
- A fresh, never-prompted session (`SessionStart`) maps to `idle`, the quiet
  at-rest state. There has been no completed turn, so there is nothing to alert.
- A blocking permission, approval, or choice maps to `needsAttention` through a
  specific attention reason such as `.permissionPrompt`; acknowledgement should
  not imply that the agent has completed the turn.
- Session exit (`SessionEnd`) is distinct from turn-end. The agent is gone, not
  ready for the next turn, so exit resets to shell/idle and clears attention and
  unread state where the provider can produce a reliable exit signal.

Status lifecycle:

| Moment | State contract |
| --- | --- |
| Agent/session starts, no user turn yet | `executionState: .idle`, no attention |
| User submits a prompt | `executionState: .thinking`, attention cleared |
| Tool/model/subagent work starts or continues | `executionState: .thinking` |
| Tool output is visibly streaming | Future `output` signal if a provider exposes reliable progress; do not fake it from generic tool-end hooks |
| Permission, approval, or blocking choice | Preserve current execution as appropriate, add `attentionReason: .permissionPrompt` or another specific blocking reason |
| Normal turn completes | `executionState: .waiting`, no `attentionReason`; if unfocused, increment unread / notify |
| User acknowledges the completed turn | Clear unread; visible state remains `waiting` |
| User answers the completed turn | Clear unread / any attention and move back to `thinking` as the new prompt starts |
| Agent/session exits | Reset to shell `idle` when a trustworthy exit signal exists |
| Runtime/tool/session failure | `executionState: .error` |

Provider lifecycle mapping:

| Moment | Claude Code | Codex | OpenCode | Pi |
| --- | --- | --- | --- | --- |
| Session starts | `SessionStart -> idle` | `SessionStart -> idle` | `session.created -> SessionStart -> idle` | `session_start -> SessionStart -> idle` |
| User prompt submitted | `UserPromptSubmit -> thinking` | `UserPromptSubmit -> thinking` | `chat.message -> UserPromptSubmit -> thinking` | `before_agent_start -> UserPromptSubmit -> thinking` |
| Tool/subagent starts | `PreToolUse` / `SubagentStart -> thinking` | same | `tool.execute.before -> PreToolUse -> thinking` | `tool_execution_start -> PreToolUse -> thinking` |
| Tool/subagent ends | `PostToolUse` / `SubagentStop -> thinking` | same | `tool.execute.after -> PostToolUse -> thinking` | `tool_execution_end -> PostToolUse -> thinking` |
| Permission or blocking choice | `PermissionRequest -> needsAttention(permissionPrompt)`; notification subtype fallback may also mark attention | `PermissionRequest -> needsAttention(permissionPrompt)` | `permission.ask -> PermissionRequest -> needsAttention(permissionPrompt)` | No current template signal; future Pi permission hooks should map to `needsAttention(permissionPrompt)` |
| Normal turn completes | `Stop -> waiting` (unfocused: unread / notify) | `Stop -> waiting` (unfocused: unread / notify) | `session.idle -> Stop -> waiting` (unfocused: unread / notify) | `agent_end -> Stop -> waiting` (unfocused: unread / notify) |
| Prompt-ready quiet signal | `Notification(notification_type=idle_prompt) -> waiting` | No current signal | No current signal separate from `session.idle` | No current signal separate from `agent_end` |
| Session exits | `SessionEnd -> shell idle` | Codex `SessionEnd` is ignored in v1 | No current normal quit hook; OpenCode may keep its glyph after an agent process exits inside a living shell | `session_shutdown -> SessionEnd -> shell idle` |
| Failure | `StopFailure -> error` | No current helper signal | `session.error -> StopFailure -> error` | No current template signal |

`waiting` remains a first-class semantic state. It represents "the agent is ready
for another user turn." It is still safe to persist and restore, and it still
must not be inferred from broad visible-text polling. The explicit hook side
channel owns turn-end waiting and prompt-ready state; viewport sampling remains a
conservative fallback for older/unconfigured panes.

## Amendment (INT-599, 2026-07-03): waiting glyph is now pause, not block-cursor

The original decision chose a vertical block-cursor glyph for `waiting` and
reserved pause for a hypothetical future paused/suspended/interrupted state.
In practice the block-cursor read as a blinking text cursor — and at small
sidebar/tile sizes, as an eye — implying text input or "watching" rather than
a quiet state badge.

`waiting` now renders the `pause.fill` SF Symbol (`AwStateGlyph.pause`) in
status dots and agent badges. The prior reservation no longer holds: no
runtime signal for a distinct paused/suspended state has materialized, and if
one ever does it will need its own state, color, and glyph anyway —
`AwStateGlyph` cases are shape names, not state semantics.

The shape-distinctness rationale is preserved: two vertical bars remain
maximally distinct from `running`'s horizontal play triangle for the
tritanopia-adjacent blue/sapphire pair. The collapsed rail's dot-only
rendering of `waiting` (`CollapsedStatusBadge`) is unchanged.

## Amendment (INT-650, 2026-07-04): turn-end rests directly on pause

INT-599's smoke test showed the two-stage `!`-until-acknowledged lifecycle was
coherent in implementation but surprising in product use. The intuitive reading
was that the pause glyph means "the agent is waiting on me"; hiding it behind a
peach `!` until acknowledgement made the most common waiting moment look like an
exceptional blocker.

The accepted hierarchy is now:

- Blue `waiting` / pause = the agent is paused at a turn boundary and ready for
  the user's next turn.
- Peach `needsAttention` / `!` = the agent is blocked on an explicit decision,
  permission, approval, or other specific attention reason.
- Unread count and macOS notification = the completion event happened while the
  terminal was not focused; this alerting layer does not change the persistent
  glyph from pause to `!`.

Therefore provider `Stop` / turn-end events map to `executionState: .waiting`
without `attentionReason: .userInputRequired`. Core still increments unread and
allows the notification bridge to fire for unfocused turn completions. Permission
prompts and provider notification fallbacks continue to use `attentionReason` and
project to `needsAttention`.
