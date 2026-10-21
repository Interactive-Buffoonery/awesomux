# 0028 - Permission decisions ride the amx bridge, file-pair fallback

## Status

Accepted (INT-628, feeds #822).

## Context

#822 gives agent tool calls an in-pane permission card. The provider side
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
  (#822) must account for that duplication — this ADR only fixes the
  transport.
- Headless `claude -p` never fires the hook (calls are auto-denied first on
  2.1.200), so integration tests must drive the interactive TUI.

## Implementation refinement (2026-10-20)

The local bridge uses a dedicated app-owned request-routing lane, sharing the
existing command bridge's secure listener-directory infrastructure. The legacy
remote lane replaces its active connection on promotion and applies reviewed
remote automatic-deny/session policy. Independent concurrent local hook requests
therefore cannot safely reuse that lane. This refines the `amx` socket/message
wording above: the app routes bounded typed local requests directly to the one
in-memory decision core, with independent connections and no daemon dependency.
The remote wire protocol and semantics remain unchanged; the pinned zmx
submodule is untouched. Phone decisions remain disabled under ADR-0038.

Both local transports retain the same hook invocation and expiry. The file pair
is a distinct request/decision record in the runtime-event directory, not the
telemetry stream. A helper acknowledgement follows a complete successful stdout
write; recording or claiming an answer alone does not prove delivery. Failure or
timeout still emits no decision and exits 0. The implementation budgets 120 s
for the helper and configures the Claude PermissionRequest hook for 150 s,
reserving time for the helper's own fall-through.

The native-prompt and headless observations above describe the 2.1.200 spike.
Interactive validation against the installed provider remains required; newer
hook documentation alone does not establish native-prompt race behavior.
