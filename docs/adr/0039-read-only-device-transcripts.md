# 0039 — A bounded read-only transcript for devices

- **Status:** Accepted
- **Date:** 2026-10-20
- **Accepted:** 2026-10-20 — Sarah accepted with one change: consent is a workspace-wide grant, not per exact target
- **Deciders:** Sarah
- **Issue:** [#829](https://github.com/Interactive-Buffoonery/awesomux/issues/829)

## Context

Phones are denied `get_agent_context` today. Its local-caller contract returns
bounded text, not typed conversation messages. Agent bubbles should follow a
decision about consent, exact identity, provider coverage and paging rather
than infer a conversation or approval from terminal output.

[ADR-0033](0033-agent-transcripts-use-exact-provider-identities.md) and the
[local API](../local-agent-api.md#exact-session-context) already require exact
provider identity, bounded secure reads and repeated authorization. This record
amends [ADR-0035](0035-awesomux-companion-pairing.md): add `get_agent_context`
to the companion allowlist only for `source: transcript` and a separate
workspace-wide consent. The corresponding ADR-0035 scope amendment is recorded
in that ADR under **Amended:** 2026-10-20 (landing with ADR-0036, #854);
this does not silently accept its other Proposed provisions. It grants no input or approval authority.
Sarah accepted this record on 2026-10-20, changing the drafted per-target
consent to a workspace-wide grant.

## Options considered

- **Enable the current text operation with new consent (recommended):** smallest
  useful Activity view, reuses exact-session reads and existing provider adapters;
  cannot promise bubbles, linked tool cards or complete history.
- **A typed message/tool API now:** supports richer UI, but needs stable record
  identities, provider-specific normalization and paging before it is trustworthy.
- **Share raw logs or terminal history:** more apparent coverage, but exposes
  unrelated data and confuses terminal text with provider conversation identity.
  Reject as a transcript fallback.

## Decision

**Decision:** first expose only the existing bounded text envelope for the
current local agent target of a pane inside a Mac-granted workspace. Defer
typed messages, tool cards and older-page navigation to a later contract.

### Consent and identity

- Add a default-off transcript power per paired device, with a Mac-approved
  grant for explicitly selected workspaces, initiated on the Mac (no
  all-workspaces default). Both are required. The grant covers every agent
  pane that is in a granted workspace at read time, including a replacement
  conversation after an agent restarts in that workspace; it is not renewed
  per pane or per target version. Explain that conversation text and tool
  output can contain secrets; do not promise automatic redaction. Status,
  terminal-history or future input permission alone cannot enable it. Existing
  pairings remain denied until the user grants this power and a workspace.
- Require `source: transcript`; continue denying `terminal_history` to devices.
  Store `allowTerminalHistory: false`; the phone cannot widen its grant.
  Apply this opt-in equally to v1 and v2 pairings within their existing network
  route restrictions; no automatic pairing or capability upgrade.
  Do not permit arbitrary provider IDs, file paths, directory searches or latest-
  conversation discovery from the phone. The phone names a pane; the Mac
  resolves that pane's exact live target using ADR-0033. No match means an
  explicit unavailable response.
- Recheck consent, revisioned lease, pane/workspace assignment, target version,
  provider session and process incarnation before reading and before writing
  the response. These are safety checks that bind each read to one exact
  conversation and process, not consent events: a target change needs no new
  approval, but a read must never mix or carry over data across targets.
  Moving a pane out of a granted workspace, or closing or deleting that
  workspace, ends access to it immediately; expiry or revocation cancels reads.
  Fail closed if the identity or process evidence is uncertain.
- App restart does not require re-approval. The workspace grant is stored with
  the companion connection and persists like the pairing itself, because it
  names a persisted workspace rather than a pane process or target version
  that cannot survive a restart. After a restart the per-read checks above
  still resolve a fresh exact target before any text is returned. Revocation
  or unpairing is the only way to end a grant early.
- Use the direct paired mutual-TLS connection and existing route rules. Do not
  send transcripts through push, analytics, a cloud assistant or a sync service.
  The phone keeps received text in memory only for this first version, clears it
  on background/lock, disconnect, target change and revocation, and obscures app
  switcher snapshots. Revocation cannot retract text already seen or copied.
  Never place transcript text in widgets, Live Activities, notifications, shared
  containers, Spotlight/Handoff, logs, crash reports or analytics. Fetch only
  while the transcript view is foreground and visible. The Mac permits one read
  in flight per device and rate-limits reads; detailed limits belong to the wire
  implementation.

### First response shape

Reuse `agentContext`: `paneID`, `workspaceID`, `targetVersion`, `provider`,
`providerSessionID`, `source`, `capturedAt`, `content`, `byteCount`, `truncated`
and `untrusted: true`. No transcript path or raw storage record is returned.
The requested UTF-8 budget remains capped at 24 KiB and the existing independent
discovery/read bounds remain in force. `truncated: false` means no clipping in
that bounded render, not that the complete provider history was read.

Label the view **Recent conversation — limited history** and show capture time.
Refresh replaces the whole snapshot; it is not an append cursor and must not
duplicate or stitch turns. No paging token or Load older control is offered in
v1. An omitted or unsupported record is not reconstructed from nearby text.

| Provider | First-version coverage |
| --- | --- |
| Claude Code, Codex, Pi | Exact-identity JSONL adapters; newest complete turns within existing source/render bounds; refresh reopens securely |
| OpenCode | Exact primary-key, read-only SQLite snapshot within its existing bounds; explicit reread, no JSONL watcher or promised live subscription |
| Grok | Explicitly unavailable; no shipped transcript adapter |
| Remote-host agents | Explicitly unavailable; no local or cross-provider fallback |

Keep all existing `get_agent_context` error codes unchanged and distinguishable
from an empty conversation, including `process_identity_unknown`,
`unsupported_provider` and `remote_context`. Provider coverage
describes adapter reuse, not a promise that every tool record is represented.

### Typed messages and tools later

A later version must define stable message/part IDs, user/assistant/tool roles,
tool-call/result correlation, unsupported-part markers, and completeness ranges
for each provider. Paging must bind opaque cursors to the granted target,
provider identity and source generation, reauthorize every page, bound bytes and
records, and explicitly expire after rotation/truncation rather than skip data.
It must not infer tool success or consent from prose. These requirements are a
follow-up boundary, not extra fields promised by this first version.

All transcript content is untrusted display data. Render plain monospaced text,
without Markdown/HTML parsing, remote resource loading, terminal control
sequences, data detectors or tappable links. A string that looks
like an approval request remains text. Approval buttons can come only from a
separate live decision-core request (the Mac's permission-request authority); never join one
to transcript text by wording, tool name or timing.

## Consequences

An Activity view can precede bubbles without replacing the local API or widening
terminal-history sharing.
The UI must acknowledge bounded history even when the response is not clipped.
A workspace-wide grant removes re-approval friction when an agent restarts, at
the cost of sharing whatever conversation later runs in that workspace; the
granted workspace, not the exact target, is the consent boundary. Per-read
identity checks still prevent a stale or mixed read.
Future validation must cover every provider's limits, stale identities, revoke
during response, session switches and malicious rendered text. This docs-only
record does not claim those device paths exist or have passed tests.

## Open questions for Sarah

Answered by Sarah on 2026-10-20; accepted with the consent change in question 2.

1. Ship bounded read-only text first, deferring bubbles/tool cards and paging?
   **Decision:** yes.
2. Require both a device transcript switch and Mac-approved exact-target consent,
   renewed after a target or app restart, rather than a workspace-wide grant?
   **Decision:** no. Consent is a workspace-wide grant: the default-off
   per-device transcript power plus Mac approval for a Mac-selected workspace.
   Exact target resolution and the per-read identity and process rechecks stay
   as safety checks but do not require fresh consent per target. Moving a pane
   out of the granted workspace ends access. App restart does not require
   re-approval; the grant persists with the pairing until revoked.
3. Keep transcripts memory-only and clear them on lock/background/disconnect in
   v1, with no offline transcript cache?
   **Decision:** yes.
