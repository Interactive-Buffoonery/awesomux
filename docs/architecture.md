# awesoMux — architecture

High-level shape of the app: targets, runtime composition, domain model, and where deeper topics live. For **libghostty build, link, and bridge details**, see [`docs/ghostty-integration.md`](ghostty-integration.md). For the **agent runtime side channel**, see [`docs/agent-runtime-side-channel.md`](agent-runtime-side-channel.md). For **default keyboard shortcuts**, see [`docs/shortcuts.md`](shortcuts.md). For **timeless decisions**, see [`docs/adr/`](adr/). For repository rules, see [`AGENTS.md`](../AGENTS.md).

## Product goals

1. Native Swift macOS terminal that feels as fast as Ghostty.
2. Vertical sidebar of workspaces as the primary navigation surface (organized into workspace groups).
3. First-class agent UX (Claude Code today; surface designed so other agents can plug in later).
4. MIT throughout — vendored upstream is MIT-only; no GPL inheritance (see [`AGENTS.md`](../AGENTS.md)).

## Non-goals (current direction)

- Cross-platform shipping — **macOS 15+** only (pinned in `Package.swift`). Ghostty itself is cross-platform; awesoMux does not target other OSes today.
- Remote multiplexing / tmux replacement — local sessions and splits only.
- General plugin system — agent integration is intentional and in-app until a second agent forces abstraction.

## SwiftPM targets

| Target | Role |
| --- | --- |
| **awesoMux** | `@main` executable: AppKit + SwiftUI chrome, settings, `GhosttyRuntime`, window/sidebar/session UI, `SessionPersistence` I/O. |
| **AwesoMuxCore** | Observable `SessionStore` facade, internal reducers/coordinators, session/workspace/pane models, agent state, notification policy/tracker, layout helpers — **unit-tested** (`AwesoMuxCoreTests`). Depends on `UnicodeHygiene`. |
| **AwesoMuxConfig** | TOML config load/round-trip with unknown-key preservation (currently scoped to the `terminal` table). Wraps `swift-toml` and `UnicodeHygiene` — **unit-tested** (`AwesoMuxConfigTests`). |
| **SecureFileIO** | Descriptor-backed, owner/type-validated reads with symlink-safe path traversal, `CLOEXEC`, and caller-supplied hard byte caps. Shared by config and Markdown document loading — **unit-tested** (`SecureFileIOTests`). |
| **AwesoMuxTestSupport** | Test-only clocks, gates, bounded event waits, temporary folders, socket clients, and domain test data. Production targets do not depend on it. |
| **AwesoMuxAgentHookSupport** | Shared hook-helper logic: provider parsing, bounded stdin handling, provider hook-event mapping, and `AgentRuntimeEvent` JSONL encoding — **unit-tested** (`AwesoMuxAgentHookSupportTests`). |
| **awesoMuxAgentHook** | App-bundled executable hook helper staged into `awesoMux.app/Contents/MacOS`; reads provider hook JSON from stdin and appends normalized agent runtime events to `AWESOMUX_AGENT_EVENT_FILE`. |
| **UnicodeHygiene** | Title/string sanitization: strips bidi override codepoints (RLO/LRO) while preserving bidi hints (LRM/RLM) for RTL users — **unit-tested** (`UnicodeHygieneTests`). |
| **DesignSystem** | Shared tokens and small UI atoms (`DesignSystemTests` uses `Testing`). |
| **GhosttyKit** | `systemLibrary` modulemap + headers shimming Ghostty’s C API. |
| **GhosttyKitLinker** | SwiftPM target whose **linker flags** pull in `.build/ghostty` artifacts (XCFramework fat archive plus static deps). Uses classic linker mode where required for Zig-produced archives — see ghostty integration doc. |

There is **no checked-in Xcode project**; day-to-day dev uses SwiftPM and [`script/build_and_run.sh`](../script/build_and_run.sh), which stages `dist/awesoMux.app` and copies Ghostty `share` resources into the bundle.

## UI layout (single window)

```text
┌─────────────────────────────────────────────────┐
│  awesoMux app window                            │
│ ┌──────────┬────────────────────────────────────┐
│ │ Sidebar  │ Active session (split panes)      │
│ │          │                                    │
│ │ ▸ Group  │ [libghostty surface(s)]           │
│ │   ● S1   │                                    │
│ │   ○ S2   │                                    │
│ └──────────┴────────────────────────────────────┘
└─────────────────────────────────────────────────┘
```

