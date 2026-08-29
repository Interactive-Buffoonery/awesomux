# 0033 — Agent transcripts use exact provider identities

- **Status:** Accepted (amended 2026-08-28: the ingress repeats while a session runs — see Amendment)
- **Date:** 2026-08-16
- **Deciders:** Sarah
- **Issue:** [#297](https://github.com/Interactive-Buffoonery/awesomux/issues/297)

## Context

Agent transcript files are provider-owned, untrusted data. A working directory
is not a session identity: several agents and several sessions can share one
directory, so choosing the newest matching file can open or resume the wrong
conversation. Provider storage also differs: Claude Code, Codex, and Pi expose
JSONL files. OpenCode and Grok remain first-class agents for lifecycle chrome,
but they do not currently expose a transcript adapter awesoMux will ship.

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

Resolved files are opened through the secure descriptor reader. Rendering is
bounded, places transcript content in dynamically sized Markdown fences, and
writes a regenerable owner-only artifact. The document tab persists the typed
provider/session identity; it never derives Resume from transcript content or
from the terminal's current agent.

Resume stages, but does not submit, the provider's exact command:
`claude --resume`, `codex resume`, or `pi --session`.
It is allowed only beside a verified local shell prompt and rechecks after the
session-log probe before writing to the terminal.

## Consequences

- After `sessionEnd`, the live latch is cleared so a new lifecycle cannot inherit
  the old id. The ended session's exact identity is kept separately until the
  next `SessionStart`, so Open Agent Transcript can still resolve that file
  without guessing by working directory or sweeping other providers. OpenCode
  and Grok keep only the ended kind, so the command still names them after the
  pane becomes a shell.
- A pane that never reported a session id — including after relaunch, before
  the next hook — explains that no exact transcript is available instead of
  guessing.
- Remote transcripts remain unsupported because their logs and provider CLIs
  live on the remote host.
- OpenCode and Grok panes say their transcripts are not currently available.
  An OpenCode transcript adapter is follow-up.
- Adding another provider requires an explicit identity validator, transcript
  adapter, renderer mapping, and resume command rather than joining a generic
  filesystem scan.

## Amendment (#494, 2026-08-28): the ingress repeats, and so does the cache write

A mounted transcript tab re-renders itself as its session appends. The ingress
above is therefore a repeating one rather than a single resolve, validate,
render pass, and the decision holds per refresh rather than per open.

**Every refresh re-validates.** A refresh is a fresh `SecureFileReader.open`,
not a second read on the descriptor the first open returned. The mechanism
forces this rather than policy asking for it: `SecureFileReadHandle` anchors
every read to the length it validated at `open`, so a handle held across
appends is structurally incapable of seeing them. Re-opening consequently
re-runs the owner, regular-file, and symlink checks against whatever inode the
path names now, once per refresh, for as long as the tab keeps refreshing.

**Re-opening never widens what discovery resolved.**
`AgentTranscriptImporter.reopen` takes the typed `AgentTranscript` a previous
discovery produced and re-opens that value's resolved path, carrying its
provider kind and session id forward. It deliberately does not take a free
`(identity, URL)` pair: a pair lets a caller bind a validated session id to an
unrelated file that passes the same checks, which is the identity/content
decoupling this ADR exists to prevent, and the only way to hold an
`AgentTranscript` is a successful discovery. A refresh never sweeps, never
falls back to a working directory, and never re-enters discovery on its own.
Remote transcripts stay unsupported; nothing here follows a file over SSH.

Failures route by kind. An owner or regular-file refusal stops the loop,
because the same file fails the same way every time. A vanished or unreadable
path falls back to the full exact-identity discovery above, at most three times
per mount; past that the tab keeps its last good render, which is what a
transcript tab did before it refreshed at all.

Re-validation also pins the inode. Re-opening compares the new handle's device
and inode against the prior handle's and refuses a mismatch, routing it into
the discovery fallback above instead of rendering. Without that comparison a
same-uid writer could replace the file with another owner-owned regular file,
pass every check, and have its contents render under the original session's
identity. The one-shot ingress could be fooled the same way during its own
resolution; what changes under a repeating ingress is that the opportunity
recurs for as long as the tab refreshes rather than passing once, which is why
the comparison earns its place here and did not before. Legitimate rotation
fails the same check and takes the same fallback, so the guard costs nothing in
the ordinary case.

**The rendered artifact changes duration and completeness, not exposure
class.** `AgentTranscriptStore` already states what it holds: a plaintext copy
of whatever passed through the session, which routinely includes pasted
credentials, file contents, and command output. That copy used to be a
point-in-time snapshot of the transcript as it stood when the user asked for
it. It is now rewritten while the tab is the selected tab of its group in an
active window, so content pasted into the session after the tab was first
opened also reaches disk, where previously it might not have.

Nothing else about the artifact moves: the same `0o600` file in the same
`0o700` directory, the same atomic temp-and-rename into the same slot keyed by
the validated session id, the same prune schedule and the same retention rule.
The slot is replaced rather than appended to, so a tab that refreshes five
hundred times still holds one render. A refresh whose rendered bytes match what
this process last wrote to that path skips the write, so the rewrite rate
follows the transcript's content rather than the filesystem's event rate.
