# 0032 — Agent transcripts are rendered artifacts with typed provenance

- **Status:** Accepted
- **Date:** 2026-08-15
- **Deciders:** eD
- **Issue:** [#297](https://github.com/Interactive-Buffoonery/awesomux/issues/297)

## Context

Claude Code and Codex both write their conversation to a JSONL log on disk, and
both report the session id naming that log through the agent runtime side
channel. **Open Agent Transcript** (⌥⌘T) turns that into a reading surface: it
resolves the session running in a pane to its log, renders a window of it to
Markdown, and opens it in a document tab beside the terminal, with a Resume
control that stages the provider's resume command into that terminal.

Four properties of the surrounding system make the obvious implementation of
each step wrong, and none of the four is visible from the code that would be
written instead:

- The side channel is **same-UID writable** and, on the bridge path, remote-host
  writable. Codex supplies `transcript_path` — an absolute path — on every hook
  event, so the easiest resolution is also the one that takes an attacker's path.
- Document panes already have a read-only concept, `isReadOnlySnapshot`, which
  means *remote provenance* and is folded across a whole tab group
  (`WorkspacePaneCapabilities.documentGroup`'s `anyRemote`). It is the obvious
  switch to reuse and reusing it breaks unrelated tabs.
- A pane outlives the agent session whose transcript is open beside it, so
  anything that asks the pane "which session?" answers with whatever is running
  *now*.
- The document pane is locked to TextKit 2 ([ADR 0018](0018-markdown-doc-pane-stays-textkit2.md)),
  which never evicts layout fragments — roughly 138 MB resident per MiB laid
  out. Transcripts on this machine reach 27 MB (Claude) and 196 MB (Codex), and
  one measured single JSONL line was 57 MB.

## Decision

**Resolve by validated-UUID glob, never by the reported transcript path.** The
session id is validated as a UUID at every ingress
(`AgentHookCommand`, `AgentRuntimeEvent.parse`, `BridgeEnvelope.Wire`), and both
providers name the log file after that id — a Claude transcript filename *is*
the session id, and Codex's rollout filename ends in it. `AgentTranscriptImporter`
therefore globs the provider's own root, resolved through
`AgentIntegrationsConfig` rather than a hard-coded `~/.claude` / `~/.codex`, and
opens the match through `SecureFileIO` in the same operation, so there is no bare
URL for a symlink swap to land in between. Codex's `transcript_path` and `turn_id`
are read by nothing. Duplicate basenames exist in practice (a worktree relocation
leaves a same-named stub with no conversation records), so the tie-break is on
content — the candidate holding real records, newest mtime breaking a remaining
tie — not on the pane's working directory, which picks the stub. When *no*
candidate shows a conversation the tie-break is size, not mtime: the head window
cannot always see a real transcript's first turn, and a stub is rewritten on
every relocation, so mtime reliably picks the 1.4 KB stub over the 14 MB
session.

With no reported id, resolution falls back to the newest transcript recording the
pane's working directory, and says which of the two paths produced the result —
`AgentTranscriptOpener` turns a fallback into a sentence in the document's own
chrome, because a directory match is a guess and must not read as a certainty.
That scan is scoped before it is bounded: Claude's project directory is named
after the working directory, so the pane's own project is searched first and the
full root only if it misses; Codex records the directory inside the file, so its
tree is scanned whole under a byte budget with a smaller per-candidate probe. The
fallback also skips session ids already latched to *other* panes — two panes in
one directory both match on `cwd`, and the neighbour's transcript is newer
precisely because its agent is writing to it.

`AgentTranscriptIdentity` re-runs the UUID gate and an explicit provider
allowlist, so the Grok exemption in `validatedProviderSessionID` (documented in
[the side channel](../agent-runtime-side-channel.md#provider-session-id)) cannot
reach a path or a staged command through this feature even if a future caller
forgets.

**Provenance is typed and lives on the document; editability is its own flag.**
A transcript tab carries an `AgentTranscriptIdentity` (provider + UUID, validity
as a construction invariant, re-validated on decode). Read-only is a **separate**
derived `DocumentPane.isEditable` — `remoteResourceIdentity == nil &&
agentTranscriptIdentity == nil` — and only the write/navigate call sites moved
onto it. `isReadOnlySnapshot` still means remote provenance and nothing else.

**Rendered transcripts persist and are reference-pruned.** The rendered `.md`
lives in an owner-only cache (`0o600` in `0o700`, via
`FileManager.validatedOwnerOnlyDirectory`, never `NSTemporaryDirectory()`), named
after a hash of provider + session id, suffixed `.transcript.md` so an
app-authored file never occupies a user-content slot. It is retained exactly as
long as a live **or recently-closed** document tab references it, and the first
prune after that deletes it. One collector walks `groups` and `recentlyClosed`
once for both generated-document caches.

**The byte budget is enforced above the pane, during accumulation.** The renderer
reads the *tail* of the log through a descriptor-backed bounded read, walks
records newest-first into a budget derived from the document pane's own
`DocumentURLValidator.maxFileSizeBytes` (three quarters of it, so the two
cannot drift), and reverses. A record over the 256 KiB per-record cap is elided
by measuring its raw line length, before any parse. Codex records are read from
`response_item` only — `event_msg` duplicates every turn.

## Alternatives considered

- **Take `transcript_path` from the hook payload.** It is supplied, it is
  correct in the honest case, and it removes the glob entirely. It also accepts
  an absolute path from a channel any same-UID process can write and any bridged
  remote host can set, and would have to be re-validated app-side against
  exactly the provider roots the glob already searches — the same work, plus a
  trust boundary. Recorded here because the payload field is right there and
  reads like an oversight.
- **Widen `isReadOnlySnapshot` to cover generated documents.** One field instead
  of two, and it fails twice: `TerminalPaneLayout.documentNudgeTarget` returns
  `.unavailable(.readOnlyRemoteSnapshot)` for any read-only tab, which would
  disable the send bar on the very pane Resume lives in, captioned as a remote
  snapshot for a purely local file; and `anyRemote` folds across the whole tab
  group, stripping `localFileAccess` from the user's unrelated local Markdown
  tabs. Two independent review lanes converged on this.
- **Ask the pane for the session id at Resume time.** No new stored field. Open
  session A's transcript, exit, start session B in the same terminal, and Resume
  stages B.
- **Purge the rendered file when its tab closes, and at launch.** Smaller
  retention story, and it breaks the case the feature most needs: after a
  relaunch the pane reattaches to a still-live agent ([ADR 0011](0011-persistent-session-daemon-command-bridge.md))
  with blank scrollback, and a restored tab pointing at a purged file is a dead
  end.
- **Render the whole transcript and let the pane cope.** TextKit 2 does not
  cope, and cannot be made to under ADR 0018. Rendering plain text instead of
  rich Markdown reduces attribute runs but hits the same wall; bounding the
  input is the only lever.
- **Bound the render by turn count.** Simpler to state, but a turn's size varies
  by four orders of magnitude here, so a count either truncates useful history
  or blows the budget. Bytes are what the pane actually runs out of.

## Consequences

- A transcript is *regenerable implementation storage* with a durable identity,
  the same shape as a remote Markdown snapshot: the identity is the tab, the
  file is not. Re-rendering reuses the path deliberately.
- The rendered file is a plaintext copy of whatever passed through the session,
  routinely including pasted credentials and file contents. Owner-only custody
  is load-bearing, not hygiene, and nothing on this path logs a path.
- The document is a *window*, not the session: it opens on the newest turns that
  fit, says so in its header, and grows its read window only when a pass rendered
  nothing.
- Remote panes are refused with their own reason. The local JSONL side channel
  cannot cross SSH ([ADR 0023](0023-remote-workspace-architecture.md)), and a
  same-id local file must never be presented as the remote session's transcript.
- Adding a third provider means teaching `AgentTranscriptImporter` its root, its
  filename shape, and its record types — and confirming its session id is a
  UUID. A provider whose id is not UUID-shaped needs this ADR revisited, not a
  looser gate.