The sidebar lists **groups** (`SessionGroup`) and **sessions** (`TerminalSession`). Selection drives which session’s pane tree is shown in the main area. **Splits** are internal to a session (not separate sidebar rows); see **Split model** below.

**Keyboard / close semantics:** sessions map to the “tab” idiom and panes to the innermost closable unit. Accepted model is recorded in [ADR 0002](adr/0002-window-close-keybinding-model.md).

## Design references

Native UI work should follow the shipped SwiftUI/AppKit patterns and shared tokens under [`Sources/DesignSystem/`](../Sources/DesignSystem/).

## Domain model (code ↔ UI)

- **Workspace group** — `SessionGroup`: named folder in the sidebar; contains ordered `TerminalSession` values.
- **Session** — `TerminalSession`: one sidebar row; has `agentKind`, `agentState`, title, cwd metadata, and a **layout** of panes (`TerminalPane` tree via splits).
- **Pane** — `TerminalPane`: one terminal slot; at runtime backed by a libghostty surface when visible. Its durable `PaneExecutionPlan` declares local or SSH execution and is the authority for command routing and host-aware resource identity.
- **Remote document snapshot** — a read-only `DocumentPane` whose
  `ResourceIdentity` combines the declared remote execution location with its
  remote Markdown path. Its `fileURL` points only to the local rendering cache;
  identity and read-only behavior survive disconnect, offline restore, and a
  missing runtime attachment.
- **Workspace tree** — `SessionGroup -> TerminalSession -> TerminalPaneLayout`: the hierarchy that backs sidebar groups, workspace rows, and split panes.
- **Snapshot** — `SessionSnapshot`: Codable aggregate written to disk for restore (groups + selection + layout); see Persistence.

User-facing copy prefers **pane**, **session**, and **workspace**; ADR 0002 defines how those align with Close actions and the single app window.

## Layered design

```text
┌──────────────────────────────────────────┐
│  App shell (AppKit + SwiftUI)             │
│  Window chrome, sidebar, settings,      │
│  menus / shortcuts, floating panels       │
├──────────────────────────────────────────┤
│  Core (AwesoMuxCore)                      │
│  SessionStore, models, agent/notifications│
├──────────────────────────────────────────┤
│  Terminal bridge (awesoMux services/views) │
│  GhosttyRuntime, GhosttySurfaceView, …    │
├──────────────────────────────────────────┤
│  libghostty (C, via vendor/ghostty)       │
└──────────────────────────────────────────┘
```

Ghostty’s own **`macos/Sources/Ghostty/`** tree remains the best upstream reference for Cocoa + libghostty integration patterns (MIT); quote with attribution when porting patterns.

## Runtime composition

1. **`AwesoMuxApp`** — Registers default settings (`SettingsDefault`) *before* loading state so `UserDefaults` observers see real defaults. Loads `SessionStore` via `SessionPersistence.load()`, owns `GhosttyRuntime` and the local `DiagnosticsModel`, and wires `AppDelegate` to the store and runtime after launch.

**Local diagnostics (INT-671):** after the user performs a manual refresh and while its Settings pane remains visible, `DiagnosticsModel` samples the awesoMux process tree every 30 seconds and retains at most one hour of aggregate CPU and memory history. Manual refresh also discovers awesoMux-owned `amx` daemon trees; timed samples reuse that cached ownership instead of launching `amx list`. The sampler keeps fixed deadlines, skips missed intervals, and gives macOS timing tolerance to reduce wakeups. `LocalDiagnosticEventRecorder` receives bounded, privacy-safe config, restore, terminal, and runtime-failure outcomes; normal agent activity is not duplicated into diagnostics. This state is never persisted or uploaded, and it is deliberately separate from opt-in product analytics under ADR-0008.

