# Agent Runtime Side Channel

awesoMux exposes a per-pane runtime event sink so tools running inside the
terminal can update session metadata without relying on visible-text polling.

The protocol name is `awesomux-agent-v1`. Each event is one compact JSON object
written as a single JSONL line to the path in `AWESOMUX_AGENT_EVENT_FILE`.

```json
{"v":1,"source":"claude-code","kind":"Claude Code","execution":"thinking","phase":"toolStart","eventID":"abc123","timestamp":1790429673.123}
```

Supported environment variables:

| Variable | Meaning |
| --- | --- |
| `AWESOMUX_AGENT_EVENT_PROTOCOL` | Protocol name, currently `awesomux-agent-v1` |
| `AWESOMUX_SESSION_ID` | awesoMux session UUID |
| `AWESOMUX_PANE_ID` | awesoMux pane UUID |
| `AWESOMUX_AGENT_EVENT_FILE` | JSONL event file for this pane |
| `AWESOMUX_AGENT_HOOK` | Absolute path to the bundled helper; templates should prefer it over the bare command name |
| `AWESOMUX_AGENT_ENABLED_SOURCES` | Comma-separated file-drop provider sources enabled when this pane was spawned, such as `opencode,pi`. This is diagnostic/legacy metadata only; app-side event acceptance is the live consent source because child-process environments cannot be updated after Settings changes. |
| `AWESOMUX_AMX` | Absolute path to the bundled `amx` CLI (the persistent-session backend). Unset when the binary is missing — never a dead path. Restored panes keep the spawn-time value until their daemon dies, so re-check `-x` before use. Not part of the health check. See [amx automation](amx-automation.md). |
| `AWESOMUX_PROFILE` | Active runtime profile: `production`, `development`, or `development:<worktree-id>`. The app scrubs inherited values and injects its bundle-derived identity. Not part of the health check. |

Payload fields:

| Field | Required | Values |
| --- | --- | --- |
| `v` | Yes | `1` |
| `source` | Yes | `claude-code`, `codex`, `opencode`, `pi`, `grok`, `unknown`; unrecognized values are treated as `unknown` |
| `kind` | No | Existing `AgentKind` raw values, such as `Claude Code` |
| `execution` | No | Existing `AgentExecutionState` raw values, such as `thinking` or `waiting` |
| `attentionReason` | No | Existing `AttentionReason` raw values, such as `permissionPrompt` or `userInputRequired` |
| `state` | No | Existing `AgentState` raw values, such as `thinking` or `waiting` |
| `phase` | No | `sessionStart`, `promptSubmit`, `toolStart`, `toolEnd`, `notification`, `stop`, `sessionEnd`, `rename`, `open-document` |
| `title` | No | Pane title for a `phase=rename` event. A non-empty value pins the pane's title; an empty string resets it to the live terminal title; an absent `title` on a rename event is dropped. Only consumed for `phase=rename`. |
| `documentPath` | No | Absolute local Markdown path for a `phase=open-document` event. Only `.md` and `.markdown` paths are accepted. Relative paths, paths containing NUL, and events over the 4 KB line cap are dropped. |
| `touchedPath` | No | Absolute local Markdown file a Claude Code tool just wrote/edited, forwarded so it can be recorded into the pane's recent links (issue #175). Retained only on a `source=claude-code`, `phase=toolEnd` event; the parser strips it on any other source or phase, and on relative, non-Markdown, NUL-bearing, or bidi/RTL-scalar paths. Unlike `documentPath` it does not open a pane — it records a link the user can open from the palette. |
| `eventID` | No | Adapter-defined identifier, paired with `timestamp` for dedupe |
| `providerSessionID` | No | Provider-native session id, currently used to keep Grok child-agent lifecycle events from driving the parent tile |
| `timestamp` | No | ISO-8601 string or numeric Unix seconds (integer or float). Helper-generated timestamps are numeric Unix seconds with fractional precision; consumers should not require nanosecond precision. |

Unknown extra fields are ignored. Unrecognized `source` values parse as
`unknown`. Invalid JSON, unsupported versions, unknown `kind` values, unknown
`state` values, and lines over 4 KB are ignored.

