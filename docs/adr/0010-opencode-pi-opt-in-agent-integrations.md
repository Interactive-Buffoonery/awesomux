# 0010 - OpenCode and Pi opt-in agent integrations

## Status

Accepted

## Context

OpenCode and Pi load in-process JavaScript or TypeScript extension files from
provider-owned plugin directories. Installing an awesoMux status file there is
therefore more sensitive than rendering passive UI: it changes what provider
processes execute whenever they run in a matching environment.

The existing runtime side channel is intentionally narrow and avoids terminal
content, but [ADR 0008](0008-privacy-boundaries-for-diagnostics-and-feedback.md)
still applies. Provider integration must be explicit, local, and reversible
because terminal sessions can contain prompts, commands, paths, environment
variables, proprietary code, and agent conversations.

## Decision

OpenCode and Pi integrations are disabled by default.

Provider setup paths are metadata only. Setting `binary_path` or `config_home`
does not imply consent and must not trigger probing, status checks, plugin
rendering, provider-directory writes, or runtime-event acceptance.

Each provider has two separate consent steps:

- Enable the provider in Settings. This allows awesoMux to validate paths,
  surface install status, and include the provider in
  `AWESOMUX_AGENT_ENABLED_SOURCES` for newly spawned panes.
- Install the provider file. This writes the awesoMux-owned plugin or extension
  file into the provider's global config home. Install is global-only; there is
  no project-local install target.

Runtime enforcement is required even after install. awesoMux must ignore
OpenCode and Pi runtime events unless the matching provider is currently
enabled. Newly spawned panes advertise enabled provider sources through
`AWESOMUX_AGENT_ENABLED_SOURCES` for diagnostics and legacy helpers, but the
running app's event-acceptance gate is authoritative. Bundled templates must not
treat that spawn-time environment value as consent because already-running panes
cannot receive environment updates after a user enables an integration.

Uninstall removes only manifest-owned awesoMux files whose contents still match
the rendered template. If the installed file was modified, awesoMux refuses the
automatic removal and shows the path for manual cleanup.

## Consequences

Existing configs that already contain OpenCode or Pi paths remain disabled until
the user opts in with `enabled = true`.

Disabling a provider takes effect immediately for runtime event acceptance. A
provider process may continue to invoke the local helper until restarted if it
inherited stale environment, but awesoMux ignores those events while disabled.

Claude Code and Codex runtime behavior is unchanged by this decision.