**Product analytics (INT-768):** analytics defaults to off. Capture sites submit closed, typed `AnalyticsEventInput` values through one sanitizer; there is no arbitrary string property path. Only post-redaction event properties can enter the bounded, owner-only local JSONL ledger shown in Diagnostics; the random analytics identifier is stored separately. `AnalyticsPipelineClient` owns live consent checks, sanitization, transparency logging, and provider lifecycle behind an injected adapter. `AnalyticsConsentObserver` tracks effective consent and local-ledger retention for the app lifetime, including external config reloads while no window exists. `PostHogCaptureProvider` starts one bounded, ephemeral `URLSession` request per accepted event against the fixed PostHog Capture API, rejects redirects, adds explicit person-profile and GeoIP-disable controls, and owns no retry queue or provider persistence. Opt-out, tier downgrade, and deletion cancel tracked requests, though already-sent bytes cannot be recalled. `AnalyticsCaptureCoordinator` maps only reliable app launch, once-per-kind-per-launch handled diagnostic failures, and Diagnostics-opening seams into the closed vocabulary. Session/group mutation analytics remains deferred until Core exposes an unambiguous successful-mutation callback; inferred count observers, duplicate agent-state sources, and analytics-specific config callbacks are not used.
2. **`SessionStore`** (`@MainActor`, `@Observable`) — Authoritative facade for selection, pane operations, and agent fields. `groups` is a read-only snapshot; callers mutate the workspace tree through explicit commands and replace a restored snapshot with `replaceState(restoring:)`. It keeps observable UI state in one main-actor store, while focused internal reducers own pure workspace-tree, pane-layout, restore, recently-closed, shell-activity, runtime-event, and attention decisions. Persists on meaningful changes (debounced save — see `SessionPersistence`).
3. **`GhosttyRuntime`** — Process-wide libghostty lifecycle: init, config, `ghostty_app_t`, tick/wakeups; creates surfaces for AppKit views embedded in SwiftUI.
4. **Notification path** — `WorkspaceNotificationPolicy` + `WorkspaceNotificationTracker` + `WorkspaceNotificationBridge` / `UNUserNotificationCenter` (details below).

### Terminal panels

One `TerminalPanelController` backs both the app-wide Terminal Companion and
the per-workspace floating panel; a `TerminalPanelMode` value (`.companion` or
`.floating`) supplies the differences as data — anchor, whether bare Escape is
intercepted, corner-tab presence, cross-workspace persistence, size-store key,
and min/default size — instead of a subclass per mode. A shared
`TerminalPanelChromeView` renders both. The companion anchors bottom-trailing
over the workspace footer and owns exactly one global, runtime-only
`SessionStore` that survives workspace changes; its expanded lower-right card
and minimized corner tab host the same Ghostty surface, so minimizing or
switching workspaces does not restart the shell. The floating panel anchors
centered over the parent window and keeps one temporary `SessionStore` slot
per workspace, tracked by an owned `FloatingSlotBook` collaborator (open/active
sets, backgrounded-running-work) rather than branched through every
controller method.