The side-channel parser accepts broader `source` values such as `opencode`,
`pi`, `grok`, and `unknown`. The bundled v1 helper accepts `claude-code`,
`codex`, `opencode`, `pi`, and `grok`.

The bridge deduplicates events per-pane by the `(eventID, timestamp)` pair, so
adapters that reuse `eventID` counters across turns or restarts can emit valid
new events as long as the timestamp differs. Outside the lifecycle-boundary
handling below, events whose `timestamp` is older than or equal to the most
recently applied event for the same pane are also dropped, defending against
retries and out-of-order delivery. Future-dated timestamps are clamped to
"now" before being stored, so one bogus event can't poison the cache.

Lifecycle boundaries add an ordering guard that does not depend on timestamps.
When a pane receives `Stop`, then a newer `SessionStart`, a delayed
`SessionEnd` from the stopped lifecycle cannot reset the newer agent. Grok's
provider session id identifies the old end directly when present; providers or
events without stable session ids use the Stop/Start boundary. The newer
lifecycle's own `SessionEnd` still applies after its `Stop`, including when
timestamps are equal or absent.

The same arrival-order boundary protects a `SessionStart` that revives a pane
after a buffered `SessionEnd`: a delayed end from the prior lifecycle is ignored
until the restarted lifecycle emits its own `Stop`.

For Grok, a different-session `SessionStart` is still treated as a child and
dropped while the parent lifecycle is active. Once the parent has emitted
`Stop`, arrival order is authoritative: a different-session `SessionStart`
begins the next top-level lifecycle even when its timestamp is equal, absent,
or behind the prior watermark. The watermark itself never moves backward.

This lifecycle ordering state is runtime-only, like the rest of
`AgentRuntimeEventReducer`: closing, recycling, or restoring a pane clears it.
When a new bridge watch starts, it skips buffered activity but inspects the
bounded existing file for one terminal lifecycle truth: if the last valid event
is `SessionEnd`, that idempotent reset is applied before later appends are
drained. Once accepted, visible-text agent-state detection stays disabled until
a real `SessionStart`, so an initial zmx scrollback replay cannot recreate the
agent from stale TUI cues. A newer buffered lifecycle event prevents an older
`SessionEnd` from being applied.

### Pane rename (`phase=rename`)

A `phase=rename` event lets an in-pane process set that pane's title — e.g. an
agent naming the pane for the task it's working on:

```sh
echo '{"v":1,"source":"claude-code","phase":"rename","title":"My Backend"}' >> "$AWESOMUX_AGENT_EVENT_FILE"
```

A non-empty `title` pins the pane's title (it stops following the live terminal
title until reset); an empty `title` resets it to the live terminal title; an
absent `title` is dropped. A rename event must be title-only — if it also carries
`execution`/`attentionReason`/`state`, it is dropped rather than half-applied.
Rename events pass through the same `(eventID, timestamp)` dedupe + staleness
guards as state events, so a replayed or out-of-order rename can't overwrite a
newer title.

### Open document (`phase=open-document`)

An `open-document` event lets a process running inside a pane ask awesoMux to
open an auxiliary Markdown document pane in that pane's session:

```sh
"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" open-document --provider codex /tmp/notes.md
```

The helper validates the provider and path, generates an `eventID` and
timestamp, and appends a normal runtime event with `phase=open-document` and
`documentPath`. The app applies the existing live provider consent gate before
the store sees the event, then routes the request through
`SessionStore.openDocumentPane(fileURL:in:)` for the requesting session. This
event is document-only: it does not change agent kind, execution, attention, or
unread state. It still uses the same `(eventID, timestamp)` dedupe + staleness
guards as state and rename events, so a replayed request does not keep opening
new panes.

Only absolute local `.md` and `.markdown` paths are accepted at the event layer.
The eventual document read still goes through `DocumentURLValidator`, including
the 10 MB file-size cap.

### Touched path (`touchedPath` on `phase=toolEnd`)

