# Session Manager identity and recovery

**Date:** 2026-09-21

## Intent

The Session Manager must answer three questions without requiring daemon-ID
archaeology:

1. What is this background session?
2. Where did it come from?
3. How do I return to it?

The existing lifecycle and cleanup model remains authoritative. This design adds
human-readable identity and recovery to the current Owned, Detached, Abandoned,
Expired, and Elsewhere groups; it does not replace UUID-backed daemon identity or
turn `amx` into a workspace manager.

## Information hierarchy

Each row presents, in order:

1. activity (`busy` or `idle`);
2. session label;
3. working directory;
4. age;
5. attached-client count;
6. actions.

The short `amx:` UUID remains available as secondary diagnostic information,
either after the directory when space permits or in row details/accessibility
copy. It is not the primary label.

The session label uses the same naming policy as the workspace/sidebar:

- a user-edited workspace title wins;
- otherwise use the existing resolved synthetic workspace title;
- when one workspace has multiple terminal panes whose labels would otherwise
  collide, append the pane title;
- never derive durable identity from the label.

The directory column shows the daemon's current cwd when available. While a pane
is owned, current `SessionStore` data may supply richer presentation, but the
daemon remains the fallback source for rows without a live owner.

Search matches label, group name, directory, agent kind, and full UUID. Lifecycle
grouping and the existing pin/end actions remain unchanged.

## Recovery behavior

The primary row action depends on lifecycle:

| Lifecycle | Primary action | Result |
| --- | --- | --- |
| Owned | Open | Select the owning workspace and exact pane. |
| Detached | Restore | Reopen the existing `RecentlyClosedWorkspace` snapshot with its layout, active pane, group, and position. |
| Abandoned | Recover | Create a one-pane workspace whose terminal attaches to the surviving daemon. |
| Expired | Recover | Same as Abandoned until cleanup is confirmed; expiry never removes the recovery action by itself. |
| Elsewhere | None | Keep the row non-destructive while another unowned client is attached. |

Detached restoration reuses the existing targeted reconstruction logic but not
the current eager-draining `SessionStore.reopen` transaction. It first materializes
a provisional copy while leaving the source entry intact. After confirmed attach,
the commit transaction drains entries containing that daemon. The original group
is reused when present and otherwise recreated with its prior name and remote
target.

Abandoned recovery cannot reconstruct a lost split tree. It creates the smallest
truthful representation: one workspace containing one terminal pane attached to
the surviving `TerminalSessionID`. It uses the original group when that group is
still present and otherwise recreates it from daemon recovery metadata. The
workspace receives the stored workspace title and the pane receives the stored
pane title. Missing optional metadata degrades to the cwd-derived synthetic title
and a normal terminal-pane title.

Recovery must consume or supersede any stale reopen entry for the same daemon so
one backend cannot appear reachable through two workspace records.

Restore and Recover use an atomic existing-only attach. awesoMux first publishes a
provisional workspace without draining its recently-closed source. A confirmed
`attached` event commits the recovery and drains entries containing that daemon;
if the daemon disappears or attachment otherwise fails, `amx` does not create a
replacement shell, awesoMux removes the provisional workspace, and the original
reopen snapshot remains intact.

## Daemon recovery metadata

The UUID remains the immutable socket/session name. awesoMux writes a small set of
namespaced labels through the existing zmx label protocol:

- `awesomux.workspace-title`
- `awesomux.pane-title`
- `awesomux.group-id`
- `awesomux.group-name`
- `awesomux.group-remote` when applicable
- `awesomux.agent-kind`

Labels are applied atomically only when the first attach creates a daemon using
the fork's existing `attach --labels` path. Reattach, heal, Restore, and Recover
do not write labels from the attach process; awesoMux updates mutable labels after a user rename, pane
rename, workspace move, or group rename/retarget. Incidental OSC title churn does
not rewrite durable labels; current live titles may enrich an Owned row without
becoming recovery metadata.

zmx label values accept only ASCII letters, digits, hyphen, underscore, and dot.
awesoMux therefore stores textual and structured values as unpadded URL-safe
Base64 with explicit per-field decoded-size limits. Label values are presentation
and recovery hints, not trusted authority. Malformed fields are ignored
independently, and group identity is accepted only when it has the expected UUID
shape. Remote-target metadata encodes the app's existing typed representation and
is decoded through its normal validation rather than interpreted as shell text.

