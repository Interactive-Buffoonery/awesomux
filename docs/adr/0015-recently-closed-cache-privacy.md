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
(`session-state.corrupted-*` / `session-state.sanitized-*`) freeze their
contents at archive time and are count-capped, not age-capped; they carry
open-workspace paths too, so they are part of the whole-file exposure this
ADR declines to gold-plate.

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
