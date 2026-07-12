# ADR-0021: Remote Markdown Uses the Submitted SSH Target

## Status

Accepted

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
