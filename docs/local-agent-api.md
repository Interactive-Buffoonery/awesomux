# Shared local agent status API

INT-1198 supplies the app-owned status transport and bundled `awesomux-agent`.
It does not enable assistant access: normal development and distributed builds
return `access_disabled` for every operation. Connection registration, credentials,
and grants belong to INT-1199. A same-user socket connection is not authorization.

## Components and ownership

```text
awesomux-agent --profile <exact profile> <named operation>
    | bounded length-prefixed JSON; same-user peer check
    v
profile endpoint + exclusive instance lock
    | framing/version/profile/operation validation; authorization
    v
MainActor capture -> off-actor process evidence -> identity recheck
    | native pane snapshots and roster semantics
    v
immutable JSON response -> authorization recheck -> bounded socket write
```

`AwesoMuxLocalAPI` owns the contract, endpoint custody, framing, listener, and
client. `SessionStore` owns the coherent pane projection and target versions.
`LocalAPIService` connects the live store/runtime to the listener. Socket I/O,
JSON response encoding, and process probing happen off the UI actor.

## Helper interface

```sh
"/path/to/awesoMux.app/Contents/MacOS/awesomux-agent" \
  --profile production get_connection_status
"/path/to/awesoMux.app/Contents/MacOS/awesomux-agent" \
  --profile development:012345abcdef list_agents
```

Profiles are required: `production`, `development`, or
`development:<12 lowercase hexadecimal worktree ID>`. There is no auto-launch,
profile fallback, arbitrary command execution, amx passthrough, or content read.
Operations are `get_connection_status`, `get_capabilities`, and `list_agents`.
Stdout contains one JSON object plus a newline; success exits 0, all failures
exit 1. Installation alone grants nothing. The credential field is reserved for
INT-1199; this helper does not yet load or accept credentials.

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
{"schemaVersion":1,"requestID":"01234567-89AB-CDEF-0123-456789ABCDEF","profile":"production","operation":"list_agents"}
```

Success returns `schemaVersion`, the same `requestID`, `profile`, a random
`appInstanceID`, and `capturedAt`. `list_agents` adds `agents` (an empty array is
success); `get_connection_status` adds `connectionStatus: "connected"`, meaning
the exact app instance is reachable and the operation is authorized. Registration
and grant states remain deferred to INT-1199. `get_capabilities` adds the limits, supported named operations, and
false context/instructions/monitoring flags. A denial discloses no roster, app
instance, or profile metadata:

```json
{"error":"access_disabled","requestID":"01234567-89AB-CDEF-0123-456789ABCDEF","schemaVersion":1}
```

Typed errors include `invalid_request`, `unsupported_version`,
`unsupported_operation`, `profile_mismatch`, `access_disabled`,
`permission_denied`, `app_unavailable`, `insecure_endpoint`, `endpoint_busy`,
`path_too_long`, `request_too_large`, `response_too_large`, `timeout`, `cancelled`,
`stale_target`, and `transport_failure`. A malformed request may have no request
ID. An empty roster must never hide endpoint or authorization failure.

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
They do not isolate malicious processes of the same macOS user, which already
share awesoMux's terminal and amx security domain. See ADR-0019 and
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
returns `stale_target`. Later context/input operations must revalidate at use time;
a status version alone is not prompt or authorization proof.

## Repeatable verification

```sh
./script/ensure_ghostty_artifacts.sh
swift build --product awesomux-agent
swift build --product local-api-e2e
BIN="$(swift build --show-bin-path)"
"$BIN/local-api-e2e" "$BIN/awesomux-agent" .build/local-api-evidence
```

This driver traverses the helper, socket listener, authorization, and live store.
Its provider lifecycle inputs are fixtures, explicitly labeled in `report.json`.
`initial-roster.json` and `transport.json` preserve the comparison and malformed,
oversized, version/profile, timeout, disconnect, and saturation checks. It is an
E2E executable, not a new unit-test suite, and is not bundled with the app.
The [recorded fixture run](local-agent-api-e2e-report.json) preserves the passing
scenario names. It does not claim native real-agent acceptance.

For native real-agent comparison, use a linked worktree and
`./script/build_and_run.sh --stage-local-api-e2e`. This builds a debug-only,
compile-time-authorized host in the isolated worktree profile. The define is
rejected in release configuration; no runtime preference, helper argument, or
production environment variable enables it. Open the staged app, launch two
real dedicated agents, compare native status/attention with helper JSON, and
save screenshots and results. Stop that app before rebuilding the ordinary
`--verify` host, which must return `access_disabled`. Never distribute the
E2E-authorized bundle. Real-agent proof, full preflight, packaging/signing,
and manual native responsiveness are separate evidence.