Agent TUIs hard-wrap long file paths with real CR/LF, so a path printed to the
console can be split across grid rows that no link matcher can rejoin — the path
is un-hoverable and un-clickable (issue #175). To give an agent-written file a
route that does not depend on console text, the bundled helper reads
`tool_input.file_path` from a Claude Code `PostToolUse` payload and, for the
file-mutating tools `Write` / `Edit` / `MultiEdit`, forwards it as `touchedPath`
on the emitted `toolEnd` event. The app records that path into the pane's recent
links, where the command palette's **Open Recent Link** surfaces it and routes
Markdown to a document pane — the same path a hovered link would take.

Scope is deliberately narrow, and enforced at the trust boundary rather than
trusting the emitting helper:

- **Markdown only.** awesoMux's link-open routing is Markdown-only by design (a
  security fence so an OSC-8 link cannot launch a local executable), so only
  paths awesoMux can actually act on are surfaced. Non-Markdown agent-written
  files are out of scope until an "open non-Markdown files" capability lands.
- **Mutating tools only.** Files merely read (`Read` / `Grep` / `Glob`) are never
  recorded — only files a tool wrote or edited.
- **Claude Code only.** Codex and Grok are deferred until their tool payload
  shapes are verified.
- **Re-validated in `AgentRuntimeEvent.parse`.** A `touchedPath` is retained only
  on a `source=claude-code`, `phase=toolEnd` event; on any other source/phase it
  is stripped (the rest of the event still applies), so a same-UID process cannot
  forge one onto another phase. Relative, non-Markdown, NUL-bearing, and
  bidi/RTL-scalar paths are rejected, as are paths containing `#` (the recent-link
  open path strips it as a fragment, so the file could never open — a `?` is
  preserved and allowed). A wrong-typed `touchedPath` (array/number/object) or a
  too-long path that would exceed the 4 KB line cap strips only the field; the
  `toolEnd` lifecycle event still applies.
- **Recorded, not opened.** The path lands in the recent-links ring (session-only,
  not persisted; shared with hover-recorded links); the user decides when to open
  it. A `toolEnd` fires after the tool ran; awesoMux does not inspect the tool
  result, so the path reflects an attempted mutation.

A Claude Code `PostToolUse` payload embeds the full `tool_input` (a `Write`
carries the entire file `content`) plus `tool_response`, so the helper's stdin
cap is 1 MiB. A single write whose payload exceeds that is dropped whole (the
pre-existing oversized-input behavior); its path is not surfaced.

## App-Bundled Hook Helper

The app bundle includes a compiled hook helper at:

```sh
awesoMux.app/Contents/MacOS/awesoMuxAgentHook
```

Panes do not inherit the app bundle's `Contents/MacOS` directory on `PATH`, so a
bare `awesoMuxAgentHook` only resolves when the helper happens to be installed on
`PATH`. awesoMux therefore advertises the helper's absolute path in
`AWESOMUX_AGENT_HOOK`. In-app provider templates may fall back to the bare name
when that matches the provider's install mode.

### Grok plugin hooks (status as of Grok Build 0.2.x)

Grok's `awesomux-grok-status` plugin installs and validates cleanly, and the
helper accepts Grok payloads, but **Grok Build 0.2.x does not invoke plugin
lifecycle hooks** during interactive or `-p` turns (confirmed with a probe
plugin that logs every SessionStart / UserPromptSubmit / PreToolUse / Stop
with zero firings). Sidebar state for Grok therefore depends on:

1. Confident Grok identity + *live* Grok activity cues in the visible-text path
   (`Subagent running`, status/title `thinking…` / `- thinking -`). Past-tense
   `Thought for…` scrollback and the always-visible `ctrl+c:cancel` footer are
   intentionally ignored so the badge does not stick after the turn ends.
2. Allowing identity-only text → `.waiting` for Grok only, so sticky thinking
   can clear when live cues leave the viewport (hooks never send Stop today).
3. Suppressing shell `command-finished` → `.done` while the pane kind is Grok
   (tool subprocess exits must not paint a checkmark mid-turn).
4. Leaving Grok on the scraped attention path (`usesReliableAttentionHooks`
   false) until Permission hooks fire.

When Grok starts firing plugin hooks, the existing `hooks.json` + helper path
is the preferred source of truth; the text path remains a fallback.

