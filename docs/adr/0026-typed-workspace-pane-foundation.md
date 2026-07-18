# 0026 — Typed workspace-pane foundation

- **Status:** Accepted
- **Date:** 2026-07-17
- **Deciders:** eD

## Context

awesoMux's workspace layout is an `indirect enum TerminalPaneLayout` with two
leaf kinds — a terminal pane and a tabbed Markdown document group — plus a split
node. Over time, per-kind behavior accreted as parallel recursions
(`removingPane` vs `removingDocumentGroup`), and the view layer decided pane
behavior by inspecting concrete payloads (`if case .documentGroup`,
`pane.executionPlan.remoteTarget != nil`, `document.isReadOnlySnapshot`).

Three planned features build directly on this layout model: named layout presets
(INT-757), pane-level reopen (INT-425), and a read-only artifact pane (INT-809),
with a sidebar header (INT-810) reading pane metadata. Each needs a stable seam:
presets must serialize *reusable layout intent* without live-only state; reopen
must distinguish reattaching an existing terminal from recreating a leaf; the
sidebar and artifact pane need a common leaf descriptor. Without a named model,
each feature would re-derive pane classification and risk leaking live state
(daemon session ids, file URLs, remote-cache origins) into a shared artifact.

## Decision

Formalize the existing layout into a **typed workspace-pane model** made of pure
value types, **without changing any encoded snapshot form** and without a
protocol or plugin registry (per AGENTS.md: a small set of product-owned kinds,
not third-party injection).

- **Taxonomy.** `WorkspacePaneKind` (`.terminal`, `.documentGroup`) names the
  closed set of leaf kinds. `WorkspaceLeafID` is a kind-tagged durable
  reference; `WorkspaceLeaf` is a leaf-as-value that type-aware projections
  dispatch on — the protocol-free "shared leaf" both kinds route through.
