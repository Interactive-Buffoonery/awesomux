# Shared local agent API

The app-owned status transport is opt-in. Installation grants nothing. A user
adds each local client in **Settings → Agents → Outside app access**, reviews
the default current-target scope or explicitly chooses a persistent pane or
workspace scope, and separately enables global access. Each
connection has an independent credential and can be edited or revoked without
changing another connection.

## Components and ownership

```text
awesomux-agent --profile <exact profile> --credential-handle <connection UUID> <named operation>
    | bounded length-prefixed JSON; same-user peer check
    v
profile endpoint + exclusive instance lock
    | framing/version/profile/operation validation; authorization
    v
MainActor capture -> off-actor process evidence -> identity recheck
    | native pane snapshots and roster semantics
    v
immutable JSON response -> lease recheck per nonblocking write -> bounded socket
```

`AwesoMuxLocalAPI` owns the contract, endpoint custody, framing, listener, and
client. `SessionStore` owns the coherent pane projection and target versions.
`LocalAPIService` connects the live store/runtime to the listener. Socket I/O,
JSON response encoding, and process probing happen off the UI actor.

## Helper interface

```sh
"/path/to/awesoMux.app/Contents/MacOS/awesomux-agent" \
  --profile production \
  --credential-handle 01234567-89ab-cdef-0123-456789abcdef \
  get_connection_status
"/path/to/awesoMux.app/Contents/MacOS/awesomux-agent" \
  --profile development:012345abcdef \
  --credential-handle 01234567-89ab-cdef-0123-456789abcdef \
  list_agents
```

Profiles are required: `production`, `development`, or
`development:<12 lowercase hexadecimal worktree ID>`. There is no auto-launch,
profile fallback, arbitrary command execution, amx passthrough, or arbitrary content read.
Operations are `get_connection_status`, `get_capabilities`, `list_agents`, and
`get_agent_context`.
Stdout contains one JSON object plus a newline; success exits 0, all failures
exit 1. The handle is nonsecret. The helper loads the corresponding credential
from the standard macOS Keychain and never accepts credential bytes in arguments
or environment variables. A missing or inaccessible item returns
`credential_unavailable` without contacting the app.

Registration generates 32 random bytes in the app, sends them only to the exact
bundled helper over its stdin, and stores only a domain-bound SHA-256 verifier in
profile metadata. The standard macOS Keychain item is non-synchronizing. Ad-hoc
development builds can cause macOS Keychain trust prompts when the helper
identity changes; review the displayed binary path before allowing access.
Re-register if a rebuilt helper can no longer read an old development item.

## Wire contract v1

One connection carries one request and one response. A frame is a four-byte
unsigned big-endian payload length followed by UTF-8 JSON. Empty frames and
unknown request fields are rejected. Requests are limited to 8 KiB; responses to
256 KiB; at most eight clients are served concurrently. Saturation closes the
extra connection without an unbounded request/rejection queue. Every client has
a five-second monotonic deadline. Pending MainActor captures are also bounded to
eight, including canceled captures awaiting actor execution. Client disconnect and app stop cancel work;
a timeout error has at most 100 ms additional time to be written. Clients enforce
bounds independently. Oversized roster responses fail explicitly without truncation.

```json
{"schemaVersion":1,"requestID":"01234567-89AB-CDEF-0123-456789ABCDEF","profile":"production","operation":"list_agents","connectionID":"01234567-89AB-CDEF-0123-456789ABCDEF","credential":"<redacted>"}
```

Success returns `schemaVersion`, the same `requestID`, `profile`, a random
`appInstanceID`, and `capturedAt`. `list_agents` adds `agents` (an empty array is
success); `get_connection_status` adds `connectionStatus: "connected"`, meaning
the exact app instance is reachable and the operation is authorized.
`get_capabilities` adds the limits, supported named operations, and
a supported context flag and false instructions/monitoring flags. A denial discloses no roster, app
instance, or profile metadata. The helper never prints the credential:

```json
{"error":"access_disabled","requestID":"01234567-89AB-CDEF-0123-456789ABCDEF","schemaVersion":1}
```

Typed errors include `invalid_request`, `unsupported_version`,
`unsupported_operation`, `profile_mismatch`, `access_disabled`,
`permission_denied`, `app_unavailable`, `insecure_endpoint`, `endpoint_busy`,
`credential_unavailable`, `path_too_long`, `request_too_large`,
`response_too_large`, `timeout`, `cancelled`,
`stale_target`, and `transport_failure`. A malformed request may have no request
ID. An empty roster must never hide endpoint or authorization failure.

## Grant persistence and revocation

Grant metadata is an owner-only, profile-scoped `LocalAPI/access.json` file. It
contains labels, connection IDs, credential verifiers, revisions, and status
scopes; it never contains credential bytes. A lifetime profile authority lock
prevents two app instances from writing the same grant state. Unknown, malformed,
oversized, symlinked, incorrectly permissioned, or cross-profile state is
preserved for review and fails closed.