Plugin hooks should invoke the helper with only the provider name and pass the
provider's native hook JSON on stdin:

```sh
AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}; "$AWESOMUX_AGENT_HOOK" --provider claude-code
AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}; "$AWESOMUX_AGENT_HOOK" --provider codex
"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" --provider opencode
"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" --provider pi
AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}; "$AWESOMUX_AGENT_HOOK" --provider grok
```

Document-open requests are the one helper verb that does not read provider JSON
from stdin:

```sh
"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" open-document --provider codex /absolute/path/to/file.md
```

The helper reads the top-level `hook_event_name`, with `hookEventName` accepted
for Grok's documented script payload shape, and for Claude Code notifications,
`notification_type`. For Grok it also preserves `session_id` as
`providerSessionID`, while continuing to accept `sessionId` payloads from older
local plugin installs and Grok's script-contract examples. It maps those fields
to the runtime event protocol, generates `eventID` and numeric Unix-seconds
`timestamp`, and appends one compact JSONL line to
`AWESOMUX_AGENT_EVENT_FILE`. It exits successfully and writes nothing to stdout
or stderr for unsupported providers, unknown hook events, invalid stdin, missing
environment, or append failures.

Hook mode does not create missing event files. awesoMux creates each pane's
event file before advertising the environment. The helper opens that existing
path without following symlinks, verifies it is a regular file owned by the
current effective user, and appends only after those checks pass. Symlinks,
directories, missing files, wrong-owner files, and other non-regular paths are
treated as silent append failures.

The app bridge applies the same descriptor-validation contract on reads: it
opens the event file with `O_NOFOLLOW`, verifies the descriptor is a regular
file owned by the current effective user, and parses bytes only from that
descriptor. Symlinks, directories, missing files, wrong-owner files, and other
invalid paths are not parsed as runtime events.

The bridge keeps its event-file dispatch sources armed while awesoMux is
inactive. Authoritative permission and turn-completion events must update the
workspace read model in the background so the notification policy can deliver
before the user reactivates the app.

Attention-only events omit `execution` so the runtime reducer can preserve the
current execution state while applying the attention overlay. Turn-end `Stop`
events carry `execution=waiting` without an attention overlay: the visible tile
rests directly on the waiting pause state, while Core handles unread/background
completion notification separately. Hook mappings do not emit `done`; terminal
process exit remains authoritative for held-pane completion and failure.

For hook-reliable agent kinds (`AgentKind.usesReliableHooks`) this channel is
the only producer of done state. For integrations that also ship reliable
attention hooks (`AgentKind.usesReliableAttentionHooks`), it is the only
producer of attention state. The visible-text fallback never applies the
corresponding scraped state because a subagent's transcript rendered in the
shared pane can echo completion or permission-prompt phrasing the scraper would
otherwise misread as the top-level agent needing the user (INT-714). Pi's
installed integration currently reports lifecycle only, so Pi and plain shells
keep scraped attention as a fallback.

### Read model

`AgentRuntimeEventReducer.decision()` turns a parsed `AgentRuntimeEvent` into a
`WorkspaceAttentionReducer.SessionUpdate`, applied per-pane by `updatePane()`.
Sidebar, search, and notification consumers do not read that transport-shaped
update directly; they read `SessionAgentRollup` (folded from per-pane
`PaneAgentSnapshot`s via `TerminalSession.agentRollup()`), the canonical
session-level read model for agent state.

Claude Code mapping:

