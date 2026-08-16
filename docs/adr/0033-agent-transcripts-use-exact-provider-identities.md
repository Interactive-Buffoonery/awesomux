# 0033 — Agent transcripts use exact provider identities

- **Status:** Accepted
- **Date:** 2026-08-16
- **Deciders:** Sarah
- **Issue:** [#297](https://github.com/Interactive-Buffoonery/awesomux/issues/297)

## Context

Agent transcript files are provider-owned, untrusted data. A working directory
is not a session identity: several agents and several sessions can share one
directory, so choosing the newest matching file can open or resume the wrong
conversation. Provider storage also differs: Claude Code, Codex, and Pi expose
JSONL files, while OpenCode provides a supported export command over its own
storage.

## Decision

awesoMux opens a transcript only after the pane reports a provider-native
session id. Every ingress validates and canonicalizes that id using the owning
provider's rules. There is no working-directory fallback and no cross-provider
sweep.

Transcript adapters are explicit:

- Claude Code and Codex resolve an exact filename beneath their configured
  session roots.
- Pi resolves the exact session-id suffix beneath `~/.pi/agent/sessions` (or
  its configured root).
- OpenCode runs `opencode export <session-id>` directly, with a 15-second
  timeout and a 32 MiB stdout limit. awesoMux does not read OpenCode's SQLite
  schema.

Resolved files are opened through the secure descriptor reader. Rendering is
bounded, places transcript content in dynamically sized Markdown fences, and
writes a regenerable owner-only artifact. The document tab persists the typed
provider/session identity; it never derives Resume from transcript content or
from the terminal's current agent.

Resume stages, but does not submit, the provider's exact command:
`claude --resume`, `codex resume`, `opencode --session`, or `pi --session`.
It is allowed only beside a verified local shell prompt and rechecks after the
session-log/export probe before writing to the terminal.

## Consequences

- A pane without a reported session id explains that no exact transcript is
  available instead of guessing.
- Remote transcripts remain unsupported because their logs and provider CLIs
  live on the remote host.
- OpenCode export bounds awesoMux's captured output and execution time, but the
  provider may still load its complete session internally before producing
  that output.
- Adding another provider requires an explicit identity validator, transcript
  adapter, renderer mapping, and resume command rather than joining a generic
  filesystem scan.
