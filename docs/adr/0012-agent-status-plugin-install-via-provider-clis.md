# 0012 — Agent-status plugin install via provider CLIs (Claude Code + Codex)

- **Status:** Proposed
- **Date:** 2026-06-25
- **Deciders:** eD, Sarah

## Context

[ADR-0010](0010-opencode-pi-opt-in-agent-integrations.md) established the consent
model for agent-status integrations — disabled by default, paths are metadata
only, enable and install are separate explicit steps, install is global-only and
reversible, and uninstall touches only awesoMux-owned files whose contents still
match the render. That ADR was written for **file-drop** providers: OpenCode and
Pi load an awesoMux-owned JS/TS extension that we install by copying one file into
a provider directory. [ADR-0008](0008-privacy-boundaries-for-diagnostics-and-feedback.md)
governs what the resulting side channel may carry (coarse status only — no
prompts, commands, paths, or agent content).

Claude Code and Codex are **CLI-driven**, not file-drop. Installing the awesoMux
status plugin means shelling the providers' own plugin CLIs (`claude plugin …`,
`codex plugin …`) and, for Codex, driving a `codex app-server` stdio JSON-RPC
session to read authoritative status and write enabled-state. This is a materially
larger capability surface than copying a file, and it does not fit the
file-drop installer as-is. The full command/RPC contract this ADR generalizes
lives in [`docs/agent-status-plugin-install-contract.md`](../agent-status-plugin-install-contract.md);
this ADR records the decisions, not the command-level detail.

The defining asymmetry between the two providers — and the reason this is not just
"two more entries in the existing installer" — is that **install does not mean
runnable**. Codex layers a per-hook **trust** model on top of install: it computes
a SHA-256 over each hook's normalized identity and runs the hook only if it is
both enabled *and* its current hash matches the stored `trusted_hash`. A freshly
installed Codex hook is inert until the user trusts it inside Codex. Claude Code
has no per-hook analogue; it trusts at the marketplace/plugin grain when the user
adds the marketplace and installs the plugin. This asymmetry is the origin of the
`Needs review` status and the hard rule that awesoMux never auto-trusts.

## Decision

1. **Structured CLI/RPC output is the source of truth; human-editable files are
   inputs, not parse targets.** Status is read from `claude plugin list --json` and
   the Codex app-server `hooks/list` RPC. `~/.claude/settings.json` and
   `$CODEX_HOME/config.toml` are treated as files the user may have hand-edited —
   never as the thing awesoMux parses to decide state. Rationale: the providers own
   their state shape; their CLIs are the only stable contract.

2. **Install is separate from trust, and awesoMux never trusts on the user's
   behalf.** awesoMux renders and installs behind an explicit confirmation, but it
   does not approve a Codex hook, does not flip a user-disabled plugin back on, and
   does not invoke a Claude in-session reload for the user. A successful Codex
   install therefore reports `Needs review` until the user trusts it in Codex.
   Rationale: trust is the user's security decision; carrying it for them would
   defeat the provider's gate. This extends ADR-0010's two-step consent model to
   CLI-driven providers.

3. **Bake the resolved helper path at render time, with an env-var fallback.** The
   rendered hook config carries the running bundle's absolute
   `Contents/MacOS/awesoMuxAgentHook` path, falling back to `${AWESOMUX_AGENT_HOOK}`.
   Rationale: Claude's `${CLAUDE_PLUGIN_ROOT}` resolves to the ephemeral plugin
   cache and cannot reach a helper that lives in the app bundle, and exec-form hooks
   do not expand shell env vars. A `dist/` development bundle triggers a warning
   (the helper disappears if that build folder is removed), and a moved/missing
   baked path surfaces as `Needs repair`.

4. **Render install manifests at install time rather than committing them to the
   bundle.** For Claude, awesoMux renders a single-plugin marketplace catalog
   (`marketplace.json` + `.claude-plugin/plugin.json`) around the bundled
   `hooks/hooks.json`; for Codex, it renders the plugin manifest that exposes the
   hooks and carries a `pluginId` for status matching. Rationale: rendering keeps a
   single source of truth with the OpenCode/Pi templates and lets the baked helper
   path (decision 3) live in a generated artifact instead of a committed one.

