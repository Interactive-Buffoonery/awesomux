# 0005 — Session persistence as a JSON snapshot on disk

- **Status:** Accepted
- **Date:** 2026-05-08
- **Deciders:** eD, Sarah

## Context

awesoMux keeps a **tree of workspace groups, sessions, and split panes** with selection, titles, cwd metadata, and agent hints. That structure must **survive relaunch** without forcing the user to recreate their sidebar every time.

Early sketches mentioned **UserDefaults** or property lists for “v0 persistence.” Those stores are awkward for **nested Codable graphs** (pane trees, many sessions), lack a natural file for manual backup/inspect, and encourage unbounded growth if misused. **SQLite** (or similar) is attractive for search, history, and migrations later—but it is heavier than needed while the product is still proving the session model.

## Decision

Session/workspace state is persisted as **JSON** encoded from a single **`SessionSnapshot`** value (and friends), written to:

`Application Support/awesoMux/session-state.json`

(see [`SessionPersistence`](../../Sources/awesoMux/Services/SessionPersistence.swift)).

That path is the production/installed profile. The default development bundle
(`com.interactivebuffoonery.awesomux.dev`) writes its snapshot to
`Application Support/awesoMux-dev/session-state.json` instead, through the same
`SessionPersistence.supportDirectoryURL` seam. This keeps local dev launches
from racing or overwriting an installed copy's restore data. Dev state
intentionally starts fresh at the new paths: dev-launch state written before
the profile split (when dev builds shared the production paths) stays under
the production locations and is not migrated.

Linked Git worktrees append a stable path-derived id to the development bundle
identifier and write to `Application Support/awesoMux-dev-<id>/session-state.json`.
This extends the same isolation guarantee to concurrent builds from multiple
worktrees while preserving the primary checkout's existing dev state.

Writes are **debounced** to coalesce rapid edits. **Corruption or oversize files** are handled defensively: log, archive or drop the bad file where appropriate, and start from a fresh store rather than crash on decode.

Restore passes sanitize **display names**, **paths**, **layout depth**, and **duplicate group names** so tampered snapshots cannot violate UI invariants.

## Consequences

- **Inspectable** — operators (and support) can reason about a single JSON file; version bumps can add migration logic against a clear schema type.
- **Profile-scoped** — production and dev builds have separate support roots, so both can run at the same time without last-writer-wins snapshot clobbering.
- **Versioning** — when the model changes, we evolve `SessionSnapshot` (or wrap versions) and add decode migrations as needed; no separate DB migration runner for v0.
- **Limits** — very large histories or queryable “session browser” features may eventually warrant SQLite or another store; this ADR does not block that—it records that **v0’s durable medium is JSON**.
- **Privacy** — the file lives under the user’s Application Support; permissions are tightened where the implementation sets private file modes.

## Alternatives considered

- **UserDefaults / plist** — rejected for the sidebar graph: wrong fit for nested structures and size evolution.
- **SQLite now** — deferred until features require queries, concurrent writers, or rich history beyond restore.
