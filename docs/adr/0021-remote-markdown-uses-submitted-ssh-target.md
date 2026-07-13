# ADR-0021: Remote Markdown Uses the Submitted SSH Target

## Status

Superseded by the declared execution identity model tracked in
[GitHub issue #2](https://github.com/Interactive-Buffoonery/awesomux/issues/2).
The corresponding implementation work is tracked secondarily in Linear as
[INT-812](https://linear.app/interactive-buffoonery/issue/INT-812/define-execution-location-and-host-aware-resource-identity)
and
[INT-821](https://linear.app/interactive-buffoonery/issue/INT-821/migrate-remote-markdown-snapshots-to-declared-identity).

## Context

awesoMux can detect that a pane is remote from the terminal title, for example
`alice@devbox:~/repo`. That prompt host is useful for display, but it is
not always the SSH target the user typed.

Many people use SSH config aliases. A user may run `ssh my-purple`, while the
remote prompt reports `devbox`. Reconnecting with `devbox` can fail
even though `ssh my-purple` works.

Remote Markdown snapshots currently fetch files by opening a short,
non-interactive SSH command from awesoMux. Until awesoMux has fuller SSH session
integration, the best target we have is the target from the submitted `ssh`
command.

## Decision

When a shell pane submits an `ssh` command, awesoMux records the command target
as runtime-only pane state. If the terminal title later proves the pane is
remote, that submitted target becomes the SSH target for remote Markdown
snapshots.

The prompt host remains the display and detection signal. The submitted SSH
target is only used for follow-up SSH reads, such as fetching a Markdown
snapshot.

The captured target is not persisted in workspace snapshots.

## Consequences

This supports SSH config aliases without adding a host-mapping UI or asking the
user to configure awesoMux separately.

This is probably temporary. Fuller SSH integration should own connection
identity directly, including aliases, users, ports, proxies, and any future
remote helper behavior. When that exists, remote Markdown should use that
connection model instead of this lightweight submitted-command bridge.

The current fetch still requires a non-interactive SSH read from awesoMux. If a
host needs an interactive password prompt for every new connection, the snapshot
fetch can still fail even though the already-open terminal session is usable.

## Superseding decision

Each pane now persists a `PaneExecutionPlan`. Remote Markdown fetches are
authorized only by an SSH plan and use its exact declared `RemoteTarget`; title
hostnames and submitted-command observations cannot create or retarget a fetch.
The snapshot persists a `ResourceIdentity` containing that execution location
and its remote path, while its local cache URL remains implementation state.
Relative paths require explicitly reported remote working-directory metadata,
and missing or malformed identity fails closed without local filesystem
fallback. The bounded non-interactive SSH transport described above remains
unchanged.