5. **`CODEX_HOME` is threaded into every Codex invocation and status read.** Unset
   resolves to `~/.codex`; awesoMux passes the same resolved home to every `codex`
   command and app-server session it intends to affect. A configured-but-missing
   home is reported as `Needs repair` (nothing is installed there), not as an error.
   Rationale: a mismatched home silently targets the wrong directory, so a status
   read would not see installs done under a different home.

6. **Runtime states with per-provider semantics.** Beyond installed/enabled/
   disabled, the resolver reports `Needs review`, `Needs repair`, and
   `Unsupported`. `Needs review` is Codex-specific (untrusted/changed trust hash);
   Claude reaches it only if a future CLI surfaces a marketplace-grain pending
   trust state. Live reload detection is deferred: reload/restart advice is shown
   as post-action guidance after install/enable/trust, not as a steady status.
   `Needs repair` covers manifest-claims-installed-but-disk-disagrees, including
   Codex trust-hash drift that is *our* render drifting rather than the user's
   change. `Unsupported` covers a missing CLI, a version without plugin/hook
   support, and Codex's `allow_managed_hooks_only` lockdown where our user hook is
   ignored entirely.

7. **The modified-file safety invariant carries over from ADR-0010.** awesoMux-owned
   files are removed or repaired only when on-disk content still matches the render;
   a user-modified file is surfaced for manual cleanup, never silently overwritten.
   Codex's trust-hash drift is the provider-native analogue of this same rule: a
   changed hash that reflects a user edit is `Needs review`, not an automatic
   re-render.

## Consequences

- **Privacy posture is unchanged.** ADR-0008 still bounds the side channel to
  coarse status; nothing in the CLI-driven install path reads or transmits prompt,
  tool, path, or transcript content. Install touches plugin/hook registration only.

- **New operational surface.** awesoMux now spawns provider CLIs and a Codex
  app-server from the app target, each with its own failure modes (spawn failure,
  non-zero exit with stderr, RPC unavailable). These must stay distinguishable —
  CLI-absent → `Unsupported`, CLI-present-but-errored → op failure with surfaced
  stderr, state-disagreement → `Needs repair` — and never collapse into one error.

