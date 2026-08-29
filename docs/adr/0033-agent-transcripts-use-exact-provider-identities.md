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
`AgentTranscript` is a successful discovery.

`reopen` is therefore narrow by construction — it never sweeps, never falls
back to a working directory, and can only succeed on the one path it was
handed. The loop around it is what re-enters discovery, and only by the same
exact-identity route the Decision describes: same validator, same adapter, same
absence of a working-directory fallback. Remote transcripts stay unsupported;
nothing here follows a file over SSH.

Failures route by kind. An owner, regular-file, or size refusal stops the loop,
because the same file fails the same way every time. A vanished or unreadable
path enters event-driven recovery. The loop arms a vnode watcher on the prior
session directory before one catch-up discovery, then authorizes at most one
full exact-identity discovery per delivered directory event. This closes the
recreation race without spending the whole budget synchronously or adding a
timer. Before the first pin, the equivalent watcher is armed on the provider's
transcript search root.

A failed cache write takes a different path. The source is still pinned and
the exact-file watcher stays armed, so the next source event retries the write
without rediscovery. It neither charges nor resets the source-recovery budget.
If the failed write follows the session's final append, there is no later event
to retry it and the tab remains stale; recovery deliberately has no timer.

Failed exact-identity recovery attempts are charged against a budget of three
*consecutive* failures. Only a render that lands clears the count, so a long
session that recovers from three unrelated transient blips keeps refreshing
rather than spending a lifetime allowance on them. The budget also belongs to
one loop rather than to the tab: a window going inactive and active again ends
one loop and starts another with a fresh count. "Three" bounds a run of source
recovery failures within a loop generation, not a mount. At three the loop
stops and the tab keeps its last good render, which is what a transcript tab did
before it refreshed at all.

Re-validation also pins the inode, and it is worth being exact about what that
buys. Re-opening compares the new handle's device and inode against the ones
discovery bound the session id to; a mismatch reports `.notFound`, which routes
into the discovery fallback above rather than rendering. The pin does not
refuse substitution outright — the next pass rediscovers, and discovery may
well accept the replacement, subject to the provider's exact-filename rule and
the conversation-record check it applies to every candidate. What the pin
forbids is the silent case: a replacement file rendering under a session id
that was validated against a different inode, without re-passing the admission
checks the first open had to pass. A one-shot ingress could be fooled during
its own resolution too; what changes under a repeating one is that the
opportunity recurs for as long as the tab refreshes, which is why the
comparison earns its place here and did not before. Legitimate rotation takes
the same route and is accepted the same way, so the pin costs a rediscovery in
the ordinary case and nothing else.

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
hundred times still holds one render. A refresh skips the write when the slot
already *is* a `0o600` file whose current contents hash to the new render —
read back through the same owner-only ingress the write uses, not compared
against a record of what this process last wrote. Asking the file rather than a
memo is what lets a prune between two refreshes be repaired instead of skipped
past, and what keeps a slot left at a wider mode from being accepted as
already-correct. The rewrite rate therefore follows the transcript's content
rather than the filesystem's event rate.
