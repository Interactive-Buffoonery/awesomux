# 0027 — Named, checked-in layout presets

- **Status:** Accepted
- **Date:** 2026-07-18
- **Deciders:** eD

## Context

INT-757: users want to save a workspace's pane/split arrangement as a named,
reusable preset that can be checked into a repo and shared (a standard "dev"
split for a project). ADR-0026 already provides the seam: `WorkspaceLayoutIntent`
is a pure layout structure with no field for live-only state, produced only by
the prune-and-normalize projection `TerminalPaneLayout.layoutIntent`.

## Decision

### File format and location

Presets are per-project files at `<projectRoot>/.awesomux/layouts/<name>.json`.
The filename (minus `.json`) IS the preset name. The project root is the
nearest `.git` ancestor of the workspace's working directory (same walker as
the path bar, extracted to `GitRepoRootLocator`), falling back to the working
directory itself outside a repo.

The wire format is `WorkspaceLayoutPreset`: `{ "version": 1, "layout":
<WorkspaceLayoutIntent> }`. Version is checked for exact equality — `0`,
negative, and future versions are rejected loudly as unsupported; a missing or
non-integer version is a malformed file. Unknown JSON fields are tolerated
(compatible extension), unknown layout node kinds are not.

### Untrusted-input posture

Preset files are checked into repos and shared, so they are **untrusted input**
end to end:

- **Names**: strict allowlist (`[A-Za-z0-9 _-]`, ≤ 64 chars, no dots or
  separators) applied on save and load — traversal is unrepresentable.
- **Filesystem containment**: every `.awesomux`/`layouts` component must be a
  real (non-symlink) directory and presets must be regular files; a checked-in
  symlink would otherwise redirect save (arbitrary overwrite) or load
  (arbitrary read). `LayoutPresetStore` enforces this on every path.
- **Bytes**: size cap (128 KB) and a byte-level JSON nesting pre-scan before
  `JSONDecoder` (the parser's own recursion precedes any decoder guard — same
  layering as `SessionPersistence.load`).
- **Decode**: `WorkspaceLayoutIntent.SplitIntent.init(from:)` bounds decode
  recursion with the same cap as `TerminalSplit.maxDecodedSplitDepth`, in the
  type so every intent decode is bounded.
- **Semantics**: `WorkspaceLayoutPreset` rejects layouts over
  `maxTerminalCount` (16) terminals or `maxSplitDepth` (15) nested splits
  before any pane exists — deliberately far under
  `SessionRestoreReducer.maxRestoredLayoutDepth` (64) so an applied preset
  survives the persist/restore contract, and bounding how many terminals an
  untrusted file can spawn.
- **Execution**: materialized panes are always `PaneExecutionPlan.local` with
  the workspace's working directory; the intent has no field that could name a
  host, command, or path, so applying a preset cannot execute anything beyond
  normal pane creation. Titles pass the standard `SessionStoreText` hygiene.

### Apply semantics — new workspace, not replace-in-place

Applying a preset **creates a new workspace** in the current group (selected,
titled after the preset, rooted at the same working directory). It does NOT
tear down the current workspace's panes. The issue sketch described
replace-in-place; that drags live-pane teardown (per-pane close-risk decisions,
daemon shutdown) into what is otherwise pure creation, and is destructive under
a mis-click. New-workspace apply is reversible (close it), needs no
confirmation dialog, and leaves replace-in-place as a possible additive
follow-up. Presets are **never auto-applied** on project open.

### Geometry semantics

A preset preserves **surviving split boundaries**, not pruned-sibling
proportions: the projection collapses a split whose sibling was pruned
(document group, remote terminal) into the survivor and drops that split's
fraction. Applied geometry reproduces the recorded structure with its clamped
fractions, which may differ from the visible proportions of the source layout
at save time. Fractions are clamped on decode (0.15–0.85, non-finite → 0.5).

### Surfaces

Two commands on the existing routing surface (ADR-0020): "Save Layout as
Preset…" and "Apply Layout Preset…" in the Workspace menu and the command
palette, plus one direct palette row per discovered preset ("Apply Layout:
<name>", snapshotted at palette summon, re-validated at run). No keyboard
shortcuts. Preset deletion/rename is the filesystem/git (the files are meant to
be edited and reviewed like any checked-in config).

## Consequences

- Save is `selectedSession.layout.layoutIntent` + one encode; apply is one
  decode + `materialize` + `insertSession`. No new persistence framework.
- A workspace with no preset-eligible pane (document-only, all-remote) has
  nothing to save; the save command says so instead of writing an empty file.
- Invalid preset files stay listed by name (listing is decode-free) and fail
  with a specific reason when picked — a broken shared preset is diagnosable,
  not invisible.

## Out of scope

Replace-in-place apply, auto-apply on open, preset management UI, remote/
document panes in presets (the projection prunes them by design), and any
per-preset execution hooks (rejected outright: presets must never run code).