| Claude hook | awesoMux event |
| --- | --- |
| `SessionStart` | `kind=Claude Code`, `execution=idle`, `phase=sessionStart` |
| `UserPromptSubmit` | `kind=Claude Code`, `execution=thinking`, `phase=promptSubmit` |
| `PreToolUse` | `kind=Claude Code`, `execution=thinking`, `phase=toolStart` |
| `PostToolUse` | `kind=Claude Code`, `execution=thinking`, `phase=toolEnd` |
| `SubagentStart` | `kind=Claude Code`, `execution=thinking`, `phase=toolStart` |
| `SubagentStop` | `kind=Claude Code`, `execution=thinking`, `phase=toolEnd` |
| `PermissionRequest` | `kind=Claude Code`, `attentionReason=permissionPrompt`, `phase=notification` |
| `Notification(notification_type=permission_prompt)` | `kind=Claude Code`, `attentionReason=permissionPrompt`, `phase=notification` |
| `Notification(notification_type=idle_prompt)` | `kind=Claude Code`, `execution=waiting`, `phase=notification` |
| `Notification` with missing/unknown `notification_type` | `kind=Claude Code`, `attentionReason=userInputRequired`, `phase=notification` |
| `Stop` | `kind=Claude Code`, `execution=waiting`, `phase=stop` |
| `SessionEnd` | `kind=Claude Code`, `execution=idle`, `phase=sessionEnd` |
| `StopFailure` | `kind=Claude Code`, `execution=error`, `phase=stop` |

`PermissionRequest` is the reliable source of permission attention. The
`Notification(notification_type=permission_prompt)` row is a best-effort
fallback only: Claude Code does not always populate `notification_type` on
permission notifications (see `anthropics/claude-code#11964`), so such a
notification can fall through to the missing/unknown row
(`attentionReason=userInputRequired`) instead. Treat the dedicated
`PermissionRequest` hook, not the notification subtype, as load-bearing.

This channel carries permission *attention* only — no command content and no
decision return. For what a bidirectional permission channel (in-pane
Allow/Deny cards, INT-110) would take on top of it, see
[`docs/reference/int-110-implementation-research.md`](reference/int-110-implementation-research.md).

Codex mapping:

| Codex hook | awesoMux event |
| --- | --- |
| `SessionStart` | `kind=Codex`, `execution=idle`, `phase=sessionStart` |
| `UserPromptSubmit` | `kind=Codex`, `execution=thinking`, `phase=promptSubmit` |
| `PreToolUse` | `kind=Codex`, `execution=thinking`, `phase=toolStart` |
| `PostToolUse` | `kind=Codex`, `execution=thinking`, `phase=toolEnd` |
| `SubagentStart` | `kind=Codex`, `execution=thinking`, `phase=toolStart` |
| `SubagentStop` | `kind=Codex`, `execution=thinking`, `phase=toolEnd` |
| `PermissionRequest` | `kind=Codex`, `attentionReason=permissionPrompt`, `phase=notification` |
| `Stop` | `kind=Codex`, `execution=waiting`, `phase=stop` |
| `SessionEnd` | `kind=Codex`, `execution=idle`, `phase=sessionEnd` |
| `StopFailure` | `kind=Codex`, `execution=error`, `phase=stop` |
| `Notification` | `kind=Codex`, `attentionReason=userInputRequired`, `phase=notification` |

`SessionEnd` resets the tile the way it does for every other provider: Codex
now shares the local-agent mapping, so a quit Codex session drops its glyph and
state back to shell instead of leaving a stuck agent tile that only the passive
idle-shell detector could clear. Because Codex shares that mapping, `Notification`
now resolves to a needs-attention event as well — but the shipped Codex
`hooks.json` does not register a `Notification` hook, so nothing emits it today;
it becomes live only if a future template (or a manual config) adds that hook.
`PreCompact`, `PostCompact`, and unknown Codex hook events remain silent in v1.

Grok mapping:

Grok uses a Claude-shaped hook envelope with CamelCase hook names. The helper
forwards no prompt or tool content; it reads only `hook_event_name` or
`hookEventName`, `session_id` or `sessionId`, and, for legacy stop events,
`reason`. `session_id` is awesoMux's preferred provider session key when present.
`sessionId` remains accepted so installed Grok script-contract payloads,
already-installed older plugins, and local test payloads do not break
immediately.

