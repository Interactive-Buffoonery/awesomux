# 0039 — A bounded read-only transcript for devices

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** Sarah
- **Issue:** [#829](https://github.com/Interactive-Buffoonery/awesomux/issues/829)

## Context

Phones are denied `get_agent_context` today. Its local-caller contract returns
bounded text, not typed conversation messages. Agent bubbles should follow a
decision about consent, exact identity, provider coverage and paging rather
than infer a conversation or approval from terminal output.

[ADR-0033](0033-agent-transcripts-use-exact-provider-identities.md) and the
[local API](../local-agent-api.md#exact-session-context) already require exact
provider identity, bounded secure reads and repeated authorization. This proposal
proposes amending [ADR-0035](0035-awesomux-companion-pairing.md): add
`get_agent_context` to the companion allowlist only for `source: transcript`
and separate consent. Acceptance requires a corresponding ADR-0035 scope
amendment; this does not silently accept its other Proposed provisions. It grants no input or approval authority.
Sarah must accept this record before implementation.

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

**Recommendation:** first expose only the existing bounded text envelope for an
explicitly granted, current local agent target. Defer typed messages, tool cards
and older-page navigation to a later contract.

### Consent and identity

- Add a default-off transcript power per paired device, with a Mac-approved
  exact pane/target-version grant initiated on the Mac. Both are required. Explain that conversation
  text and tool output can contain secrets; do not promise automatic redaction.
  Status, terminal-history or future input permission alone cannot enable it. Existing
  pairings remain denied until the user grants this power and target.
- Require `source: transcript`; continue denying `terminal_history` to devices.
  Store `allowTerminalHistory: false`; the phone cannot widen its grant.
  Apply this opt-in equally to v1 and v2 pairings within their existing network
  route restrictions; no automatic pairing or capability upgrade.
  Do not permit arbitrary provider IDs, file paths, directory searches or latest-
  conversation discovery from the phone. The Mac resolves the exact live target
  using ADR-0033. No match means an explicit unavailable response.
- Recheck consent, revisioned lease, pane/workspace assignment, target version,
  provider session and process incarnation before reading and before writing
  the response. Close/move/restart/session change invalidates the target grant;
  expiry or revocation cancels reads. App restart requires a fresh target grant.
  Fail closed if the identity or process evidence is uncertain.
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
terminal-history sharing. Exact-target consent adds friction when an agent
restarts; that is preferable to silently sharing its replacement conversation.
The UI must acknowledge bounded history even when the response is not clipped.
Future validation must cover every provider's limits, stale identities, revoke
during response, session switches and malicious rendered text. This docs-only
record does not claim those device paths exist or have passed tests.

## Open questions for Sarah

1. Ship bounded read-only text first, deferring bubbles/tool cards and paging?
2. Require both a device transcript switch and Mac-approved exact-target consent,
   renewed after a target or app restart, rather than a workspace-wide grant?
3. Keep transcripts memory-only and clear them on lock/background/disconnect in
   v1, with no offline transcript cache?
