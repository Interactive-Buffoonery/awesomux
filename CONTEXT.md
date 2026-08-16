# awesoMux — context

A native macOS terminal built on libghostty, with a vertical sidebar of sessions and first-class agent UX.

This file is the project's glossary and orientation entry point for the engineering skills (`improve-codebase-architecture`, `diagnose`, `tdd`, etc.). It grows lazily — the `/grill-with-docs` skill appends terms as they get resolved during real work.

For **high-level architecture** (targets, runtime, persistence, agent/notification model), see [`docs/architecture.md`](docs/architecture.md). For **keyboard shortcuts**, see [`docs/shortcuts.md`](docs/shortcuts.md). For **libghostty** build/link/runtime bridge details, see [`docs/ghostty-integration.md`](docs/ghostty-integration.md). For the **agent runtime side channel**, see [`docs/agent-runtime-side-channel.md`](docs/agent-runtime-side-channel.md). For **numbered decisions**, see `docs/adr/`. For the project rules, see [`AGENTS.md`](AGENTS.md).

## Markdown document panes

Markdown document panes are auxiliary rendered viewers for local `.md` and
`.markdown` files ≤2 MiB. They live inside a workspace beside terminal
panes; a document is never the only pane in a workspace. Current entry points
are **File > Open Markdown File…** (`⌘O`), the matching command-palette
action, local Markdown links opened from terminal output, and Markdown links
clicked inside another document pane.

Remote Markdown opens are read-only snapshots. Their durable provenance is a
`ResourceIdentity` built from the initiating pane's declared
`PaneExecutionPlan` and remote path; the downloaded local cache URL is only
implementation storage. Runtime titles and observed SSH commands never grant
fetch authority, and relative paths require explicitly reported remote working
directory metadata.

**Open Agent Transcript** (⌥⌘T) is the other way a document tab appears: awesoMux
renders the pane's agent session log to Markdown itself and opens that. Those tabs
are app-authored and not editable, but they are *local* — read-only here is
`isEditable`, not `isReadOnlySnapshot`. In place of **Send to Agent** they offer
**Resume**, which stages the provider's resume command in the adjacent terminal
without submitting it. See [ADR 0032](docs/adr/0032-agent-transcripts-are-rendered-artifacts.md).

The review/comment workflow is intentionally file-backed. A document can carry
one whole-document note plus any number of inline annotations. Selecting rendered
text and adding an inline annotation writes a `<mark>...</mark><!-- AMX id=... -->`
marker pair; the whole-document note is one own-line AMX marker. awesoMux watches
the file for reloads and keeps marker text available for the agent. **Send to
Agent** stages a nudge in the adjacent terminal without submitting it; the user
presses Return after reviewing the prompt. An agent resolves an AMX annotation by
setting `status=resolved`, keeping it available for verification. Legacy
`USER COMMENT` markers remain readable and use their original remove-on-complete
lifecycle.

## Glossary

Add rows here when a term is used repeatedly in code, issues, or ADRs and the meaning should stay stable.