| Grok hook | awesoMux event |
| --- | --- |
| `SessionStart` | `kind=Grok`, `execution=idle`, `phase=sessionStart`, `providerSessionID=session_id` |
| `UserPromptSubmit` | `kind=Grok`, `execution=thinking`, `phase=promptSubmit`, `providerSessionID=session_id` |
| `PreToolUse` | `kind=Grok`, `execution=thinking`, `phase=toolStart`, `providerSessionID=session_id` |
| `PostToolUse` | `kind=Grok`, `execution=thinking`, `phase=toolEnd`, `providerSessionID=session_id` |
| `SubagentStart` | `kind=Grok`, `execution=thinking`, `phase=toolStart`, `providerSessionID=session_id` |
| `SubagentStop` | `kind=Grok`, `execution=thinking`, `phase=toolEnd`, `providerSessionID=session_id` |
| `PermissionDenied` | `kind=Grok`, `execution=error`, `phase=notification`, `providerSessionID=session_id` |
| `Notification` | `kind=Grok`, `attentionReason=userInputRequired`, `phase=notification`, `providerSessionID=session_id` |
| `Stop` | `kind=Grok`, `execution=waiting`, `phase=stop`, `providerSessionID=session_id` |
| `SessionEnd` | `kind=Grok`, `execution=idle`, `phase=sessionEnd`, `providerSessionID=session_id` |
| `StopFailure` | `kind=Grok`, `execution=error`, `phase=stop`, `providerSessionID=session_id` |

Grok emits hooks for child agents as well as the parent turn. The reducer latches
the parent Grok `session_id` at `SessionStart`, or at the first parent
`UserPromptSubmit` if a start hook was missed. Once latched, the id is sticky
until `SessionEnd`, and Grok events with a different `session_id` are dropped so
child lifecycle activity cannot flip the parent tile.

The mapper still accepts the older snake_case names, including
`permission_denied` and `stop(reason=end_turn)`, for compatibility with stale
installed plugins. New plugin renders use only current CamelCase hook keys.
Existing Grok processes should be restarted after repairing or reinstalling the
awesoMux Grok status plugin because a running Grok session may not reload
changed hook config.

OpenCode and Pi mapping:

OpenCode and Pi templates emit awesoMux-owned synthetic hook event names instead
of forwarding raw provider payloads. The helper maps those names identically for
both providers, using `kind=OpenCode` / `source=opencode` or `kind=Pi` /
`source=pi` as appropriate.

| Synthetic hook | awesoMux event |
| --- | --- |
| `SessionStart` | `execution=idle`, `phase=sessionStart` |
| `UserPromptSubmit` | `execution=thinking`, `phase=promptSubmit` |
| `PreToolUse` | `execution=thinking`, `phase=toolStart` |
| `PostToolUse` | `execution=thinking`, `phase=toolEnd` |
| `SubagentStart` | `execution=thinking`, `phase=toolStart` |
| `SubagentStop` | `execution=thinking`, `phase=toolEnd` |
| `PermissionRequest` | `attentionReason=permissionPrompt`, `phase=notification` |
| `Notification` | `attentionReason=userInputRequired`, `phase=notification` |
| `Stop` | `execution=waiting`, `phase=stop` |
| `StopFailure` | `execution=error`, `phase=stop` |

OpenCode and Pi templates must pass only these synthetic hook names plus
provider-only helper args. They must not pass prompt text, tool args, cwd, file
paths, model data, token/cost data, or raw provider payloads.

OpenCode and Pi events are accepted only when the matching file-drop provider is
enabled in awesoMux settings. Grok, like Claude Code and Codex, is
provider-managed and trusted once events reach the pane-scoped sink. The app
filters incoming file-drop provider events at apply time. Bundled templates do
not use `AWESOMUX_AGENT_ENABLED_SOURCES` as a consent gate because it is fixed
when the pane's child process starts and can be stale after Settings changes. See
[ADR 0010](adr/0010-opencode-pi-opt-in-agent-integrations.md).

OpenCode template:

- Source template:
  `Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template`
- Runtime destination: `~/.config/opencode/plugins/awesomux-opencode-status.js`
- Behavior: when awesoMux runtime-event environment is present, maps OpenCode
  events to the synthetic hook names above, then invokes
  `"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" --provider opencode` with only
  `{"hook_event_name":"..."}` on stdin.

OpenCode exposes two distinct surfaces, and the template uses both. Plugin **hook
keys** are registered by name; session lifecycle arrives through the generic
`event` catch-all keyed on `event.type`. The mapping (pinned to OpenCode plugin
API v1.x; the keys are version-specific):

