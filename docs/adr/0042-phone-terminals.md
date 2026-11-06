# 0042 — Your Mac's terminals, usable from your phone

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Sarah
- **Issue:** [#892](https://github.com/Interactive-Buffoonery/awesomux/issues/892)

## Context

A paired phone can already attach an interactive stream when its Mac-approved
Input switch is on. Requiring a separate Take over tap makes opening a terminal
feel like opening a viewer. Restored panes are lazily mounted on the Mac, and a
phone currently cannot start a workspace or pane when it needs one.

[ADR-0036](0036-multi-client-terminal-leadership.md) keeps last-typer leadership.
[ADR-0040](0040-live-terminal-stream.md) supplies snapshot generations and an
explicit `claim` with a grid. [ADR-0041](0041-paired-device-terminal-input.md)
supplies the device-wide, default-off Input switch. This decision changes the
phone's opening default and adds creation under that existing authority.

## Decision

### Open ready to type

Opening a pane with Input on takes control at the phone's size; Watch is an
explicit choice. The phone opens the existing interactive `watch_terminal`
stream, waits for `snapshot_end`, and sends a fresh `claim` carrying its grid.
The existing Mac relay forwards that frame as zmx `TakeOver`, without a dummy
keystroke or a new protocol version. A Watch choice omits the claim and input;
Input off still receives a Mac-enforced Watch role. An interactive follower
remains allowed to claim later through Take over or accepted typing.

A reconnect never restores an old claim or replays input. When reopening in
Input mode the phone makes a new claim only after the new snapshot. Explicit
Watch stays Watch. The Mac's control banner, local typing taking control back,
stream generations, revocation and no-replay rules remain in force.

### Open restored panes

Every terminal in `list_panes` has a target version, including
`awaitingHydration`. That availability is truthful lazy-mount state, not a
reason to disable opening on the phone. The phone must make both `attached`
and `awaitingHydration` terminal rows openable when a target version exists.
The former attached-only row condition must be removed on the phone (#61).

Before acknowledging `watch_terminal`, the Mac validates the original device
lease, Terminal scope, pane assignment and target version. It starts the same
cached native surface creation and SSH preflight used when selecting a pane
on the Mac, without selecting it, changing focus or acknowledging attention.
It waits on filesystem events within the request deadline for the local daemon
socket before starting the relay. Concurrent opens reuse the cached surface and preflight.
Input is not required to hydrate a Watch pane. Phone-initiated SSH preflight
retains the original certificate, lease revision, target, cancellation and
deadline, and rechecks them under the authority lock immediately before spawning.
Losing that authority prevents a phone-only hydration from spawning; a native
Mac mount or another authorized phone can still need the shared preflight.

An exited pane returns `pane_exited`; a disconnected or reconnecting bridge
returns `pane_disconnected`. A remote-owned zmx pane, disabled command bridge
or unavailable native runtime returns `terminal_unavailable`; no local shell
is substituted for a remote terminal. Missing or changed identities return
`stale_target`. A hydration that misses the request deadline returns `timeout`.
A session ending after acceptance retains the stream's `session_ended` reason.

### Create a terminal

Add the Companion-only `create_terminal` operation. It uses the authenticated
pairing envelope and accepts exactly one optional argument, `workspaceID`:

```json
{
  "schemaVersion": 1,
  "requestID": "<UUID>",
  "operation": "create_terminal",
  "connectionID": "<paired device UUID>",
  "workspaceID": "<existing workspace UUID, omit for a new workspace>"
}
```

The optional `profile` must match the listener. Explicit null, pane IDs,
commands, titles, SSH destinations and split direction are rejected.

- With no workspace ID, create a local shell using `SessionStore.addSession`,
  the Mac's configured default group and native New Workspace directory/title
  defaults. An SSH group default cannot turn this into a remote workspace.
- With a workspace ID, use `SessionStore.splitActivePane` with the native
  right-split orientation. The new shell inherits the active terminal's
  execution plan and local launch directory, including its SSH host for
  local-amx SSH panes. Like native Cmd-D, it does not inherit the reported remote
  working directory; SSH starts with the host's normal login directory behavior.
  A workspace containing a remote-owned (`.remoteZmx`) pane returns
  `remote_workspace_unsupported` before any mutation; remote session creation
  is unsupported. No execution location is accepted from the phone.
- Both require Terminal authority covering the whole target workspace and
  Input on. A new workspace requires `allWorkspaces`; a workspace-scoped grant
  can split only its own workspaces. A pane-only grant cannot authorize a new
  pane. No permission is added. Recheck certificate, original lease revision,
  cancellation and deadline while holding authority through the synchronous
  native mutation. Recheck the lease before every response write.

The success envelope adds:

```json
{
  "schemaVersion": 1,
  "requestID": "<request UUID>",
  "profile": "<runtime profile>",
  "appInstanceID": "<Mac runtime UUID>",
  "capturedAt": "<ISO 8601 timestamp>",
  "createdTerminal": {
    "workspaceID": "<workspace UUID>",
    "paneID": "<pane UUID>",
    "targetVersion": "<target UUID>"
  }
}
```

The phone opens that identity with `watch_terminal`, which hydrates it if
needed. Errors use the existing `error` string envelope. A lost creation
reply does not roll back the terminal and must not cause an automatic retry;
the phone refreshes the roster to find the result.

Like `rename_pane` (#860), the Mac decodes this endpoint before the shared
`CompanionOperation` policy. Shipping the Mac requires no shared protocol
package change. The phone can use local Codable DTOs, or add
`CompanionOperation.createTerminal = "create_terminal"`, optional
`CompanionAPIRequest.workspaceID: UUID?`, and optional
`CompanionAPIResponse.createdTerminal` with three UUID fields (`workspaceID`,
`paneID`, `targetVersion`) to the shared package. Schema and stream versions
stay at 1. These phone/package edits are separate work.

There is no implemented creation-provenance or last-typed note that fits this
mutation. Do not repurpose the current-leader banner as creation provenance
or add new UI. The existing banner identifies the phone when its stream claims.

## Consequences

The existing Input decision also permits starting a shell. Terminal scope
still bounds creation, and revoking either prerequisite prevents it. The phone
can reopen lazy panes without moving the Mac user to them. Rename, close,
choosing a split direction and selecting an SSH host for a new workspace remain
outside this change. The phone must implement the opening policy, openable row
condition and creation UI separately (awesomux-companion #61).

Focused isolation tests cover Input off, missing/out-of-scope Terminal grants,
native SSH split parity, remote-owned workspace rejection, certificate/revision
checks, local creation, stale/revoked/expired requests, versioned
restored panes and denial before hydration. Native runtime and physical-phone
verification remain separate from those tests.