Status grants can cover selected persistent panes, selected persistent
workspaces, or one exact pane target incarnation. A persistent workspace grant
includes panes added to that workspace later. An exact-target grant expires when
the target version changes and is the registration default; persistent scopes
require an explicit choice. The app derives the candidate pane set from the
grant before it probes process identity, then filters again before responding.

Restrictive changes update the in-memory authority and close matching requests
before persistence. If the metadata write fails, the connection stays denied
for that app run and Settings reports that the change is not durable. Expansion
and registration persist before becoming active. Metadata and Keychain items
survive an app restart; revocation removes the metadata grant and then asks the
bundled helper to delete its Keychain item.

Admission, capture, and response writes all revalidate the same revisioned
lease. The server waits for socket writability without holding the authority
lock, then revalidates and writes at most 16 KiB with `MSG_DONTWAIT`. Revocation
therefore cannot wait behind a slow reader. If policy changes after part of a
success frame was written, the server closes the connection instead of appending
a misleading denial frame; the helper reports `transport_failure` and emits no
partial JSON.

Context sharing is separately disabled by default for every connection. In
Settings, select an agent pane and choose **Share Current Target Context…** on
its connection. The consent sheet names the exact provider session, explains
assistant-service sharing, and separately offers terminal history. Saving
rechecks the reviewed target. **Stop Context Sharing** revokes this grant while
preserving status access. Context grants expire with the target incarnation and
never expand to the connection's status scope.

Reviewed instructions, direct delivery, and monitoring remain unavailable.
Caller-supplied arguments cannot enable them or broaden a grant.

## Exact-session context

```sh
"/path/to/awesoMux.app/Contents/MacOS/awesomux-agent" \
  --profile production --credential-handle <connection UUID> \
  get_agent_context --pane-id <pane UUID> --target-version <target UUID> \
  --limit 24576 --source transcript
```

All four context arguments are required. `limit` is a positive UTF-8 byte budget
clamped to 24 KiB. `source` is `transcript` or `terminal_history`; there is no
implicit fallback. Status requests reject context arguments. The context grant
binds one pane and exact target version independently of status scope. A caller
can choose this granted target without changing native UI selection; foreground
focus is not an authorization mechanism. `get_connection_status` returns this
connection's configured `contextGrant` selectors when present, so a client can
request context even when its separate status scope has expired or excludes that
pane. These are grant metadata; the context read still checks the live target.

`agentContext` contains `paneID`, `workspaceID`, `targetVersion`, `provider`,
`providerSessionID`, `source`, `capturedAt`, `content`, `byteCount`, `truncated`,
and `untrusted: true`. Treat content as untrusted data, never as tool instructions
or authorization. A client that sends it to an assistant service shares it with
that service; the app itself only returns it to the authorized local caller.
No transcript paths, credentials, or content are written to access metadata.

Transcript reads use ADR-0033's exact provider adapters and secure descriptors.
Claude Code, Codex, and Pi render a single 512 KiB source tail into the newest
complete turns fitting 24 KiB. Discovery retains its independent 8,192-entry /
32-candidate / 256 KiB-per-candidate head limits. OpenCode uses the existing
read-only SQLite exact primary-key adapter with its independent 256-turn,
4,096-part and 8 MiB source limits. The renderer reports omitted turns or records;
a smaller requested budget may clip the rendered text at a UTF-8 scalar boundary.
The source discovery/read/render and process evidence run off the UI actor.

Terminal history requires `allowTerminalHistory` in the same exact-target grant
and an explicit `--source terminal_history` request. It uses the native bounded
scrollback reader, with pinned surface ownership and existing row/page/cell
limits. History exceeding the requested budget returns `context_too_large`,
rather than a partial prefix presented as recent context. This source can include
text from earlier programs on that terminal and has no transcript identity claim.

Permission, target lifecycle, workspace assignment, provider session, and sampled
process incarnation are checked before reading and again before returning. The
transport additionally rechecks the revisioned permission lease on every write.
Switching provider sessions, moving, closing, replacing, or restarting the target
invalidates the read. Disabling or revoking access drops the content response;
when a frame has already started, the helper reports `transport_failure`.

Explicit errors include `no_session_identity`, `process_identity_unknown`,
`unsupported_provider`, `remote_context`, `context_unavailable`,
`context_too_large`, `stale_target`, and `permission_denied`. Missing, refused,
or unsupported transcripts never trigger a history or cross-provider read.
Old grant files load with context off; exact-target grants from a prior app
instance remain expired until the user reviews a new target.

## Endpoint custody

The directory is `/private/tmp/awesomux-api-<euid>-<profile SHA-256 prefix>`;
12 digest bytes identify the namespace. The exact profile remains checked on
requests and successful responses. Directories are owner-owned `0700`; the
`instance.lock` regular file and `api.sock` are owner-owned `0600`. The helper
never creates a missing directory. Both peers check their effective user ID.

