# INT-110 implementation research — in-pane permission prompts

Research note (not an ADR). Captures what it would take to build INT-110
(in-pane permission cards for agent tool calls) given the current codebase and
the current Claude Code / Codex hook contracts. Prerequisite decision already
made: **Option A** — INT-110 owns the bidirectional permission channel; INT-500's
telemetry firewall stays intact.

Upstream issue/PR statuses and provider doc contracts last verified
**2026-07-02**. This note makes time-sensitive claims about four fast-moving
CLIs — re-check the cited issues before scoping against it.

## TL;DR verdict

Feasible, and **cleaner than the "new transport" framing implied** — a
**Claude Code + Codex v1** is on the table, gated behind a decision-return
channel that the repo already has most of the plumbing for.

Three facts move the estimate down:

- **Down:** Claude Code's `PermissionRequest` is a real **blocking** hook that
  returns a decision. We don't have to gate every tool call via `PreToolUse`.
- **Down:** Codex resolved upstream. openai/codex#15311 closed **completed**
  2026-04-22; a blocking `PermissionRequest` hook landed (PR #17563) and is
  documented, with the **same decision shape as Claude Code's**
  (`hookSpecificOutput.decision.behavior`). One gate-helper contract can
  plausibly serve both providers.
- **Down:** ADR 0011's `amx` command-bridge is already a bidirectional
  app↔pane channel. The decision-return path can likely ride it as a new
  message type instead of inventing IPC.

**Provider matrix (permission-channel ceiling):** Claude Code full three-action /
Codex full three-action pending an empirical contract check on the installed
CLI / OpenCode **blocked upstream** (`permission.ask` doesn't fire on the target
version) / Pi **deny-only** (`tool_call` returns `{block:true}`, no approval
return). See "OpenCode and Pi" below.

## The mechanism (external contract)

### Claude Code — the clean path

`PermissionRequest` is a **blocking** hook. When the permission dialog would
appear, Claude Code runs the hook and **waits** for it (command hook timeout
defaults to 600s). The hook returns a decision (official hooks docs):

```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
                          "decision": { "behavior": "allow" } } }
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
                          "decision": { "behavior": "deny" } } }
```

`behavior` is `allow` / `deny` — there is **no** `ask` value; falling through to
Claude Code's own prompt is done by returning *no decision*. `allow` may carry
`updatedInput` to rewrite the tool input. This is exactly the shape INT-110
needs: it fires only when permission is actually required, awesoMux can answer
on the user's behalf, and the "Always allow → auto-allow without prompting"
behavior is just returning `allow` without surfacing a card.

This is a **different field shape** from `PreToolUse` (which uses
`permissionDecision: allow|deny|ask|defer`). Only `PreToolUse` uses
`permissionDecision`; `PermissionRequest` uses `decision.behavior` — and Codex's
`PermissionRequest` hook now returns the **identical**
`hookSpecificOutput.decision.behavior` shape (see Codex below), so one
gate-helper decision contract can plausibly serve both providers. INT-110 binds
to `PermissionRequest`.

Contract status + caveats:

- The `decision.behavior` allow/deny contract is now first-class in the official
  hooks docs. Community writeups (ClaudeLog, claudefa.st) that earlier drafts of
  this note leaned on show a stale shape — a top-level `decision` object, an
  `ask` value, and `message`/`interrupt` fields on deny — treat those as
  historical. The hook post-dates INT-500, which is why the repo's side-channel
  doc still treats `PermissionRequest` as inbound-only.
- **Reliability wrinkle:** deny decisions from `PermissionRequest` were *ignored*
  in earlier Claude Code versions (anthropics/claude-code#19298 — auto-closed
  2026-03-05 as `not_planned` by the stale-bot, never confirmed fixed). Pin a
  minimum Claude Code version (installed at time of writing: 2.1.198) and add an
  integration test that a returned `deny` actually blocks, before trusting it.
- Claude Code does not always populate `notification_type` on permission
  notifications (anthropics/claude-code#11964), so the dedicated
  `PermissionRequest` hook — not the `Notification` subtype — is the load-bearing
  signal.

### Codex — landed upstream; verify the contract empirically

Codex `PreToolUse` shipped shell-only and deny-only (PR #15211), but has since
grown: it now fires for Bash, `apply_patch` edits (PR #18391), and MCP tool
calls (PR #18385), and can return `permissionDecision: "allow"` with
`updatedInput`. More importantly, the bidirectional story resolved upstream:

- **openai/codex#15311** ("Add blocking PermissionRequest hook for external
  approval UIs") — the request for exactly INT-110's use case — **closed
  completed 2026-04-22**. The blocking `PermissionRequest` hook landed in
  PR #17563 (merged 2026-04-17) and is in the official Codex hooks docs: it
  fires when Bash / `apply_patch` / MCP calls need approval, blocks, and
  returns the decision in `hookSpecificOutput.decision.behavior`
  (`"allow"` / `"deny"`, optional `message` on deny); returning no decision
  falls through to Codex's native approval flow. That is the **same shape as
  Claude Code's** `PermissionRequest` hook.
- The follow-on issues (#23465 "expose reviewer / support explicit defer",
  #28833 "approval signal for passive notifications") are still open — they
  refine the hook's ergonomics; neither blocks INT-110's three-action card.

Consequences for INT-110 scoping:

- Codex can join v1 on nearly the same shape as Claude Code — both providers
  return `hookSpecificOutput.decision.behavior`, so one gate-helper decision
  contract plausibly serves both.
- **Action:** the remaining check is empirical, not existential — run a
  `PermissionRequest` hook round-trip against the installed codex-cli
  (0.142.5 at time of writing, months past the April release) to confirm the
  documented allow/deny contract behaves, before committing scope. We already
  have `CodexAppServerClient` + `codex-app-server-initialize-handshake` notes
  to lean on.

### OpenCode and Pi — the other two providers

INT-110 is a permission-channel question, and awesoMux integrates four providers,
not two. OpenCode and Pi are the remaining two. The honest shape is **constrained,
not "both doable."** For an in-pane Allow/Deny card a provider must expose a hook
that fires *at the permission decision point* and can return **allow** (to
suppress the native prompt) as well as **deny**. Claude Code clears that bar
today; Codex clears it on paper pending the empirical check above.

| Provider | Can DENY from an awesoMux hook? | Can ALLOW / always-allow (suppress native prompt)? | Net for INT-110 v1 |
|---|---|---|---|
| **Claude Code** | Yes | Yes — `PermissionRequest` → `hookSpecificOutput.decision.behavior` | Full three-action card (above) |
| **Codex** | Yes (`PreToolUse` or `PermissionRequest`) | Yes — documented `PermissionRequest`, same shape as Claude Code (verify empirically) | Full three-action candidate (above) |
| **OpenCode** | In principle (`permission.ask` → `status:"allow"\|"deny"\|"ask"`) | **Not on the target version — hook doesn't fire** | **Blocked on upstream** |
| **Pi** | Yes — `tool_call` → `{ block: true, reason? }` | **No — deny-only, no `{allow}` return** | **Deny-only** |

#### OpenCode — blocked on upstream (not "immature")

- `permission.ask` is a real plugin hook whose contract is bidirectional: input
  `{ id, permission, patterns, metadata }`, output `status: "allow" | "deny" | "ask"`.
  On paper it is exactly the shape INT-110 wants.
- **But on the target version it does not fire.** Issue #7006 ("`permission.ask`
  defined but not triggered") is OPEN; #19927 shows the partial wiring is bypassed
  for first-encounter `needsAsk=true` commands — exactly the prompts that matter;
  PR #19453 (wire it back + add `message`) is still unmerged (all as of
  2026-07-02). awesoMux's OpenCode facts are baselined on **v1.17.x** — v1.17.8
  is the CI test-fixture baseline (`.github/actions/run-opencode/test/README.md`),
  not an enforced pin, and the locally installed CLI is v1.17.12, where the
  `permission.ask` hook type still exists (`packages/plugin/src/index.ts:261`).
  The `dev` branch has since diverged to a v2 Effect-based system — the live
  opencode.ai plugin docs now list `permission.asked` / `permission.replied`
  events instead of `permission.ask` — so a fix landing there does not
  automatically reach the version awesoMux targets.
- awesoMux's current OpenCode template already maps `permission.ask` → a synthetic
  `PermissionRequest` → content-free `attentionReason=permissionPrompt`
  (`Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template:53`).
  That is **attention only** — a badge, no body, no decision return.
- **Doable today:** nothing beyond the existing attention badge. **Gating fact:**
  in-pane approve/deny for OpenCode is blocked until `permission.ask` fires on a
  version awesoMux targets. Before scoping any OpenCode card, verify whether #19453
  merged and in which release.

#### Pi — deny-only

- Pi's extension API is `export default function (pi: ExtensionAPI)` with
  `pi.on("event", handler)`. The tool-gating hook is `tool_call` (fires after
  `tool_execution_start`, before execution, "can block"), and it returns **only**
  `{ block: true, reason? }`. There is **no** `{ allow: true }` / approval return and
  **no** dedicated permission-decision hook that suppresses Pi's native prompt
  (verified against `earendil-works/pi` `extensions.md`).
- Pi *does* ship a rich native permission UI (Allow Once / Allow Always / Reject /
  Reject with Reason) plus third-party config-driven extensions
  (`pi-permission-system`, `pi-permissions`). **That is Pi's own surface** — a
  competitor to the in-pane card, not something an awesoMux extension can drive to
  return "allow."
- awesoMux's current Pi template doesn't even emit `PermissionRequest`: it emits
  SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop / SessionEnd only
  (`Resources/AgentIntegrations/pi/awesomux-pi-status.ts.template:8`). So step one
  for *any* Pi permission signal is adding a `tool_call`-based emit.
- **Doable today:** a **deny-only** in-pane card (the extension vetoes via
  `block:true`), plus wiring an attention signal. A faithful three-action card is
  **not** achievable through the extension API; it would require Pi upstream to add
  an approve/suppress hook.

#### Two cross-cutting notes (fold in; don't fully design here)

1. **Transport reachability from interpreted plugins.** Claude and Codex gate
   through the compiled Swift `AwesoMuxAgentHook`. OpenCode and Pi hooks are
   **interpreted JS/TS plugins**, so the decision round-trip (ADR 0011's `amx`
   bridge, or the file-pair fallback) has to be reachable *from the plugin* — most
   naturally by the plugin calling a new **blocking** mode of the helper and awaiting
   its stdout decision. Noted as a shape, not designed here.
2. **Content-stripping inversion (ADR 0010).** ADR 0010 keeps the OpenCode/Pi side
   channel content-free — no command/tool text, per the ADR 0008 lineage. The card
   body needs exactly that content. This is the same "local UI, not egress" exception
   the Claude path already takes (see privacy note below), but for OpenCode/Pi it
   means **deliberately relaxing the ADR 0010 template content rule for the permission
   path only** — an explicit decision, the sibling of "break fire-and-forget for one
   mode."

**No named issue** covers OpenCode/Pi permissions (unlike INT-110). Open
question: should this become a sibling issue rather than riding INT-110?

## Why this is NOT a pure view over INT-500

INT-500's side channel (`docs/agent-runtime-side-channel.md`) is deliberately:

- **One-directional** — append-only per-pane JSONL, `AWESOMUX_AGENT_EVENT_FILE`.
  The app *reads*; the pane *writes*. No path to send a decision back.
- **Content-free** — the hook helper is forbidden from emitting command text,
  tool inputs, or file paths. `PermissionRequest` reaches awesoMux today only as
  `attentionReason=permissionPrompt`, `phase=notification` — a flag with no body.
- **Fire-and-forget** — `AwesoMuxAgentHook/main.swift` reads stdin, appends one
  line, `exit(status)` immediately. It never blocks, never emits stdout. An
  approval hook is the opposite: it must **hold** the process open and **write a
  decision to stdout**.

INT-110 needs the two things INT-500 refuses:

1. a **command/target preview** for the card body, and
2. a **decision-return path** (Allow/Deny back to the agent).

That's why Option A is real work, not a skin.

## Where the pieces land in this repo

### 1. A new blocking hook mode (helper) — net new

`AwesoMuxAgentHook` today is append-and-exit. INT-110 needs a second mode
(e.g. `--provider claude-code --gate` or a distinct `awesoMuxAgentPermission`
helper) that:

- reads the `PermissionRequest` payload (which **does** carry command/tool
  content — that's fine, it's for local UI, see privacy note below),
- forwards the request to the running app and **blocks** awaiting a decision,
- writes the `{"hookSpecificOutput":{"decision":{"behavior":...}}}` JSON to
  stdout and exits.

This is where the fire-and-forget invariant is deliberately broken, for this one
mode only. The telemetry mode stays append-and-exit.

### 2. The decision-return channel — reuse ADR 0011's `amx` bridge

Option A said "new transport," but the repo already has bidirectional app↔pane
IPC: **ADR 0011** — the `amx` command-bridge over a per-session unix socket
(`AmxBackend`, `AmxStatusChannel`, `AmxStatusFileWatcher`). `amx` is explicitly
described as "the out-of-band semantic channel" and the namespace for
awesoMux-specific subcommands. A permission request/response is a natural new
message type on that channel rather than a from-scratch transport.

- **If** the daemon bridge is live for the pane: the gate helper talks to the
  app via `amx`, app shows the card, app returns the decision.
- **Fallback** (no daemon): a request/response file pair in the awesoMux-owned
  runtime-event directory (already `0700`, per-pane `0600`) — the helper writes a
  request and polls for a decision file the app writes. Slower but self-contained.

Pin this transport choice before building; it's the single biggest cost driver.

### 3. The card UI — mounts on existing overlay anchors

`TerminalPaneView` already composes the surface inside a `ZStack` with
`.overlay {}` layers (drag/drop indicators live there). The permission card is a
new bottom-anchored overlay sibling — no impact on PTY sizing (overlays don't
participate in layout, per the existing comments). Visual spec is fully defined
in the issue (peach left edge, `--shadow-overlay-low`, header, mono command
preview, three actions).

DesignSystem tokens/atoms exist (`Sources/DesignSystem`); the card should be
built from them.

### 4. Keyboard focus vs. the Ghostty surface — the second-biggest cost

The issue requires `⏎` (allow once) / `⌘⏎` (always) / `esc` (deny) to work
**while the card is up**, keyboard-only. The libghostty `NSView` is normally
first responder and swallows all keystrokes into the PTY.

SwiftUI has the *handlers* (confirmed via Apple docs / Context7): `onKeyPress`
(macOS 14+), `keyboardShortcut(_:modifiers:)` for `⌘⏎`, and `onExitCommand` for
`esc`, plus `.focusable()` / `@FocusState`. But every one of these fires **only
when the view has focus** — and `NSHostingView.keyDown(with:)` is the AppKit
escape hatch when they don't. So the SwiftUI modifiers are the easy 20%; the real
work is the AppKit first-responder handoff: when a card appears, pull first
responder off the Ghostty surface to the card's hosting view, and restore it to
the PTY on dismiss, without the surface eating the keystrokes first. That's the
genuine risk, not the shortcut wiring. Prototype it early.

### 5. Trust model — settings surface already stubbed by INT-520

**INT-520 already shipped the settings scaffolding INT-110 assumed it would have
to build.** `AgentsSettingsPane` has a "Permissions" section, and
`AgentConfig` (`Sources/AwesoMuxConfig/AgentConfig.swift`) already persists:

- `permissionPosture`: `.askEveryTime` / `.rememberPerWorkspace` / `.trustKnownTools`
- `rememberToolTrust`: Bool (default true)

What's **missing** for INT-110's trust model:

- The per-`(workspace, tool, target-pattern)` **trust store** itself (the issue
  wants it in the workspace snapshot). `AgentConfig` today holds only the coarse
  posture toggle, not the tuple list.
- The **editable trust list UI** in Settings → Workspaces → Permissions.
- The optional **"Allow for session"** tier (trust until app/session ends).

So INT-520 gives the posture toggle + the surface; INT-110 adds the tuple store,
the list editor, and the session tier.

### 6. Edge cases (from the issue) → where they hit

- **Queued prompts stack, never auto-advance:** each blocking hook is its own
  held process. The app needs a per-pane (or global) queue model so multiple
  in-flight `PermissionRequest` gates render as a stack and resolve one at a time.
- **Deny → structured rejection:** returning `behavior:"deny"` already gives the
  agent a structured rejection it can retry against. Free from the contract.
- **Backgrounded app:** reuse the existing `needsAttention` → dock badge +
  notification path (INT-99 policy, `WorkspaceNotification*`).

## Privacy note (ADR 0008 — no real tension)

ADR 0008's "never capture command text / paths / prompt text" rule governs
**diagnostics that leave the machine** (product analytics, error reports,
feedback egress). INT-110 consuming the `PermissionRequest` command preview is
**local, in-process UI** that never leaves the device — a different concern.
INT-500's content-free rule is about keeping the *telemetry side channel* dumb,
not a blanket ban on the app ever seeing command text. So the gate helper reading
the command for the card body is consistent with both, as long as that content
is never routed into analytics/egress.

## Rough shape of the work (Claude Code v1; Codex joins behind the same contract)

1. **Prototype the risky seams first:** (a) a blocking `PermissionRequest` hook
   round-trip that actually returns `allow`/`deny` to Claude Code (then repeat
   the same round-trip against Codex — same decision shape), and (b)
   keyboard-chord routing to a SwiftUI overlay while the Ghostty surface is
   first responder. These two carry the schedule risk.
2. New gate helper mode (blocking, content-carrying, stdout decision).
3. Decision channel: extend `amx` bridge (primary) + file-pair fallback.
4. Per-`(workspace, tool, target)` trust store in the workspace snapshot +
   "allow for session" tier; wire to existing `permissionPosture`.
5. Card UI on `TerminalPaneView` overlay from DesignSystem tokens.
6. Trust-list editor in Settings → Workspaces → Permissions (extend the
   INT-520 Permissions section).
7. Queue model for stacked prompts; backgrounded-app notification via INT-99.

## Open decisions to settle before starting

- **Transport:** `amx` bridge as the decision channel vs. file-pair fallback vs.
  both. (Recommend both: bridge primary, file fallback.)
- **Codex v1:** the hook exists upstream (openai/codex#15311 closed completed
  2026-04-22; documented contract). What remains: empirically confirm the
  allow/deny round-trip on the installed codex-cli, and pin minimum provider
  versions (Claude Code and Codex) for the gate. (Recommend: include Codex in
  v1 unless the empirical check fails.)
- **Trust store location:** confirm workspace snapshot vs. `AgentConfig`. The
  issue says workspace snapshot; `AgentConfig` currently holds only the posture.

## Sources

- Claude Code hooks (permission decision contract, blocking `PermissionRequest`):
  https://code.claude.com/docs/en/hooks
- Claude Agent SDK permissions (`canUseTool`, evaluation order):
  https://code.claude.com/docs/en/agent-sdk/permissions
- `PermissionRequest` deny-ignored bug (auto-closed unresolved) + community
  writeup showing the stale decision shape:
  https://github.com/anthropics/claude-code/issues/19298 ,
  https://claudelog.com/mechanics/hooks/
- Codex hooks (blocking `PermissionRequest` contract; expanded `PreToolUse`):
  https://developers.openai.com/codex/hooks
- Codex blocking-approval request (closed completed 2026-04-22) + landing PR +
  scope-expansion PRs + open follow-ons:
  https://github.com/openai/codex/issues/15311 ,
  https://github.com/openai/codex/pull/17563 ,
  https://github.com/openai/codex/pull/18385 ,
  https://github.com/openai/codex/pull/18391 ,
  https://github.com/openai/codex/issues/23465 ,
  https://github.com/openai/codex/issues/28833
- SwiftUI key handling / focus (onKeyPress, keyboardShortcut, onExitCommand):
  https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)
- OpenCode `permission.ask` (defined-but-not-firing, first-encounter bypass, fix PR;
  contract cited from the versioned source — the live opencode.ai plugin docs have
  drifted to v2 and no longer document `permission.ask`):
  https://github.com/sst/opencode/issues/7006 ,
  https://github.com/sst/opencode/issues/19927 ,
  https://github.com/sst/opencode/pull/19453 ,
  https://github.com/sst/opencode/blob/v1.17.12/packages/plugin/src/index.ts#L261
- Pi extensions API (`tool_call` gating hook, `{block:true}` deny-only contract):
  https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md
- Internal: `docs/agent-runtime-side-channel.md` (OpenCode/Pi hook mapping),
  `docs/adr/0011-persistent-session-daemon-command-bridge.md`,
  `docs/adr/0010-opencode-pi-opt-in-agent-integrations.md`,
  `docs/adr/0008-privacy-boundaries-for-diagnostics-and-feedback.md`,
  `Sources/AwesoMuxConfig/AgentConfig.swift`,
  `Sources/awesoMux/Views/Settings/Panes/AgentsSettingsPane.swift`,
  `Sources/awesoMux/Views/TerminalPaneView.swift`,
  `Sources/AwesoMuxAgentHook/main.swift`,
  `Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template`,
  `Resources/AgentIntegrations/pi/awesomux-pi-status.ts.template`