The two modes fork on entry path: the companion binds to the parent window,
installs parent-window observers, and attaches its panel and corner tab as
child windows; the floating panel stays standalone — never a child window,
never observing the parent — and instead does a one-shot show that rebinds
its root view to the active workspace's slot on every summon. Per ADR-0023,
floating keeps bare Escape as smart-dismiss while the companion delivers
Escape to the terminal (TUIs need it); this is now expressed as
`TerminalPanelMode.interceptsBareEscape` rather than divergent handling per
controller. Both modes are user-movable and user-resizable; a
`panelUserPositioned` flag (mirroring the corner tab's own positioned flag)
tracks whether the user has dragged the panel, so reanchoring after that only
clamps it back on-screen instead of resetting it to the anchor, and each mode
remembers its size per display via `TerminalPanelSizeStore`. V1 does not
restore either panel after app relaunch.

The terminal bridge is split under `Sources/awesoMux/Views/GhosttySurface/`.
`GhosttySurfaceNSView` stays the thin AppKit/libghostty host, while focused
extensions own lifecycle/sizing, keyboard and mouse input, `NSTextInputClient`
IME/preedit, terminal callback interpretation, process-exit close/recycle
effects, scrollbar math, input mapping, accessibility announcements, and the
terminal backstop background color. Pure bridge decisions that affect durable
agent/session behavior live in `AwesoMuxCore`: `CommandExitCache` owns cached
exit-code freshness, and `VisibleTextAgentStateReducer` owns visible-text
fallback suppression, `.waiting` preservation, unread deltas, and error
announcement intents.

## Persistence

- **Location:** profile-scoped Application Support JSON (see `SessionPersistence.supportDirectoryURL`): installed/production builds use `Application Support/awesoMux/session-state.json`; the primary checkout's dev bundle (`com.interactivebuffoonery.awesomux.dev`) uses `Application Support/awesoMux-dev/session-state.json`; linked worktrees use `Application Support/awesoMux-dev-<worktree-id>/session-state.json`.
- **Format:** JSON via `JSONEncoder` / `SessionSnapshot`; debounced writes to avoid thrashing.
- **Safety:** size cap, corruption detection with archive-and-reset behavior, conservative restore sanitization (titles, cwd paths, layout depth, duplicate group names) so tampered files cannot violate UI invariants.
- **File permissions:** local stores keep their on-disk state owner-only — directories `0o700`, files `0o600`. The posture is defined once in `AwesoMuxConfig` (`FileManager+OwnerOnly.swift`: `createOwnerOnlyDirectory(at:)`, `setOwnerOnlyPermissions(onFileAt:/onDirectoryAt:)`); new stores adopt those helpers instead of hand-rolling permission literals (INT-859).
- **Execution-plan migration:** pane plans are additive and do not bump the snapshot schema. A missing or null pane plan inherits the owning group's legacy `RemoteTarget` during restore; only a successfully decoded, non-null plan is authoritative. A true v1 session with no `layout` key follows the same inheritance rule for its synthesized pane. Malformed active pane plans fail decoding and trigger the normal archive-and-reset path, while malformed recently-closed rows remain isolated to that disposable row.

The same runtime profile split scopes runtime event files, rendered integration
artifacts, daemon pins, settings config, and the command-bridge socket namespace.
Linked worktrees derive a stable 12-hex-character id from their canonical path
and use `awesoMux-dev-<id>`, `awesomux-dev-<id>`, and a deterministic short
socket directory. Agent integration install manifests are the exception: their
provider targets are global, so both manifests live under the production
`Application Support/awesoMux/AgentIntegrations` root and serialize mutations
with a cross-process lock.

Remote Markdown cache entries are keyed by the full typed resource identity,
so the same path on local, host A, and host B cannot share provenance or a tab.
SSH fetches use only the active pane's declared `RemoteTarget`; prompt titles,
display hostnames, and submitted-command observations remain presentation or
diagnostic signals. Relative remote Markdown paths resolve only from explicit
remote-directory metadata and otherwise fail closed.

Older sketch docs assumed UserDefaults for v0; **the shipped direction is JSON on disk** for session/workspace restore.

## Split model

Splits live **inside** a session. `Command-D` creates **Split Right** and `Command-Shift-D` creates **Split Down**; each pane owns its own Ghostty surface and inherits cwd from the active pane when created (see keyboard catalog / session APIs in code). Sidebar rows stay **sessions**, not per-pane rows.

## Typed workspace-pane model

The layout tree (`TerminalPaneLayout`) is a **closed** taxonomy of leaf kinds —
a terminal pane and a tabbed Markdown `documentGroup` — plus a split node. It is
deliberately an enum, not a protocol or plugin registry: awesoMux owns a small
set of product-owned pane kinds. `WorkspacePaneKind` names the leaf kinds,
`WorkspaceLeafID` is a kind-tagged durable reference, and `WorkspaceLeaf` is the
leaf-as-value that type-aware projections dispatch on (the protocol-free "shared
leaf"). Shared layout operations live over the tree
(`leaves`/`leafIDs`/`leaf(_:)`/`removingLeaf(_:)`/`replacingLeaf(_:with:)`, with
`TerminalSplit.rebuilding` centralizing split reconstruction); removal
*dispatches* to the distinct per-kind policies because only terminal removal
defends the root "≥1 terminal" invariant — an auxiliary pane can never be a
workspace's sole survivor.

Type-aware behavior is exposed as pure projections so the view layer need not
guess from raw payloads:

- **Capabilities** — `WorkspacePaneCapabilities` (`localFileAccess`,
  `remoteProvenance`, `safeInputTarget`, `duplicable`, `presetEligible`) at
  layout granularity, reusing `ExecutionContext`.
- **Lifecycle, three axes** — `PaneAvailability`
  (`awaitingHydration`/`attached`/`unavailable`/`stale`) is the derivable
  classifier over a leaf plus its runtime signals and never lets a
  remote/degraded/dead pane read as a healthy local attach; `PaneVisibility`
  (`visible`/`hidden`) is supplied by the mounting layer; `PaneClosePhase`
  (`active`/`closing`/`closed`) is supplied by the close pipeline. `PaneLifecycle`
  composes all three so every lifecycle term is representable while each axis is
  produced only by the authority that can observe it.
- **Live state vs reusable layout intent** — `WorkspaceLayoutIntent` is the
  preset seam (INT-757). The `TerminalPaneLayout.layoutIntent` projection prunes
  everything not preset-eligible (documents, remote terminals), collapses the
  resulting unary splits, and carries an explicit attribute allowlist only
  (orientation, fraction, user-pinned title, color). It has no field for a
  session id, execution plan, file URL, agent state, or remote-cache origin, so
  a preset cannot serialize live-only state.
- **Restore / close / descriptor seams** — `PaneRestorationRequirement`
  separates reattaching an existing terminal (durable `TerminalSessionID`) from
  reopening a document group (INT-425); `PaneCloseConsequence` folds terminals
  through `QuitRiskPolicy` and closes documents immediately;
  `WorkspaceLeafDescriptor` aggregates id/kind/label/capabilities/availability
  for INT-810 and INT-809.

The model is additive: it changes **no encoded snapshot form** (schema stays
v7). Adding a persisted kind is a localized set of exhaustive-switch arms reusing
the single split renderer and Codable machinery — see
[ADR 0026](adr/0026-typed-workspace-pane-foundation.md) for the full model and
the touch-point checklist.

## Sidebar presentation

The sidebar/detail divider is a real `NSSplitView` divider in `SidebarSplitController`. The sidebar view mounts full-time in a **single permanent host** (the root-level `sidebarHostView` inside `sidebarHostClipView`) and never moves. The split-pane slot is an empty width reservation for the detail/terminal pane. `⌘\` toggles the sidebar with a one-shot resize; hover-reveal slides the permanent host's layer over a stationary detail pane (an overlap slide, not a divider animation — a per-frame divider animation would rewrap multi-pane terminal content). See [ADR 0025](adr/0025-sidebar-single-host-presentation.md).

## Agent state contract

`AgentState` is the vocabulary for agent execution and attention. Shell command activity is tracked separately as **Shell activity** so a live login shell does not masquerade as an agent in `running`. `.done` means an agent run or detected agent command completed successfully; terminal process-exit workspace close does not set `.done`.

| State | Meaning | Visual contract | Notification behavior |
| --- | --- | --- | --- |
| `idle` | No agent attached / shell-only session at rest. | No agent-tile status badge; absence is the quiet idle signal in expanded and collapsed sidebar presentations. | Never notifies. |
| `running` | Agent attached with no recent activity; not raw shell-process liveness. | Quiet idle dot. | Never notifies. |
| `waiting` | Agent/session is alive but awaiting the next user turn; no work in flight. | Quiet blue pause indicator, distinct without color alone. | State itself is quiet, but an unfocused turn-completion event can increment unread / notify while remaining visually `waiting`. |
| `thinking` | Tool call or model response in flight. | Mauve activity indicator. | Never notifies. |
| `output` | Fresh stdout or visible progress in the recent-output window. | Green output indicator. | Never notifies by default. |
| `needsAttention` | Blocked on an explicit user decision such as permission, approval, or a blocking choice. | Peach loud pulse. | Increments unread and may drive user notifications. |
| `done` | Agent finished cleanly. | Teal check. | v0: does not notify; often ephemeral because exit may close the pane/session. |
| `error` | Agent crashed or exited non-zero. | Red error mark. | v0: does not notify; wiring evolves with exit-code plumbing. |

Acknowledgement clears unread and any attention overlay. For a normal turn-end,
`Stop` rests directly on `waiting`: the blue pause is the primary "agent is
waiting for your next turn" semantic. If the turn completed while the terminal
was not focused, the pane can still receive unread / notification treatment, but
that event does not project to the peach `needsAttention` badge. Selection-based
acknowledgement uses a **dwell** so keyboard cycling does not accidentally clear
attention or unread state — see [ADR 0003](adr/0003-acknowledge-on-selection-dwell.md).

Transition diagram (target contract; not necessarily a single enforced state machine in code yet):

```text
idle ── attach agent ──▶ running
running ── model/tool starts ──▶ thinking
running ── prompt-ready quiet timeout ──▶ waiting
waiting ── user submits turn ──▶ thinking
waiting ── agent run / detected command completed ──▶ done
thinking ── stdout/progress ──▶ output
output ── prompt-ready quiet timeout ──▶ waiting
running|thinking|output|waiting ── user input required ──▶ needsAttention
needsAttention ── user acknowledgement ──▶ underlying execution state
waiting(unread turn-complete) ── user acknowledges ──▶ waiting
running|thinking|output ── agent run / detected command completed ──▶ done
running|thinking|output ── detector/runtime error ──▶ error
error ── next shell command in this pane exits zero ──▶ idle
```

Per-state color polish may lag the table above; loud vs quiet distinction is implemented with design-system foreground roles today.

`prompt-ready quiet timeout` means an adapter has a reliable prompt-ready signal and the recent-output quiet window has elapsed. The runtime side channel is the preferred path for explicit agent identity/state events: awesoMux injects per-pane environment variables and watches a capped JSONL event file. OSC desktop notifications are not parsed as agent runtime events because arbitrary terminal output can forge them. Live polling of libghostty visible text remains best-effort for older/unconfigured panes and is not allowed to claim `.waiting`; that state requires an explicit runtime signal. The visible-text fallback is interpreted by `VisibleTextAgentStateReducer` so the privacy-sensitive terminal-text sample stays transient in the bridge and the durable decision rules remain testable in Core.

The side channel is a transport and state-ingestion contract, not a blanket
adapter trust decision. OpenCode and Pi file-drop integrations are explicit
opt-in runtime sources: setup paths alone do not enable probing or
runtime-event acceptance, newly spawned panes advertise enabled file-drop
provider sources as spawn-time metadata, and the app's live settings gate owns
runtime-event acceptance. Claude Code, Codex, and Grok provider-managed plugins
are trusted once events reach the pane-scoped sink. Plugin/extension/hook
installation is a separate user action. See
[ADR 0010](adr/0010-opencode-pi-opt-in-agent-integrations.md) and
[ADR 0017](adr/0017-grok-icon-only-agent-and-revived-rings-glyph.md).
Opt-in Claude Code configuration and richer per-agent adapters remain follow-up
work under INT-350, INT-351, and INT-352.

Shell activity is display-only chrome for shell sessions. It OR-folds per-pane prompt-marker readings from libghostty, debounces them to avoid flicker for quick commands, and maps busy shells to the visible `Running` label while leaving `AgentState` unchanged. Each pane must observe at least one prompt/idle marker before its own busy marker can affect chrome — tracked per pane (`shellPromptSeenPaneIDs`) — so a single pane with missing shell integration, or one stuck away-from-prompt, cannot force the whole session's chrome to `Running`. The debounce is deliberately a sustained-activity ("something big is running") indicator rather than a per-command one: `Running` surfaces only after the raw busy signal persists past `shellActivityBusyDebounceInterval` (250ms), so sub-threshold commands (`ls`, `cd`, `git status`) stay `Idle` by design (INT-333 decision A). Flipping to per-command semantics is a localized change — surface busy immediately on accepted submit and apply the debounce to the idle transition only. Quit confirmation still uses the raw immediate prompt-marker signal so close/quit safety does not wait for display debounce.

**Assistive technology**: `* → error` and detector-driven `error → non-error` transitions post `NSAccessibility.announcementRequested` at medium priority so VoiceOver users get an audible signal for state they can't see. The shell-exit `clearStaleErrorIfPresent` path announces `"Session error cleared."`. Recycling out of `.error` posts the combined `"Session error cleared. New shell started."` at high priority (matching the existing recycle announcement) to mirror the two-fold visual signal sighted users receive (red dot vanishes + fresh prompt). Terminal process-exit workspace close posts a high-priority `"Workspace closed. Terminal process exited."` announcement, or `"Workspace closed. Terminal process ended with an error."` when the close follows a fresh non-zero exit code. `error → needsAttention` is owned by the needs-attention surface (the dock-badge VoiceOver announcement covers it); the generic cleared message is suppressed for that transition specifically so VO users don't hear two announcements for one event. Other transitions out of `.error` are deliberate v1 silence: direct `markNeedsAttention` writes and `.error` restored from disk on app launch. Entering display `.waiting` via the runtime side channel (Claude Code's `idle_prompt` notification shape or turn-end `Stop`) posts a high-priority `"Agent waiting for your input in <session title>."`; `error → waiting` posts the combined `"Session error cleared. Agent waiting for your input…"` so neither fact is swallowed, and consecutive waiting events dedupe to one announcement. Known v1 limitation: a flapping detector could chain rapid entry/cleared announcements, and a chatty hook re-entering `.waiting` re-announces per cycle; the right layer to fix is detector/hook hysteresis, tracked separately.

Manual process-exit QA gate: on macOS, run `./script/build_and_run.sh` with the real libghostty-backed app. Verify `exit`, `Ctrl-D`, and `exit 7` in a single-pane workspace close the workspace without crash, speak the clean/error workspace-closed announcements, and allow `Cmd-Shift-T` reopen when eligible. In a split workspace, verify clean exit closes only that pane, non-zero exit leaves the sibling and speaks the existing sibling error announcement, the last remaining split pane closes the workspace with the new workspace-close announcement, and repeated close/reopen cycles show no console crashes or surface discard assertions.

Manual accessibility QA for `waiting`: VoiceOver should expose `Waiting` in the header/title bar, sidebar row labels, `AgentTile`, and any `AwPill` use. The pause glyph (INT-599 replaced the old prompt/caret bar) should remain distinguishable from idle/running/output — in both the full `AgentTile` badge and `StatusDot` — with Reduce Motion, Differentiate Without Color, Increased Contrast, and grayscale inspection enabled.

Debug smoke test for `waiting`: in DEBUG builds, the Workspace menu includes **Debug: Set Active Workspace Waiting**. It calls `SessionStore.setDebugAgentState(id:agentState:clearsAttention:)` for the selected workspace with `.waiting` and no unread delta. This is intentionally a manual visual/accessibility affordance only: it does not simulate Claude Code runtime detection, does not touch Ghostty viewport sampling, and should not produce notifications or quit-risk prompts.

To see the menu item, run a binary compiled with Swift's `DEBUG` condition. `script/build_and_run.sh` defaults to a release configuration for daily driving, so the normal `./script/build_and_run.sh` launch will not include this item. Options:

```sh
./script/build_and_run.sh debug
```

This builds debug and opens `lldb`; run the process from lldb to inspect it. For a clickable staged app without lldb, build debug, copy the debug binary into the staged bundle, re-sign, then open:

```sh
./script/build_and_run.sh
swift build -c debug
cp "$(swift build -c debug --show-bin-path)/awesoMux" dist/awesoMux.app/Contents/MacOS/awesoMux
codesign --force --deep --sign - --options runtime dist/awesoMux.app
open -n dist/awesoMux.app
```

## Notification policy

`WorkspaceNotificationPolicy` decides whether a `needsAttention` / unread transition produces a macOS notification. `WorkspaceNotificationTracker` consumes `.macOSNotification` when unread grows.

| Focus context | In-pane banner | Sidebar dot | Tab strip dot | Dock badge | macOS notification | Sound |
| --- | --- | --- | --- | --- | --- | --- |
| App focused, workspace selected | Yes | Yes | Yes | Yes | No | No |
| App focused, different workspace selected | Yes | Yes | Yes | Yes | List only | No |
| App backgrounded | Latent | Latent | Latent | Yes | Yes (banner) | Yes |

**Foreground presentation contract (INT-598):** while awesoMux is the active app, a needs-attention notification — including one for a workspace other than the selected one — is delivered to Notification Center's *list* only: no banner, no sound. The in-app chrome (sidebar dot, tab indicator, dock badge, VoiceOver announcement) already carries the signal, and a banner on top would double-announce for VoiceOver users. The policy still grants `.macOSNotification`/`.sound` for the focused/different-workspace context so the notification lands in Notification Center and a focus loss can upgrade a deferred banner; the quiet presentation is enforced by `WorkspaceNotificationBridge.foregroundPresentationOptions`, which is pinned by `WorkspaceNotificationForegroundPolicyTests`. The selected-workspace-active case stays non-interruptive by design.

**Per-workspace mute (INT-598):** each workspace's sidebar context menu offers Mute/Unmute Notifications. Mute gates only the interruptive channels — macOS banner, sound, and Dock bounce — while sidebar indicators, unread badges, and the dock-badge count keep firing: the user asked not to be interrupted, not to have state hidden. The flag lives on `TerminalSession.notificationsMuted`, persists in the local session snapshot (additive key, no schema bump), survives restore, and dies with the workspace (a reopened recently-closed workspace starts unmuted). Muted-era attention is swallowed, not deferred: unmuting does not retro-fire banners or Dock bounces for unread that accrued while muted. Muted workspaces are listed (and unmutable) in Settings → Notifications.

**Notification Center scope (INT-598):** `needsAttention` (and the background waiting/turn-completion unread path) is deliberately the *only* macOS Notification Center trigger. Agent `done` / `error` and process/backend errors stay on in-app surfaces plus VoiceOver announcements — completion is not an interruption, and error states already have loud in-app chrome. Revisit as an opt-in setting only if users ask for it.

**Permission remediation (INT-598):** Settings → Notifications shows the live macOS authorization state. When permission is denied, the pane explains that macOS only shows the permission dialog once and deep-links to System Settings → Notifications for awesoMux; the app never re-prompts on its own.

**Dock bounce (INT-634):** Dock bounce is a one-shot AppKit user-attention request, separate from the persistent Dock badge count. `WorkspaceDockBounceTracker` keys off the workspace rollup entering `.needsAttention`, not unread totals, so it does not repeat for an already-needy workspace and does not defer a foreground transition until later focus loss. The app requests an informational Dock bounce only while inactive, with output-attention, per-workspace mute, needs-attention delivery, and the Dock-bounce setting all allowing it. Because AppKit user-attention requests cannot be delegated to `UNUserNotificationCenter` Focus filtering, awesoMux suppresses Dock bounce while the user has **Respect Do Not Disturb** enabled rather than letting the Dock bypass that preference.

**Implemented vs scaffolding:** macOS notifications, dock badge, and attention-gated Dock bounce have live consumers. Sidebar indicators follow store state directly today; full routing through the policy for every channel is still future work. **Do Not Disturb** is delegated to `UNUserNotificationCenter` / system Focus for notification banners — the app does not re-implement DnD detection.

## Related decisions (index)

| Topic | Where |
| --- | --- |
| ADR process | [0001 — Record architecture decisions](adr/0001-record-architecture-decisions.md) |
| Close keybindings / session vs pane | [0002 — Window-close keybinding model](adr/0002-window-close-keybinding-model.md) |
| Notification acknowledgement dwell | [0003 — Acknowledge on selection dwell](adr/0003-acknowledge-on-selection-dwell.md) |
| SwiftPM-only; no checked-in Xcode project | [0004 — SwiftPM app without Xcode project](adr/0004-swiftpm-app-without-xcode-project.md) |
| Session restore file format | [0005 — Session persistence as JSON snapshot](adr/0005-session-persistence-json-snapshot.md) |
| Semantic waiting agent state | [0007 - Agent waiting semantic state](adr/0007-agent-waiting-semantic-state.md) |
| OpenCode and Pi provider opt-in | [0010 - OpenCode and Pi opt-in agent integrations](adr/0010-opencode-pi-opt-in-agent-integrations.md) |
| Ghostty app actions and awesoMux command ownership | [0020 - Ghostty app actions are not an awesoMux command surface](adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md) |
| Remote SSH workspaces: local `amx`, declared execution identity, SSH composition | [0023 - Remote workspace architecture](adr/0023-remote-workspace-architecture.md) |
| Sidebar single-host presentation | [0025 - Sidebar single-host presentation](adr/0025-sidebar-single-host-presentation.md) |
| Typed workspace-pane model, capabilities, live-vs-intent seam | [0026 - Typed workspace-pane foundation](adr/0026-typed-workspace-pane-foundation.md) |
| Ghostty submodule, XCFramework, linker, resources | [`docs/ghostty-integration.md`](ghostty-integration.md) |
| Ghostty XCFramework prebuilds, richer persistence | Open items in [`AGENTS.md`](../AGENTS.md) **Stack & decisions (open)** |

## What’s intentionally out of date in older notes

If another doc contradicts this file on **persistence** (JSON vs UserDefaults) or **whether libghostty is linked** (it is, via `GhosttyKit` + `GhosttyKitLinker`), treat **this document + `ghostty-integration.md`** as current.