The existing verbose `amx list` output already emits cwd and every daemon label
as machine-parseable fields in its one-session-per-line output; populating these
labels makes the identity available at the command line without another zmx
format. `--short` continues to return only session IDs so scripts and garbage
collection retain their current contract. `amx get <uuid>` remains the complete
label inspection surface.

## Data flow

1. Pane creation resolves stable workspace/pane recovery labels and passes them
   with the initial `amx attach`.
2. Relevant app mutations update labels through `amx set`; failures are logged
   and retried on the next attach or relevant mutation without blocking UI.
3. Session Manager refresh reads one `amx list` snapshot, process activity, live
   workspace reachability, and recently-closed snapshots.
4. Row resolution prefers live owner data, then recently-closed metadata, then
   daemon labels/cwd, and finally UUID-only diagnostics.
5. Open, Restore, and Recover all revalidate the daemon and lifecycle immediately
   before mutating the workspace tree.
6. Restore and Recover mark their terminal panes for `amx attach --existing`; both
   attach-command availability and launch use that mode, preventing recreation in
   the interval after step 5.
7. The daemon's confirmed `attached` event commits the provisional recovery;
   failure rolls it back without changing reopen history.

No separate recovery registry is added. It would duplicate daemon and snapshot
state while introducing another synchronization and pruning problem.

## Failure and race handling

- If a daemon disappears before Open/Restore/Recover, refresh the row and report
  that the session ended; do not create a fresh shell under the old identity.
- If an abandoned daemon becomes owned or attached elsewhere before recovery,
  abort and refresh rather than creating a duplicate owner.
- If label update fails, terminal attachment still succeeds. UUID, cwd, and any
  surviving snapshot keep the row operable.
- A pre-label daemon is recovered automatically only when its cwd proves a local
  execution plan. A remote or ambiguous daemon remains visible and attachable by
  UUID, but awesoMux does not invent routing that could respawn it incorrectly.
- If group metadata is incomplete, create the recovered workspace in a local
  group named from the stored group name; if that is also absent, use a localized
  "Recovered Sessions" group.
- Recovery never kills or restarts the daemon and never discards scrollback.
- Recovery drains every recently-closed entry containing the recovered daemon
  only in the confirmation transaction after the provisional workspace reports a
  successful existing-only attach.
- Existing pre-kill revalidation remains mandatory for cleanup actions.

## Accessibility and interaction

- The complete row label speaks lifecycle, activity, session label, directory,
  age, client count, pin state, and shortened daemon ID.
- Open, Restore, Recover, Pin, and End Session have explicit labels and hints;
  iconography is not the only carrier of meaning.
- Keyboard focus follows visual row order. Return invokes the lifecycle's primary
  action when one is available.
- A successful Restore or Recover selects the resulting pane, dismisses the
  Session Manager, and announces the result.
- Recovery failure leaves the manager open, preserves focus where possible, and
  exposes a concise actionable error.

## Validation

Minimum automated coverage:

- label resolution follows user-edited, synthetic, and multi-pane naming rules;
- `amx list` parsing accepts the extended fields while remaining compatible with
  older daemons and preserving `--short` behavior;
- creation and relevant rename/move mutations produce the expected label updates;
- Detached restores the targeted snapshot to its existing or recreated group;
- Abandoned recovers the same daemon ID into a one-pane workspace;
- stale lifecycle and vanished-daemon races fail closed without duplicate owners;
- malformed recovery labels degrade safely;
- row accessibility copy and primary-action availability match every lifecycle.

Manual macOS verification covers realistic duplicate workspaces, long paths,
multi-pane labels, keyboard and VoiceOver operation, detach/restore, forced
abandonment/recovery, app relaunch, and preserved terminal contents after recovery.

## Explicit non-goals

- Human-readable strings do not replace UUID daemon IDs.
- Abandoned recovery does not reconstruct a split layout that no snapshot retains.
- This does not add Moshi support or a generic remote-multiplexer protocol.
- This does not adopt the external zmx session manager as a dependency; its
  attach/filter/copy workflow is useful product evidence, not missing runtime
  machinery.
