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
JSONL files, while OpenCode stores sessions in SQLite. Grok remains a
first-class agent for lifecycle chrome but does not currently expose a
transcript adapter awesoMux will ship.

## Decision

awesoMux opens a transcript only after the pane reports a provider-native
session id. Every ingress validates and canonicalizes that id using the owning
provider's rules. There is no working-directory fallback and no cross-provider
sweep.

Transcript adapters are explicit:

- Claude Code and Codex resolve an exact filename beneath their configured
  session roots.
- Pi resolves the exact session-id suffix beneath `~/.pi/agent/sessions` (or
  its configured root). The prefix before `_<session-id>.jsonl` must not
  contain another `_`, so a longer id cannot match a shorter one.
- OpenCode opens `~/.local/share/opencode/opencode.db` read-only and selects the
  exact session primary key. It reads the live WAL through SQLite rather than
  copying sidecar files or invoking a CLI, bounds turns and parts in the query,
  and renders only the newest complete window. The fixed database path must be
  a regular file owned by the current user and cannot be a final symlink.

Resolved files are opened through the secure descriptor reader. Rendering is
bounded, places transcript content in dynamically sized Markdown fences, and
writes a regenerable owner-only artifact. The document tab persists the typed
provider/session identity; it never derives Resume from transcript content or
from the terminal's current agent.

Resume stages, but does not submit, a provider's exact command:
`claude --resume`, `codex resume`, or `pi --session`. OpenCode transcript
viewing does not imply a resume command; no OpenCode syntax is staged.
It is allowed only beside a verified local shell prompt and rechecks after the
session-log probe before writing to the terminal.

## Consequences

- After `sessionEnd`, the live latch is cleared so a new lifecycle cannot inherit
  the old id. The ended session's exact identity is kept separately until the
  next `SessionStart`, so Open Agent Transcript can still resolve that file
  without guessing by working directory or sweeping other providers. Grok
  keeps only the ended kind, so the command still names it after the pane
  becomes a shell.
- A pane that never reported a session id — including after relaunch, before
  the next hook — explains that no exact transcript is available instead of
  guessing.
- Remote transcripts remain unsupported because their logs and provider CLIs
  live on the remote host.
- Grok panes say their transcripts are not currently available.
- Adding another provider requires an explicit identity validator, transcript
  adapter, renderer mapping, and resume command rather than joining a generic
  filesystem scan.
