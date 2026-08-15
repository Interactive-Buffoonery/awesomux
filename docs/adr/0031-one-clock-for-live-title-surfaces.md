# 0031 — One clock for every live-title surface

- **Status:** Accepted
- **Date:** 2026-08-14
- **Deciders:** Sarah
- **Issue:** [#327](https://github.com/Interactive-Buffoonery/awesomux/issues/327)

## Context

A display-only OSC title write updates storage silently (issue #311), so two
notification paths keep title-derived UI current:

- each session's `LiveTitleBox` coarse mirror, which the sidebar *row* renders;
- `SessionStore.liveTitleGeneration`, a shared counter `SidebarView.body` reads
  to re-derive its projections (search haystacks, duplicate "N of M" ordinals,
  VoiceOver rotor labels, the agent activity panel, announcements).

Both were gated by a leading-edge coalescing window with an identical 1-second
interval — but they were two **independently phased** windows, each stamped by
its own events. With no shared phase, a row and the projections beside it
could name the same workspace by different titles: a screen reader lands on a
row the rotor called something else (WCAG 4.1.2), search matches a name no
visible row carries, and duplicate ordinals key on a title that isn't
displayed. The duplicate windows also meant the projections paid a whole
second re-derivation for publishes the row had already absorbed.

## Decision

**One gate, one tick.** `SessionStore.tickLiveTitle` is the sole owner of the
per-session `liveTitleCoalescingWindowHasElapsed` check. When a silent title
write arrives:

- if the session's window has not elapsed, only the box's fine-grained
  properties move;
- if it has, the same timestamp check bumps `liveTitleGeneration` **and** — via
  an explicit `publishCoarseNow` trigger passed into
  `LiveTitleBox.adoptPaneTitle` — publishes the box's coarse mirror.

The generation still bumps for a session with no box: projections cover the
whole roster, so their invalidation cannot wait for a row to exist. The
box-side window state (`lastCoarsePublish`, `coarseCoalescingInterval`,
`resetCoalescingWindow`) is deleted; the interval lives only as
`SessionStore.liveTitleGenerationInterval`. A bulk restore keeps clearing the
store-side stamp map, which is now the *only* per-session coalescing state.

**One channel for every name.** `SidebarView.body` builds a single
resolved-title map per roster session from the boxes' coarse mirrors
(`SessionStore.sidebarResolvedTitles()`, resolved through
`TerminalSession.displayTitle(overridingRawTitle:)` to preserve the
synthetic-title localization path) and threads it through the search haystack,
the duplicate disambiguator, the visible-row and rotor labels, the activity
panel's invalidation key, and the single-session announcements. Unrendered
sessions seed their box from storage on creation, so "coarse" means "current
storage" for them.

**Provenance on title matches.** `SessionMatch` carries the exact title string
the projection scored, and the sidebar snapshot uses it for the row, labels,
rotor, ordinals, and announcements until the projection is replaced. The
highlight ranges are `String.Index`es into the scored string; re-reading a
"fresher" source (struct or box) indexed them into a different string.

## Alternatives considered

- **Keep two clocks, tunable independently.** The intervals were the same
  number in two places, but phase — not duration — was the hazard, and no
  evidence ever asked for different periods. Two windows is exactly the bug
  shape; keeping them preserves a dial nobody turns.
- **Collapse the clocks only.** Single-gate publishing without a shared
  resolution channel would still let each projection re-derive from `groups`
  storage, which a silent write moves ahead of the coarse mirror. The row
  parity issue demands every surface resolve from the same values, not merely
  refresh at the same times.
- **A trailing debounce instead of a leading-edge gate.** Kills the remaining
  staleness ceiling but needs a scheduled wake-up per title write; the repo
  ratchets against new sleeps/polling in production code. The accepted ceiling
  is a uniform one-window lag every surface shares at once.

## Consequences

- A row and every name-bearing surface around it are *provably* in phase for
  display-only title reports: the only coalescing gate that can publish the
  coarse mirror is the gate that re-derives the projections reading it.
  Ordinary publishing and structural writes refresh both storage observation
  and the mirror immediately. Search freshness now equals row parity by
  construction.
- The surviving staleness ceiling is uniform: a final title write landing
  inside its window with nothing publishing afterwards leaves the whole
  sidebar — row included — naming the previous title until the next publish.
  No surface can disagree with another; it can only be late together.
- `SidebarView.body` now creates (and thereby retains) a `LiveTitleBox` plus its
  per-pane title channels for every roster session while building the map. The
  O(sessions + panes) objects are pruned with their sessions. This deliberately
  spends roster-bounded memory so collapsed or filtered-out workspaces join the
  same title channel before they render; revisit only if large-roster profiling
  shows retained channels matter.
- Tests drive the window with an injected `now:` as before; the gate having a
  single owner means the leading-edge, backwards-clock, and no-box behaviors
  are pinned in exactly one place.