| OpenCode surface | Name | Synthetic hook |
| --- | --- | --- |
| `event` type | `session.created` | `SessionStart` |
| hook key | `chat.message` | `UserPromptSubmit` |
| hook key | `permission.ask` | `PermissionRequest` |
| hook key | `tool.execute.before` | `PreToolUse` |
| hook key | `tool.execute.after` | `PostToolUse` |
| `event` type | `session.idle` | `Stop` |
| `event` type | `session.error` | `StopFailure` |

`session.status` is intentionally not used as the turn-start signal: it is a
state snapshot (`idle` / `busy` / `retry`), so `chat.message` carries
`UserPromptSubmit` instead.

Pi template:

- Source template:
  `Resources/AgentIntegrations/pi/awesomux-pi-status.ts.template`
- Runtime destination: `~/.pi/agent/extensions/awesomux-pi-status.ts`
- Behavior: when awesoMux runtime-event environment is present, maps Pi session,
  agent, and tool lifecycle events to the synthetic hook names above, then invokes
  `"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" --provider pi` with only
  `{"hook_event_name":"..."}` on stdin.

Grok plugin:

- Source plugin:
  `Resources/AgentIntegrations/grok/plugins/awesomux-grok-status/`
- Install path: managed by `grok plugin install` under `GROK_HOME`, defaulting to
  `~/.grok`.
- Behavior: Grok passes its native hook JSON on stdin. The hook config invokes
  the helper with `--provider grok`. The helper reads only lifecycle fields and
  drops prompt/tool payload details from the normalized event.

## Integration Installer State

User-selected OpenCode, Pi, and Grok setup paths live in the user config:

```toml
[agent_integrations.open_code]
enabled = true
binary_path = "/opt/homebrew/bin/opencode"
config_home = "/Users/example/.config/opencode"

[agent_integrations.pi]
enabled = true
binary_path = "/opt/homebrew/bin/pi"
config_home = "/Users/example/.pi/agent"

[agent_integrations.grok]
enabled = true
binary_path = "/Users/example/.grok/bin/grok"
config_home = "/Users/example/.grok"
```

All fields are optional. `enabled` defaults to `false`; `binary_path` and
`config_home` do not imply consent when `enabled` is absent or false.
`binary_path` names the provider executable the user wants awesoMux to show for
setup context. `config_home` names the provider's global config root; OpenCode
installs below `plugins/`, Pi installs below `extensions/`, and Grok passes it
as `GROK_HOME` to the provider CLI.

Generated rendered artifacts belong under the active runtime profile:

```text
~/Library/Application Support/awesoMux/AgentIntegrations/
```

For the primary checkout's development bundle
(`com.interactivebuffoonery.awesomux.dev`), the rendered state is under:

```text
~/Library/Application Support/awesoMux-dev/AgentIntegrations/
```

Linked worktree builds use
`~/Library/Application Support/awesoMux-dev-<worktree-id>/AgentIntegrations/`
instead. The provider targets are global, so the canonical file-drop and
CLI-managed install manifests are always:

```text
~/Library/Application Support/awesoMux/AgentIntegrations/install-manifest.json
~/Library/Application Support/awesoMux/AgentIntegrations/plugin-install-manifest.json
```

Install, repair, disable, and uninstall remain available in development builds.
All profiles read the same canonical records and serialize provider mutations
with a nonblocking cross-process lock. A render changes only its profile cache;
it does not rewrite global ownership. If no canonical manifest exists, awesoMux
imports the old `awesoMux-dev` manifest once. When both exist, production state
wins; use **Repair** to recanonicalize an integration last installed by an older
development build.

Manifest records are keyed by provider alone. Installs are global-only and
one-per-provider, so `binary_path` and `config_home` are attributes of that
single record rather than part of its identity; changing the config home moves
the install rather than creating a second record. When an install writes into a
provider directory, the manifest records the final installed path as
`installedPath`. Automatic uninstall removes only manifest-owned files whose
contents still match awesoMux's rendered template; modified installed files are
left in place for manual cleanup.

File-drop install destinations are:

```text
~/.config/opencode/plugins/awesomux-opencode-status.js
~/.pi/agent/extensions/awesomux-pi-status.ts
```