- **Version-skew risk.** Older Codex without the `hooks/list` / `config/batchWrite`
  RPCs degrades to coarse present/absent status from `codex plugin list` text, with
  trust reported conservatively. The minimum Codex version that ships these RPCs is
  an open question to resolve during implementation (contract §4 #3).

- **Reload signal is deferred.** awesoMux currently shows Claude reload and Codex
  fresh-thread advice as post-action guidance rather than a steady status. Live reload
  detection can be revisited once there is a clean session-start signal to compare
  against install time.

- **Unblocks INT-520.** This installer/status service is the dependency the agent
  settings UI (INT-520) consumes to render Claude Code and Codex cards in place of
  today's `comingSoon` placeholders.

- **DEBUG-only diagnostics preview.** The plugin-card diagnostics disclosure is
  failure-only by design (it renders only when a failed op attached an
  `AgentPluginDiagnostics`), which makes it awkward to inspect during development.
  A `#if DEBUG` toggle in the Agents settings pane can inject a sample
  `AgentPluginDiagnostics` through the same `diagnostics(provider:)` gate the real
  path uses, so the production disclosure renders unchanged. It is compiled out of
  release builds, so regular users never see it. The sample deliberately carries a
  `$HOME`-prefixed executable path and long stderr to exercise the `~` redaction
  and length cap [ADR-0008](0008-privacy-boundaries-for-diagnostics-and-feedback.md)
  requires. Note that `script/build_and_run.sh` defaults to release (which strips
  the toggle); use `--debug`, or `swift build`/`swift test`, to see it.

Status stays **Proposed** until the runner PRs implementing this contract land.

## Addendum: instruction injection (INT-684)

- **Date:** 2026-07-05
- **Deciders:** eD, Sarah

### Context

The markdown document pane teaches agents the document/annotation convention —
the `<mark>…</mark><!-- USER COMMENT N: … -->` review-comment lifecycle plus the
`"$AWESOMUX_AGENT_HOOK" open-document` invocation — only through the one-shot
nudge string composed by `NudgeComposer`. For that knowledge to be durable, each
provider's shipped integration must carry it. Claude Code's shape was already
decided (a skill inside the bundled plugin tree); Codex, OpenCode, and Pi were
deferred pending verification of their injection mechanisms against current
docs. This addendum records those three decisions.

### Decision

**All four providers receive the convention as a skill (`SKILL.md`), never as
hook-based prompt injection, installed per provider.** Skills are loaded lazily
(name/description up front, body on demand), carry no per-session token cost,
and — unlike Codex hooks — no trust gate, so an installed skill is immediately
usable rather than inert until reviewed. Per-provider installation preserves
ADR-0010's per-provider consent and uninstall model: enabling or removing one
provider's integration never changes what another provider sees.

1. **Claude Code** (restating the prior decision for completeness):
   `skills/awesomux-documents/SKILL.md` inside the bundled
   `awesomux-claude-status` plugin tree. The installer already copies the whole
   plugin tree, so this requires no installer changes.

2. **Codex:** the install-time-rendered `plugin.json` for
   `awesomux-codex-status` gains `"skills": "./skills/"`, and the rendered
   plugin directory ships `skills/awesomux-documents/SKILL.md` alongside
   `hooks/hooks.json`. The Codex `plugin.json` spec documents the `skills`
   manifest field, and plugin-provided skill roots are part of Codex's skill
   discovery. Rejected: SessionStart hook `additional_contexts` output — it
   injects the full text into every session (token cost with no lazy loading)
   and rides the hook trust model, so it would be inert until the user trusts
   the hook (`Needs review`), which a skill sidesteps entirely.

3. **OpenCode:** file-drop
   `~/.config/opencode/skills/awesomux-documents/SKILL.md` as a second
   awesoMux-owned file under the existing ADR-0010 file-drop install/uninstall
   invariants. OpenCode documents this global skills location (alongside
   Claude-compatible and agent-compatible paths). Rejected: writing the
   `instructions` array in `opencode.json` — that hand-edits a human-owned
   config file, against decision 1's "human-editable files are inputs, not
   parse/write targets"; and plugin-hook injection — OpenCode plugins expose no
   stable system-prompt hook (only `experimental.session.compacting` context
   push and the SDK's `noReply` prompt injection exist today).

4. **Pi:** file-drop `~/.pi/agent/skills/awesomux-documents/SKILL.md`. The
   global agent directory needs no per-project trust prompt (project-local
   skill locations do). Rejected: appending to the system prompt from the
   status extension via `before_agent_start` — always-on token cost, and it
   would entangle instruction content with the status side channel ADR-0008
   deliberately keeps narrow; skills are Pi's documented mechanism for durable
   agent knowledge.

**Rejected globally: a single shared drop into `~/.agents/skills/`.** Codex,
OpenCode, and Pi all honor that cross-agent location, so one write could cover
all three — but it couples consent and uninstall across providers (removing the
file for one provider removes it for all), breaking ADR-0010's per-provider
model and the manifest-ownership story.

### Provider-specific limitations and invariants

- The skill body's single source of truth is
  `NudgeComposer.commentConventionSummary` (introduced by the markdown-pane
  agent-integration track), with a test asserting each shipped resource
  contains it, so the nudge and the shipped skills cannot drift.
- The Codex skill rides the rendered manifest — decision 4 above (render
  install manifests at install time) already covers it; the render step also
  copies the skill directory.
- The OpenCode and Pi skill files extend the ADR-0010 file-drop manifest; the
  modified-file safety invariant (decision 7) applies to them: a user-modified
  `SKILL.md` is surfaced for manual cleanup, never silently overwritten.
- Runtime verification is a named follow-up per provider (tracked from
  INT-684): the minimum Codex version with plugin `skills` manifest support;
  whether OpenCode's `permission.skill` defaults allow the skill without extra
  config; and confirming Pi's global-skill load prompts for nothing.