- **Shared operations.** `TerminalSplit.rebuilding(first:second:firstFraction:)`
  centralizes the split reconstruction that was copy-pasted across every
  structural mutation. `TerminalPaneLayout.{leaves, leafIDs, leaf(_:),
  removingLeaf(_:), replacingLeaf(_:with:)}` are the shared operation surface.
  Removal deliberately **dispatches** to the distinct per-kind policies rather
  than flattening them: only terminal removal defends the root "≥1 terminal"
  invariant (an auxiliary leaf can never be a workspace's sole survivor), so a
  single kind-agnostic remover would be unsafe.
- **Capabilities.** `WorkspacePaneCapabilities` exposes `localFileAccess`,
  `remoteProvenance`, `safeInputTarget`, `duplicable`, and `presetEligible` at
  layout granularity, reusing the existing `ExecutionContext` engine. Per-*tab*
  file access stays on `DocumentPane`/`ExecutionContext` and is not folded in.
- **Lifecycle as three axes.** The issue's lifecycle vocabulary splits into
  independent axes rather than one enum that would carry cases no producer can
  emit:
  - `PaneAvailability` (`.awaitingHydration`, `.attached`, `.unavailable`,
    `.stale`) — the DERIVABLE axis, a pure classifier over a leaf plus its
    runtime signals. Remote/degraded/dead panes never classify as a healthy
    local attach.
  - **Visibility** — an `isMounted: Bool` the mounting layer owns; a
    valid-but-unmounted leaf is "hidden". Not a leaf property, and a `Bool`
    needs no enum.
  - **Close phase** — `closing`/`closed` are transient states the close pipeline
    drives (`PaneCloseConsequence`); they have no stored representation, so no
    classifier fabricates them.
- **Live state vs reusable layout intent.** `WorkspaceLayoutIntent` is the
  preset seam. It is produced only by the prune-and-normalize projection
  `TerminalPaneLayout.layoutIntent` (retain preset-eligible terminal leaves,
  collapse the unary splits pruning leaves, drop their fractions, reject an empty
  result) and carries an explicit attribute allowlist — split orientation/
  fraction, a user-pinned title only, and pane color. It has **no field** for a
  pane id, `TerminalSessionID`, `PaneExecutionPlan`, working directory,
  `fileURL`, `ResourceIdentity`, agent state, or remote-cache origin, so live
  state cannot leak; a golden encoded key-set test fails if a future field
  reintroduces any. Wire-format versioning of persisted presets is INT-757's
  responsibility.
- **Restoration and close seams.** `PaneRestorationRequirement` separates
  `.reattachTerminal(TerminalSessionID)` (durable, reopen-only identity) from
  `.reopenDocumentGroup` (recreate from file identity), so a preset can never
  consume reattach-only daemon identity. `PaneCloseConsequence` is a thin
  projection: documents (and any future artifact) close immediately; terminals
  delegate to the existing `QuitRiskPolicy.closeDecision`.
- **Descriptor.** `WorkspaceLeafDescriptor` aggregates id, kind, label,
  capabilities, and availability so INT-810/INT-809 join on one value instead of
  re-joining by id.

## Snapshot compatibility

**No encoded form changes.** The persisted taxonomy is still the existing
`TerminalPaneLayout` Codable; the new types are derived/runtime-only and never
serialized into the session snapshot. The current schema version stays **v7**.
Existing v1–v7 migrations (agent-state fold, `.document`→`.documentGroup`, typed
remote `ResourceIdentity`, execution-plan inheritance, INT-775 fail-loud remote
decode) are unchanged. `TypedPaneSnapshotRoundTripTests` pins that a v7 snapshot
with a terminal + a document group carrying a terminal association and remote
provenance round-trips losslessly, asserting durable identity
(`terminalSessionID`, execution plan) explicitly because `Equatable` excludes it.

"Lossless" here means encode→decode equality of the durable fields before
`SessionRestoreReducer` sanitization; runtime-only field resets (liveness,
connection health, live title) are the intended, documented loss.

## Adding a workspace-pane kind (touch-point checklist)

A new **persisted** leaf kind (e.g. the INT-809 artifact pane) is a localized
change — one more arm at each existing exhaustive switch, reusing the single
split renderer and the single Codable machinery. It requires **no second layout
renderer and no second persistence framework**. The touch points are:

1. `TerminalPaneLayout` — add the leaf case + its `+Codable` encode/decode arm
   (this bumps the snapshot schema and needs a forward-rejection + migration
   test, per ADR-0005).
2. `TerminalPaneLayout+Queries` / `+Mutations` / `+Siblings` — the leaf-kind
   arms (most are the existing "invisible to terminal enumeration" no-op).
3. `WorkspacePaneKind` + `WorkspaceLeaf` (`leafKind`, `appendLeaves`, `id`,
   `kind`) and the shared `leaf(_:)`/`removingLeaf`/`replacingLeaf` dispatch.
4. The typed projections: `WorkspacePaneCapabilities.of`, `PaneAvailability.of`,
   `WorkspaceLeaf.{label, restorationRequirement, closeConsequence}`, and the
   `layoutIntent` retention rule.
5. The single render switch in `TerminalPaneView` and the persistence traversal
   in `SessionPersistence`.

The compiler forces each decision (the switches are exhaustive, no `default`
arms), so a missed site is a build error, not a silent fallthrough.

> Not yet satisfied as an *automated* test: an in-tree throwaway kind that
> exercises the checklist. The closed-enum taxonomy means a test cannot inject a
> case without editing production source. If a stronger literal proof is wanted,
> that is a follow-up decision (queued as an ASK on the PR).

## Consequences

- The view layer can stop re-deriving pane behavior from raw payloads; capability
  and descriptor projections are the intended seam. Migrating existing view sites
  off inline checks is deliberately out of scope here (avoids churn in files with
  concurrent work) and is follow-up.
- Presets, reopen, sidebar header, and artifact pane get stable, tested seams
  with no live-state leakage.
- Removal keeps two policies behind one shared API; a future maintainer must not
  collapse them into a single kind-agnostic remover.

## Out of scope

Shipping a third pane kind, a plugin system, sidebar redesign, drag-and-drop, and
implementing the presets/reopen UIs — this ADR provides their safe model seams
only.