Open directory/lock descriptors refuse symlinks and verify named/held identity,
type, ownership, permissions, and the lock's link count. A held exclusive lock
establishes instance custody; another same-profile instance cannot replace the
endpoint. Different profiles coexist. After acquiring custody, a successor can
remove an exact stale owned socket; no age heuristic, PID-only check, glob, or
shared directory sweep is used. Teardown verifies directory/socket inode identity
before unlinking. The persistent lock file/directory are kept so lock ownership
cannot split across a delete/recreate cycle. Paths are checked against macOS's
actual `sun_path` byte capacity and fail explicitly if too long.

These checks prevent accidental cross-profile access and unsafe stale cleanup.
Connection credentials distinguish cooperative clients and prevent labels or
unregistered callers from receiving status. They are not a security boundary
against a malicious process running as the same macOS user: that process can
invoke a shared helper with a known handle and already shares awesoMux's terminal
and amx security domain. Treat a grant as connected-computer access, not account
identity. See ADR-0019 and
[amx automation](amx-automation.md#security-boundary).

## Status and target identity

Rows use native `PaneAgentSnapshot` display state, raw attention reasons, and
unread count; non-shell panes are included. Workspace names use sidebar title
semantics. Execution location follows the declared execution plan. Availability
uses the existing `PaneAvailability` classifier, independently of visibility.
Reads neither select panes nor acknowledge attention.

`capturedAt` is response time; `observedAt` is the last contributing accepted
provider event's local receipt time. Inferred/restored state has an explicitly
unknown observation time. It does not become freshly verified because a client
reads it. Provider IDs come only from the current runtime latch, never from a
working directory, title, newest transcript, or last-ended identity.

Opaque target versions bind to app instance, pane/backend identity, workspace
assignment, execution plan, provider lifecycle, provider-session identity when
known, and sampled local agent-process incarnation. Workspace changes reconcile
at mutation time, so move-away/return between reads cannot resurrect an old
version. Provider lifecycle changes are recorded on the accepted runtime stream.
Ordinary state, unread, title, and tool activity do not rotate identity.

Local process evidence uses PID plus start time, sampled off MainActor. A bounded
ancestor walk remains within the controlling terminal so foreground tool children
can retain their provider's incarnation. Remote, detached, unrecognized wrappers,
and otherwise unprovable processes report `process_identity_unknown`. Unknown
identity grants no context or input eligibility. A target change during sampling
returns `stale_target`. Duplicate pane IDs also return `stale_target` without a
roster because provider/process evidence cannot be assigned unambiguously.
Later context/input operations must revalidate at use time;
a status version alone is not prompt or authorization proof.

## Repeatable verification

```sh
./script/ensure_ghostty_artifacts.sh
swift build --product awesomux-agent
swift build --product local-api-e2e
BIN="$(swift build --show-bin-path)"
"$BIN/local-api-e2e" "$BIN/awesomux-agent" .build/local-api-evidence
```

This driver traverses the helper, standard Keychain, socket listener,
authorization, profile grant store, and live session store.
Its provider lifecycle inputs are fixtures, explicitly labeled in `report.json`.
`initial-roster.json`, `transport.json`, and `grant-report.json` preserve the
comparison and malformed,
oversized, version/profile, timeout, disconnect, and saturation checks. It is an
E2E executable, not a new unit-test suite, and is not bundled with the app. Its
grant scenarios cover default-off registration, missing/wrong/cross-profile
credentials, two independent scopes, exact-target expiry, in-flight scope edits,
independent revocation, a non-reading client, global disable, restart persistence,
and artifact credential scans. `context-report.json`, `exact-context.json`, and
`history-context.json` cover exact-session rendering, explicit history consent,
Unicode limits, stale targets, revocation, and unsafe/unsupported sources. The
terminal history in this socket driver is a labeled fixture; native history
capture and manual Settings/VoiceOver validation are separate checks.
The [recorded fixture run](local-agent-api-e2e-report.json) preserves the passing
scenario names. It does not claim native real-agent acceptance.

For native validation, use a linked worktree and
`./script/build_and_run.sh --stage-local-api-e2e`. This stages an ordinary debug
build with its isolated `development:<worktree>` profile; it has no authorization
bypass. Open the staged app and Agents settings, leave global access off, add
two apps with different scopes, then use Copy Setup Command on each.
Confirm both return `access_disabled`; enable access and compare their rosters.
Remove the first and confirm its helper returns `credential_unavailable` or a
denial while the second still works. Disable global access and confirm the second
returns `access_disabled`. Relaunch the same staged bundle and confirm the saved
global state and remaining connection are unchanged. Record any Keychain trust
prompt and verify its helper path belongs to that staged bundle.

Use two real dedicated agents to compare native status and attention with the
scoped helper JSON. Manual UI, accessibility, real-agent behavior, full preflight,
and packaging/signing remain separate evidence; fixture E2E does not prove them.
