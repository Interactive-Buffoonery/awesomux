# 0028 - Permission decisions ride the amx bridge, file-pair fallback

## Status

Accepted (INT-628, feeds INT-110).

## Context

INT-110 gives agent tool calls an in-pane permission card. The provider side
is a blocking `PermissionRequest` hook: the hook process holds the tool call
open until it writes a decision JSON
(`hookSpecificOutput.decision.behavior: allow|deny`) to stdout, or writes
nothing and the provider falls through to its native prompt. The INT-628
spike verified this contract empirically on Claude Code 2.1.200: deny blocks,
allow proceeds promptless, empty output falls through, and a hook that
blocked ~10 s awaiting an external decision was applied cleanly (the default
command-hook timeout is 600 s, per-hook overridable). Codex is out of v1
scope; its hook-trust provisioning gate is the blocker, not the decision
shape (see the spike report referenced from INT-628).

The open question was the transport between the short-lived hook process and
the app: how does `awesoMuxAgentHook` forward the request to awesoMux and
receive the decision?

Candidates:

1. A new message type on the ADR 0011 `amx` command bridge (unix socket).
2. A file pair in the runtime-event directory: hook writes
   `req-<id>.json`, polls for `dec-<id>.json`.

The spike prototyped the file pair end to end; the bridge offers the same
blocking semantics without polling but requires the daemon to be reachable.

## Decision

The bridge is primary, the file pair is the daemonless fallback.

- `awesoMuxAgentHook` gains a blocking mode: connect to the `amx` socket,
  send a `permissionRequest` message carrying the hook stdin JSON, block on
  the reply, emit the decision to stdout.
- If the socket is absent or the connect/reply fails, fall back to the
  file-pair protocol in the runtime-event directory so a card can still be
  served when the daemon is down.
- On helper timeout — in either transport — the hook emits *no decision* and
  exits 0, deliberately falling through to the provider's native prompt.
  A transport failure must never manufacture an allow or a silent deny.

Timeout budget: the helper's own ceiling stays comfortably under the
provider's hook timeout (600 s on Claude Code) so the fall-through path is
always the helper's choice, never the provider killing the hook.

## Consequences

- One more `amx` message type; the daemon routes it to the owning pane's
  card UI and returns the user's choice.
- The file-pair path keeps polling out of the common case but preserves a
  no-daemon story; both paths share the same decision JSON, so the card and
  trust-store layers above are transport-agnostic.
- The provider's native dialog renders in the pane *while* the hook blocks
  and remains answerable; the hook decision wins if returned. The card UI
  (INT-110) must account for that duplication — this ADR only fixes the
  transport.
- Headless `claude -p` never fires the hook (calls are auto-denied first on
  2.1.200), so integration tests must drive the interactive TUI.