| Term | Meaning |
|---|---|
| **Workspace group** | `SessionGroup` — named sidebar folder containing ordered sessions. |
| **Session** | `TerminalSession` — one sidebar row; owns agent metadata and a tree of panes (splits). |
| **Workspace tree** | The `SessionGroup -> TerminalSession -> TerminalPaneLayout` hierarchy. |
| **Workspace group color** | Optional per-`SessionGroup` sidebar tint override. It drives group identity chrome — the group dot/header tint plus row accent chrome such as the active rail/glow or a future collapsed-sidebar dot. It is decorative for row backgrounds: sidebar tile row text stays on stable semantic surfaces (verified by `script/check_tint_contrast.py`), and the tint does not affect terminal colors. |
| **Pane** | `TerminalPane` — one terminal slot; backed by a libghostty surface when attached. |
| **Workspace-pane kind** | `WorkspacePaneKind` — the closed leaf taxonomy (`terminal`, `documentGroup`). `WorkspaceLeaf` is the leaf-as-value type-aware projections dispatch on; a new kind is added here, not via a protocol/plugin ([ADR 0026](docs/adr/0026-typed-workspace-pane-foundation.md)). |
| **Pane capabilities** | `WorkspacePaneCapabilities` — per-leaf `localFileAccess`/`remoteProvenance`/`safeInputTarget`/`duplicable`/`presetEligible`, so views don't guess behavior from raw payloads. |
| **Pane availability** | `PaneAvailability` — derivable attachment classifier (`awaitingHydration`/`attached`/`unavailable`/`stale`). Visibility (`isMounted`) and close phase are separate axes. |
| **Layout intent** | `WorkspaceLayoutIntent` — reusable, serializable layout structure with zero live-only state; the INT-757 preset seam. Produced by the prune-and-normalize `TerminalPaneLayout.layoutIntent`. |
| **Execution location** | `ExecutionLocation` — value-semantic local or SSH-host identity. A pane's durable `PaneExecutionPlan` is authoritative; a workspace group's `RemoteTarget` only seeds new panes and migrates legacy snapshots. |
| **Resource identity** | `ResourceIdentity` — an execution location plus a path. Equal path strings on different hosts identify different resources. |
| **Document pane** | `DocumentPane` — auxiliary Markdown viewer leaf in a workspace layout; validates local `.md`/`.markdown` files, renders comments/highlights, and stays paired with a terminal pane for agent nudges. |
| **Agent transcript** | The on-disk JSONL log an agent CLI writes for one session (Claude Code and Codex today). awesoMux reads it, never writes it; **Open Agent Transcript** (⌥⌘T) renders a byte-bounded window of the newest turns into a document tab ([ADR 0032](docs/adr/0032-agent-transcripts-are-rendered-artifacts.md)). |
| **Transcript identity** | `AgentTranscriptIdentity` — provider + UUID session id, valid by construction, stored on the `DocumentPane`. It is the tab's durable identity; the rendered `.md` is regenerable storage, exactly as `ResourceIdentity` is to a remote snapshot's cache file. Stored on the document, not asked of the pane, because a pane outlives the session open beside it. |
| **Generated document** | A document tab whose file awesoMux authored rather than the user: a remote Markdown snapshot or a rendered transcript. Kept in owner-only caches, named so it can never occupy a user-content slot, and reference-pruned against live **and** recently-closed layouts. |
| **`isEditable` vs `isReadOnlySnapshot`** | Two different questions about a `DocumentPane`, deliberately not merged. `isReadOnlySnapshot` means *remote provenance* and folds across a whole tab group (`WorkspacePaneCapabilities`' `anyRemote`); `isEditable` means *this document accepts writes* and gates only write/navigate call sites. Widening the first to cover transcripts kills the send bar on the pane Resume lives in and strips `localFileAccess` from unrelated local tabs. |
| **Shell activity** | Runtime-only busy/idle signal for shell sessions. It is derived from Ghostty prompt markers after at least one prompt has been observed, debounced for chrome, not persisted, and separate from the raw quit-confirmation signal. |
| **Session snapshot** | On-disk JSON (`Application Support/…/session-state.json`) representing groups, layout, and selection for restore. |
| **Live title channel** | `SessionStore`'s per-session `LiveTitleBox` notification path for display-only OSC title writes, which update storage silently (issue #311). Two channels per box: fine (per pane, every report — pane title bars) and coarse (see below). |
| **Coarse mirror** | A `LiveTitleBox`'s `coarseWorkspaceTitle` / `coarsePaneTitles`. Display-only title reports publish it when the session's coalescing window fires; ordinary publishing or structural writes refresh it immediately. Everything the sidebar renders as a *name* resolves from it — rows, search haystacks, duplicate ordinals, rotor labels, announcements (`SessionStore.sidebarResolvedTitles()`). |
| **Live title generation** | `SessionStore.liveTitleGeneration` — the shared counter `tickLiveTitle` bumps when a session's window fires, alongside the same tick's coarse publish. One gate drives both (issue #327), so a sidebar row and every projection derived from it move together ([ADR 0031](docs/adr/0031-one-clock-for-live-title-surfaces.md)). |
| **Feedback report** | A user-initiated support message with diagnostics shown in an editable email draft before anything is sent. |

### Conventions

- **Single context.** awesoMux is one Swift app, not a monorepo. One `CONTEXT.md`, one `docs/adr/`.
- **Conventional Commits** for both commit messages and PR titles. See `AGENTS.md` § Code style.