Grok uses its provider CLI instead of a direct file drop:

```sh
GROK_HOME=~/.grok grok plugin validate <rendered-plugin-dir>
GROK_HOME=~/.grok grok plugin install <rendered-plugin-dir> --trust
```

## Runtime Health Check

The app-bundled helper also supports an explicit diagnostic mode:

```sh
"${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}" --health-check
```

Health-check mode deliberately differs from hook mode. Hook mode stays silent
and exits `0` for ignored or failure inputs so it cannot break provider command
hooks. Health-check mode prints a diagnostic and exits nonzero when the runtime
environment is unusable.

The check validates:

- `AWESOMUX_AGENT_EVENT_PROTOCOL` is `awesomux-agent-v1`.
- `AWESOMUX_SESSION_ID` and `AWESOMUX_PANE_ID` are valid UUIDs.
- `AWESOMUX_AGENT_EVENT_FILE` names the current pane's
  `<AWESOMUX_PANE_ID>.jsonl` file.
- The event file exists, is a regular file, is owned by the current effective
  user, and can be opened for append.

A successful health check means the helper can safely append to the configured
JSONL file. It does not prove that the app consumed an event; there is no
acknowledgement mechanism in the v1 protocol.

Expected environment outcomes:

| Context | Expected health-check result |
| --- | --- |
| Plain local pane in awesoMux | Passes while the pane's runtime-event file exists and is writable. |
| `ssh` session | Usually fails with missing or stale environment; remote shells should not inherit a usable local event file. |
| `tmux` inside awesoMux | May pass if `tmux` preserves the current pane environment. A detached/reattached or long-lived server can fail with stale pane/file mismatch. |
| `sudo` | Usually fails with missing environment or wrong-owner/non-writable file depending on environment preservation. |
| Nested awesoMux session | The innermost awesoMux process should inject its own environment; inherited outer-pane values should fail as stale when the pane/file pair no longer matches. |

## Legacy Arg-Driven Hook Helper

The helper at `script/agent-hooks/awesomux-agent-event` appends one event when
`AWESOMUX_AGENT_EVENT_FILE` is present and exits quietly otherwise:

```sh
script/agent-hooks/awesomux-agent-event --source claude-code --phase toolStart --state thinking
```

Use the path relative to the current repository checkout, or install the helper
with an absolute path if the hook runner does not execute from the repo root.

Historical script-helper Claude Code mapping:

This table documents the deprecated `script/agent-hooks/awesomux-agent-event`
prototype, not the app-bundled `awesoMuxAgentHook` contract above. Current
helpers map `SessionStart` to `execution=idle`, and `Stop` to
`execution=waiting` without an attention overlay.

| Claude hook | awesoMux event |
| --- | --- |
| `SessionStart` | `kind=Claude Code`, `state=waiting`, `phase=sessionStart` |
| `UserPromptSubmit` | `kind=Claude Code`, `state=thinking`, `phase=promptSubmit` |
| `PreToolUse` | `kind=Claude Code`, `state=thinking`, `phase=toolStart` |
| `PostToolUse` | `kind=Claude Code`, `state=thinking`, `phase=toolEnd` |
| `Notification` | `kind=Claude Code`, `state=needsAttention`, `phase=notification` |
| `Stop` | `kind=Claude Code`, `state=waiting`, `phase=stop` |
| `SessionEnd` | `kind=Claude Code`, `state=done`, `phase=sessionEnd` |

OSC desktop notifications are not an agent runtime-event transport. Arbitrary
terminal output can forge notification title/body content, so awesoMux treats
desktop notifications only as ordinary output-attention signals. The JSONL
files under the awesoMux-owned runtime-event directory are the sole agent
runtime-event transport.

That directory is awesoMux-owned (`0700`) with per-pane `0600` event files, but
it is not authenticated against the pane's own processes: awesoMux injects the
event-file path as `AWESOMUX_AGENT_EVENT_FILE`, so a process running in a pane
can write events for its own pane, and a same-UID process can reach other panes'
files. The channel therefore trusts code already executing locally as the user —
a strictly higher bar than emitting terminal output, which is all the removed OSC
path required, but not cryptographic authenticity.
