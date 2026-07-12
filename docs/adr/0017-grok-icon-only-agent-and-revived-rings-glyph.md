# 0017 - Grok agent integration and revived rings glyph

## Status

Accepted, amended by INT-731 and the native Grok plugin follow-up.

## Context

Grok (xAI's Grok Build, launched as the `grok` terminal coding CLI) is a coding
agent in the same shape as Claude Code and Codex: the user runs it in a pane.
Adding it raised two decisions the existing ADRs did not cover.

First, the integration model. At the time this ADR was accepted, opt-in
providers so far shipped a status-reporting install: Claude Code and Codex install
a provider-CLI plugin/hook
([ADR 0012](0012-agent-status-plugin-install-via-provider-clis.md)), and OpenCode
and Pi drop a status extension file
([ADR 0010](0010-opencode-pi-opt-in-agent-integrations.md)). The original
decision assumed Grok Build shipped no hook or plugin mechanism, so that install
model had nothing to install for it. Grok also authenticates through its own
first-run browser OAuth, so awesoMux needs no API-key or environment wiring to
launch it.

Second, the glyph. [ADR 0016](0016-agent-icon-family-provider-tints.md) had just
retired the three-overlapping-rings shape from Codex because, in Codex's context,
it read as a hazard/biohazard symbol, and replaced it with a cloud. The product
owner asked for that exact ring mark as Grok's icon.

## Original Decision (Superseded In Part)

Grok was added as an `AgentKind` (`Sources/AwesoMuxCore/Models/AgentKind.swift`)
and drawn with the `AwAgentIcon.grok` glyph. The original decision deliberately
kept it out of the status-hook integration families:

- No `AgentPluginProvider` / `AgentIntegrationInstallProvider` case, no bundled
  marketplace/extension tree, no provider-CLI install, no
  `AWESOMUX_AGENT_ENABLED_SOURCES` source, and no launch/environment/API-key
  plumbing.
- Grok's Settings entry (under Agents, below Pi) is a plain toggle, not an
  install card. It persists as `AgentIntegrationsConfig.grok.enabled`; only
  `enabled` is read. Turning it on has exactly one effect: a text-detected
  `grok` session is allowed to adopt the Grok kind and therefore show the Grok
  sidebar icon. Turning it off strips the detected kind at the surface-view call
  site, so no Grok icon appears. The toggle promises only what it does.

Grok's glyph revives the retired three-ring shape as its own `GrokGlyph`, tinted
`green`. This is a deliberate exception to ADR 0016's "no shape that reads as a
real-world sign" rule. The mitigation: the hazard reading was specific to Codex's
framing; as Grok's green identity mark, adjacent to Codex's now-distinct
lavender spiral, the rings carry no false connotation, and ADR 0016's cross-provider
ambiguity concern does not arise (different shape and different tint from every
other provider).

## Original Consequences (Superseded In Part)

- Grok sessions never report live running/done/needs-attention state, because
  there is no hook. The icon is identity-only. If Grok Build later ships a hook
  API, a follow-up ADR can supersede this and promote Grok into the plugin
  family.
- The Grok Settings row is intentionally thinner than the install cards above
  it. That asymmetry is the honest signal that it does less, not a layout bug.
- ADR 0016's glyph table gains a Grok row (rings / `green`); the rings are no
  longer a retired shape but a reassigned one.
- Grok's exact headless auth environment variable and a potential `grok` binary
  name collision with third-party CLIs are not addressed here, because awesoMux
  adds no launch wiring. They become relevant only if a future ADR expands Grok
  into a full integration.

## Amendment (INT-731, 2026-07-06): Grok now has lifecycle hooks

The original integration decision was based on the assumption that Grok Build
had no usable hook mechanism. INT-731 superseded that part of the decision:
Grok exposed a global `~/.grok/hooks/*.json` lifecycle-hook system with a
Claude-shaped payload envelope and snake_case event names.

Grok is now an installable file-drop integration, like OpenCode and Pi:

- Settings renders Grok as a local status hook card.
- The bundled template installs to `~/.grok/hooks/awesomux-grok-status.json`.
- `AgentIntegrationsConfig.grok.enabled` gates both the hook event acceptance
  path and pre-hook text identity.
- `AgentRuntimeSource.grok` is a real runtime source.
- `AgentKind.grok.usesReliableHooks` is true, so visible-text `.done` cues must
  not override Grok's hook-owned lifecycle.

The INT-731-era hook payloads also carried provider session ids. The reducer
latched the parent `sessionId` at `session_start`, or at the first parent
`user_prompt_submit` if a start hook was missed. The latch stayed sticky until
`session_end`; Grok events whose later `sessionId` differed were dropped so child
lifecycle hooks could not drive the parent tile. `stop(reason=end_turn)` was the
normal turn-end path; cancel, error, shutdown, missing, and unknown reasons
mapped to error stops.

The glyph decision is unchanged: Grok keeps the revived green rings mark from
this ADR and ADR 0016.

## Amendment (2026-07-09): Grok uses its native plugin CLI

The INT-731 file-drop decision is superseded by the current Grok CLI. Grok now
ships a native `grok plugin` surface with local plugin install, validation,
enable/disable, uninstall, and JSON listing commands.

Grok remains a first-class runtime source, but its Settings card now follows the
same provider-CLI plugin family as Claude Code and Codex:

- The bundled integration is a Grok plugin tree at
  `Resources/AgentIntegrations/grok/plugins/awesomux-grok-status/`, with a
  `.grok-plugin/plugin.json` manifest and hook config.
- awesoMux installs it through `grok plugin validate <plugin-dir>` followed by
  `grok plugin install <plugin-dir> --trust`.
- awesoMux passes the configured Grok config home as `GROK_HOME`; if unset, the
  CLI default is `~/.grok`.
- Status reads use `grok plugin list --json`. Current Grok versions report
  installed plugins but do not reliably expose disabled state in that JSON, so
  awesoMux treats the JSON list as authoritative when it does report a disabled
  state and otherwise reports the installed plugin as enabled.
- Current Grok hook names are Claude-style CamelCase events such as
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionDenied`, `Stop`,
  and `StopFailure`. Hook payloads use `session_id` for the provider session id
  when present. The helper still accepts `sessionId`, Grok's `hookEventName`
  payload key, and snake_case hook names from stale local plugin installs, but
  new plugin renders should use only current CamelCase keys.
- `Stop` is the current normal turn-completion signal and maps to waiting even
  when Grok omits a `reason`; `StopFailure` maps to error.

OpenCode and Pi remain direct file-drop integrations. Grok is no longer one of
them.
