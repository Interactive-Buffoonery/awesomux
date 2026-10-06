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

## Amendment: independent one-operation file reads

An unmanaged SSH terminal may open a remote Markdown snapshot after the user
explicitly chooses an independent OpenSSH config alias and confirms the exact
file path. Submitted-command observations may prefill a simple alias but never
authorize the destination or recreate flags, wrappers, or nested connections.
This permission covers one file read; Refresh, document navigation, and later
opens require confirmation again. It does not change the terminal execution plan.

A declared snapshot retains its saved destination. Snapshots from confirmed reads
persist a restrictive read policy and restore cached-only, regardless of launch
refresh settings. Equal-resource tab deduplication can tighten this policy but
cannot relax it. Every network entry point consumes operation authorization
before starting and revalidates its originating pane or document after awaiting.

Terminal-relative links without trustworthy remote cwd metadata ask for an
explicit base directory or full `/…` or `~/…` path. Unqualified daemon or pane
cwd strings do not authorize resolution. Managed reads retain declared authority
and managed transport after this path choice. Unmanaged reads use independent
noninteractive OpenSSH, with no managed control socket or local-file fallback.
