# 0015 — Recently-closed workspace cache: 24h TTL, no further hardening

- **Status:** Accepted
- **Date:** 2026-07-03
- **Deciders:** Sarah
- **Related:** INT-423, INT-415, ADR 0002

## Context

INT-415 shipped a persisted recently-closed workspace cache (`recentlyClosed`
in `session-state.json`, cap 20, TTL 7 days) backing Reopen Closed Workspace
(`Cmd-Shift-T`). Pre-merge review flagged that closed-workspace paths linger
on disk and can leave the machine via Time Machine, Spotlight indexing, cloud
sync of Application Support, or sysdiagnose bundles. INT-423 asked us to
evaluate four mitigations: shorter TTL, a settings toggle, an excluded-path
list, and Keychain-encrypting the blob.

## Decision

Drop the TTL from 7 days to 24 hours. Decline the other three options.

The key observation: `session-state.json` already persists working
directories for every *open* workspace — that is how session restore works —
and every exfil vector above applies equally to that data. The marginal
exposure from `recentlyClosed` is only that a path lingers up to TTL *after*
close. Hardening one field of a file whose other fields carry the same class
of data buys little; encrypting all session state is not on the table.

24 hours matches actual reopen muscle memory ("what I just closed") and cuts
the post-close disclosure window 7x at the cost of one constant.

Enforcement: pruning fires at close, reopen, and launch restore, and
`SessionStore.snapshot()` additionally filters expired entries at
serialization time, so any state-triggered save scrubs them from disk. On a
fully idle app the on-disk window is 24h plus time-to-next-save. In-memory
enablement of Reopen Closed Workspace is still checked lazily (an entry can
show as reopenable past 24h until the next prune trigger) — UI-level TTL
awareness is a follow-up, not a privacy exposure.

Known residual surfaces, accepted: quarantine archives
(`session-state.corrupted-*`, `session-state.sanitized-*`,
`session-state.conflict-*`, and `session-state.unsaved-*`) freeze their
contents at archive time and are count-capped, not age-capped; they carry
open-workspace paths too, so they are part of the whole-file exposure this
ADR declines to gold-plate. `session-state.unsaved-*` is the only one of the
four written at quit rather than at load: it holds state a termination flush
could not get into `session-state.json`, and like the others it is written
only while `restoreWorkspaces` is on, so the declined-toggle rationale below
continues to hold.

Re-affirmed (#335, 2026-07-30) now that the quit-time family exists: still
count-capped, still no age sweep, still no in-app "forget my saved sessions"
action. Retention for `session-state.unsaved-*` preserves the earliest capture
rather than the latest (#333), which raises the *value* of what is retained
without changing how much is retained or for how long. Since #339, "earliest"
means the first capture of the current incident: that archive is named by an
owner-only marker, and any successful live snapshot save clears the marker so
the next incident can establish a new pin. Earlier incident archives remain
eligible for ordinary eviction; there is still no age sweep. Archive paths are
logged by filename only across all four families, so a log export no longer
carries the account short name.

One narrowing of "only while `restoreWorkspaces` is on" (#334): the terminate
flush also runs when an explicit, user-approved recovery replacement is still
outstanding, because that write was requested specifically and the mid-session
continuation already completes it regardless of the setting. If that flush
fails, an `unsaved-` archive can therefore be written with the toggle off.
Reachable only by disabling restore in the gap between approving the
replacement and the detached write resolving, and it retains state the user
had just asked to be written to disk anyway. Since #338, termination waits at
most two seconds for that detached write. A timeout reports a write failure but
does not start an `unsaved-` archive write in the same slow directory; the
protected prior file remains unless the already-in-flight replacement finishes
before process exit. This deliberately trades the latest quit-time delta for a
truthful termination bound on a contended or network-backed home directory.

Addendum (INT-773, 2026-07-09): `recentlyClosed` entries also capture the
owning group's declared SSH target (`groupRemote`, a `user`/`host` pair) so
a deleted remote group reopens remote instead of silently local. This
extends the same accepted TTL window to infrastructure hostnames: deleting
a remote group no longer scrubs its target from disk immediately — it can
linger up to 24h in the closed-workspace cache. Accepted under the same
reasoning as paths: live remote groups already persist their targets
unbounded, so the marginal exposure is TTL-bounded lingering after delete,
and the same prune/serialization scrubbing applies.

## Declined options

- **Settings toggle** — `restoreWorkspaces = false` already stops all new
  capture and persistence. Note it deliberately does not delete an existing
  `session-state.json` (kept for recovery), so previously persisted paths
  remain until the file is cleared manually or restore is re-enabled and the
  next save scrubs them.
- **Excluded-path list** — new config surface for a marginal field; open
  workspaces under the same paths would still persist.
- **Keychain-encrypted blob** — largest surface, still leaves open-workspace
  paths in cleartext next to it.

Revisit only if session-state as a whole gets an encryption story.
