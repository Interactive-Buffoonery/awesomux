# awesoMux Companion pairing protocol

This document is the complete Mac-to-iPhone pairing, status API, opt-in pane rename, and self-unpair contract.
All integers are decimal unless a representation is stated explicitly.

V1 wire DTOs, framing, link syntax, and confirmation words live in the root
`AwesoMuxCompanionProtocol` package in `awesomux-companion`. This app pins an exact
package revision in `Package.swift` and `Package.resolved`; TLS and authorization
remain local. Package versions do not change wire versions.

The Mac emits v2 pairing links and reports current bound routes (#783).
Legacy v1 grants retain their stored transport restriction. Phone v2 parsing,
persistence, and route selection require corresponding phone support.
Pairing frames retain `v: 1`; API requests and responses retain
`schemaVersion: 1`. Link version 2 does not change either wire version.

## Cryptographic identities

The Mac and phone each use a P-256 key and a self-signed X.509 certificate. The
phone should keep its private key non-exportable in the Secure Enclave. The Mac
keeps its private key and certificate in the login Keychain. Development and
production Mac profiles use different identities.

`SPKI` means the complete DER `SubjectPublicKeyInfo`, including the
`id-ecPublicKey` and `prime256v1` algorithm identifiers and the uncompressed
P-256 point. A fingerprint is `SHA-256(SPKI)`.

The phone must compare the Mac certificate's SPKI fingerprint with `fp` before
sending the pairing secret or any API request, on every route. An identity
failure must never update trust. After pairing, both sides pin the other side's
SPKI fingerprint. TLS is version 1.3 and requires certificates from both peers.

## Pairing link

### Legacy v1

Legacy pairings used exactly this URL:

```text
awesomuxcompanion://pair?v=1&h=<host>&p=<port>&fp=<macFP>&s=<secret>&n=<macName>&t=<lan|tailscale>
```

- `v` is `1`.
- `h` is the IPv4 address of the one interface on which the Mac listener is
  bound. It is never a wildcard address. For `lan` it is a private address
  (10/8, 172.16/12, 192.168/16) on a non-tunnel interface; for `tailscale` it
  is a 100.64/10 address on a `utun` interface.
- `p` is the TCP port.
- `fp` is unpadded base64url of the Mac SPKI SHA-256 fingerprint.
- `s` is unpadded base64url of 32 random bytes. It is single use and expires
  after five minutes or when the Mac closes the pairing sheet.
- `n` is the percent-encoded Mac display name.
- `t` is `lan` or `tailscale`.

The phone must preserve the host, port, fingerprint, Mac name, and transport for
the paired connection. The port is stable across Mac restarts for that pairing.
A persisted v1 pairing stays single-route and transport-scoped. Authorizing
both routes requires explicit re-pairing with a v2 link, not a metadata update.
An unreachable v1 saved endpoint still requires re-pairing.

### v2

The QR code and **Copy Link** action contain this fixed shape:

```text
awesomuxcompanion://pair?v=2&lan=<IPv4>&tailscale=<IPv4>&p=<port>&fp=<pin>&s=<secret>&n=<name>
```

- `v` is `2`. `lan` and `tailscale` are optional, with at most one of each;
  at least one is required. Omit unavailable routes rather than using empty
  values. These are IPv4 literals, not DNS names or endpoint lists.
- `p` is one decimal TCP port in 1–65535, stable across Mac restarts for the
  pairing and shared by both listeners. A port change requires re-pairing.
- `fp`, `s`, and `n` have the same encoding and meaning as in v1. Both routes
  share the Mac SPKI pin, phone identity, grant/connection ID, and exact profile.
  Routes do not create separate pairings or authorization scopes.
- `h` and `t` are v1-only fields. A v2 parser rejects duplicate fields, invalid
  route values, missing required fields, and mixed v1/v2 route fields. A client
  without v2 support must reject the link explicitly; it must not silently
  downgrade it, reinterpret it as v1, or discard a route to manufacture a v1
  pairing. Supporting v1 and v2 explicitly is allowed.

The Mac accepts a v2 grant on either currently bound eligible route, regardless
of which route completed pairing. Legacy v1 grants remain restricted to their
stored `transport`; the Mac must not advertise or accept a second transport for
them. Persist the distinction between v1 transport-scoped and v2 dual-route
grants. Reading and saving existing `access.json` grants must preserve their
fingerprints, connection IDs, ports, and transport restriction. Do not ignore
the legacy `transport` field globally or infer v2 authorization from a newer
phone, a status request, or the presence of another listener. Re-pairing uses
the existing replacement/revocation rules; metadata cannot widen a grant.
V1 and v2 grants may coexist within one runtime profile. All listeners and
grants in that profile share one stable port, retaining the existing port
while any grant remains. Adding a v2 pairing must not allocate a replacement
port or require removing v1 phones. A legacy grant's transport check still
applies even when a v2 grant authorizes the other listener.

#### Eligible private interfaces and listener lifecycle

The listeners enforce these IPv4 route-class boundaries:

- Every address must be assigned to an UP, non-loopback interface and be
  unicast. Never bind or advertise public, wildcard, loopback, link-local,
  multicast, or broadcast addresses (including subnet broadcast addresses).
- `lan` must be RFC1918: 10/8, 172.16/12, or 192.168/16. Exclude tunnel and
  bridge interfaces, including names prefixed `utun`, `ipsec`, `ppp`, or
  `bridge`, as in the current source rules.
- `tailscale` must be 100.64/10 on a `utun` interface. This is an eligibility
  convention, not proof that Tailscale owns that interface or address. A
  100.64/10 address on a carrier hotspot/non-`utun` interface is ineligible;
  other tunnel addresses and other VPN support are outside this contract.

Choose at most one address per class. Preserve the existing `en0` preference,
then sort by interface name, with numeric IPv4 address as the stable tie-break
when an interface has multiple eligible addresses. Only successfully bound
addresses may be advertised. Both listeners use the shared `p`; inability to
bind a route never permits a wildcard or a different port for that route.
Re-evaluate eligibility on network changes, stop binding/advertising removed
addresses, and select eligible replacements deterministically. Listener
lifetime remains limited to an open pairing sheet or an existing paired phone.
IPv6, DNS, Bonjour, and arbitrary address discovery are not added.

All listeners share one pairing session and one secret. Consumption is atomic
across listeners: the first valid attempt consumes it, so simultaneous attempts
cannot create multiple approvals or grants. Closing/expiring the session
invalidates it everywhere. Revocation and self-unpair invalidate the same
phone grant on all routes.

#### Phone route selection and compatibility

Persist the available route set and shared port with the existing pairing
identity. Try LAN first, then Tailscale on failure. Before sending the secret
or any API request to either address, verify the saved Mac SPKI pin. A stale
LAN address belonging to a different machine receives neither. An identity
failure makes that route unusable for that attempt, without removing it from
the saved set or replacing the pin, identity, profile, or grant; another saved
route must authenticate independently.
A TLS rejection on one route falls through to the next saved route. TLS
failures alone never prove revocation or cause automatic deletion of pairing
state, even if all routes fail.

When using Tailscale, reconsider LAN on network change or foreground, with a
cooldown to avoid flapping. Exact retry timing and cooldown mechanics belong
to #783 and the phone implementation, not this contract. Refresh routes only
through the pinned, authenticated `get_connection_status` extension below.
If every saved route is unreachable, remain offline until a saved route works
or the person re-pairs; do not probe arbitrary addresses. A reachable alternate
route can report a changed DHCP address without re-pairing.

## Framing

Every JSON message is one length-prefixed frame:

1. Four-byte unsigned big-endian JSON byte length.
2. That many bytes of UTF-8 JSON.

An empty frame is invalid. Requests are limited to 8 KiB and API responses to
256 KiB. A normal API connection carries one request and one response. The
pairing connection carries the initial request, a `confirm` response, and then
one final `paired` or `denied` response.

## Pairing exchange

The phone opens mutual TLS with its self-signed P-256 certificate. During an
open pairing session the Mac accepts a cryptographically self-signed client
certificate whose key is P-256. The first frame must contain exactly:

```json
{"v":1,"op":"pair","secret":"<s>","phoneName":"<name>"}
```

The Mac trims leading and trailing whitespace from `phoneName`, removes unsafe
control, bidirectional-routing, and invisible-routing scalars, and normalizes
the displayed name. The pre-sanitized trimmed input must be at most 80 Unicode
characters and the sanitized result must be non-empty. It rejects an invalid
name without consuming the secret. The Mac compares the decoded 32 secret bytes
in constant time. A malformed, wrong, expired, or already-used secret returns
this frame and closes:

```json
{"v":1,"status":"denied"}
```

A correct secret is consumed immediately (atomically across all listeners in
v2). The Mac replies:

```json
{"v":1,"status":"confirm"}
```

Both devices then compute the same three confirmation words:

```text
digest = SHA-256(macSPKI || phoneSPKI)
words  = [W[digest[0]], W[digest[1]], W[digest[2]]]
```

Concatenation uses the exact DER SPKI byte strings with no length prefix. The
three digest values are unsigned byte indices into the list below. The phone
should show the words in order. The Mac asks the person to allow the named
phone and shows the same order.

If the person chooses **Allow**, the Mac stores the phone SPKI fingerprint and
returns:

```json
{"v":1,"status":"paired","connectionID":"<uuid>","macName":"<n>"}
```

The UUID is lowercase in the Mac implementation, but clients must accept any
standard UUID case. Re-pairing with the same phone key replaces its old grant
with a new connection ID; the old connection ID is immediately revoked.
`macName` is the decoded display name, not percent-encoded.

If the person chooses **Don't Allow**, closes the sheet, or does not decide
within two minutes, the Mac returns `denied` and closes. The phone reconnects
after `paired`; the pairing connection does not become an API connection.

## Authorized API requests

On every later connection the phone presents the paired certificate. It sends
the existing local API v1 request object without a bearer `credential`. Because
the exact pairing link intentionally contains no runtime profile, `profile` may
also be omitted on Companion transport; the listener binds the request to its
own exact profile. If `profile` is present, it must match that profile.

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"list_agents","connectionID":"<uuid>"}
```

Only these operations are accepted:

- `get_connection_status`, with no operation arguments.
- `unpair`, with no operation arguments; revokes only the authenticated phone.
- `list_agents`, with no operation arguments.
- `get_alert_preferences`, with no operation arguments; reads only the
  authenticated pairing's preferences.
- `set_alert_preferences`, with exactly one `alertPreferences` object containing
  the replacement `categories` array; changes only the authenticated pairing's
  preferences. Pane, cursor, scope, and command-event arguments are rejected.
- `rename_pane`, with required `workspaceID`, `paneID`, and `title`; requires
  a separate Mac-approved rename scope.
- `list_panes`, with no operation arguments.
- `set_terminal_preview`, with required `terminalPreviewAllowed` JSON Boolean
  and no other operation arguments. It changes only the authenticated phone's
  permission; it cannot target another connection.
- `get_attention_events`, with required positive `limit` (maximum 100) and an
  optional non-empty `cursor` of at most 2,048 UTF-8 bytes. Optional
  `includeCommandEvents` accepts a JSON boolean; omission or `null` defaults to
  false. Only this operation accepts the field, including when its value is
  false or `null`.

`get_agent_context`, `get_capabilities`, all input operations, context fields,
and bearer credentials are denied. The connection ID must be the value returned
by `paired`, and the presented certificate fingerprint must still match that
non-revoked connection. Unpairing revokes it immediately. Companion access is
independent of the Mac's Outside app access switch.

### Opt-in terminal-pane rename (#795, first layer)

`rename_pane` is Companion-only and is absent from the local bearer operation
catalog. It does not grant create, split, close, workspace rename, document
rename, input, or context access. The existing paired certificate, connection ID,
profile, and transport checks still apply.

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"rename_pane","connectionID":"<paired-uuid>","workspaceID":"<workspace-uuid>","paneID":"<terminal-pane-uuid>","title":"Backend"}
```

`workspaceID` is the native session UUID and `paneID` is the native terminal
pane UUID, matching the pane roster identities (#785). Both are required;
array positions, active selection, document tab IDs, and document-group IDs are
not terminal identities. `title` must be a JSON string. No other operation
arguments are accepted; missing, null, wrong-type, malformed UUID, and unrelated
fields return `invalid_request`. Rename fields are rejected on other operations.
The usual 8 KiB request bound applies.

Each phone's optional persisted `paneRenameScope` is independent of status,
context, and terminal-preview permissions. Missing means denied for both legacy
and new grants. Only the Mac's **Allow pane renaming** control can enable or
disable it; the phone cannot grant itself rename permission. Enabling captures
that phone's current status scope. At mutation time both the status scope and
rename scope must allow the exact target. Granting rename never widens status
visibility. Turning the control off removes the grant. Every change rotates the
connection revision and invalidates pending requests before saving; a failed
save denies this phone for the run until Retry Save succeeds.

The endpoint rechecks the original certificate and lease under the authority
lock, then checks cancellation and its monotonic deadline before a synchronous
MainActor `SessionStore` rename. The lock remains held with no suspension.
A revoked, replaced, disabled, or scope-changed grant cannot perform a pending
mutation. Response writes recheck the same lease too. A rename already applied
before a disconnect/revocation may have no receipt; reconnect and read the pane
roster to reconcile. Retrying the same target and title has the native idempotent
result; request IDs are correlation IDs, not a durable deduplication journal.

The native title sanitizer trims whitespace, removes unsafe display scalars,
and caps titles at 200 Characters. A title that sanitizes to empty returns
`invalid_title`; it never resets the native custom-title pin. A missing workspace
or pane, or a pane no longer in the supplied workspace, returns `stale_target`.
An existing document-group leaf returns `nonterminal_target`. Scope/grant denial
returns `permission_denied` before target lookup. Cancellation and expiry return
`cancelled` and `timeout` without mutating. Success is the standard envelope with
`profile`, `appInstanceID`, and `capturedAt`, without roster or content. The native
rename pins the title, persists through the usual session snapshot, and preserves
selection and attention. Native lone-pane workspace-title behavior also applies.

Release order: this Mac operation is additive; old phones remain unchanged and
all existing grants stay denied until Mac opt-in. No shared-package pin change is
needed for the Mac decoder and existing acknowledgement envelope. A typed phone
request can later add the operation string and optional UUID/title fields to
`CompanionAPIRequest` without changing wire version. Older Macs reject the new
operation (`invalid_request` on implementations whose strict field allowlist
predates rename, or `unsupported_operation`); neither is success. Clients must
show that the Mac needs an update and must never fall back to another operation.

Mac downgrade is a separate limitation: after rename permission is saved, an
older Mac build using the same runtime profile rejects the newer access file's
unknown `paneRenameScope` field. Its existing fail-closed loader preserves the
file and disables all Local API access for that run, including other phones and
Outside app grants. Return to a supporting Mac build to manage those grants;
do not treat an older build's refusal as revocation or delete the access file.

The pairing E2E harness covers default denial and malformed/unrelated arguments
through TLS. `CompanionPaneRenameTests` covers native success/persistence,
visibility intersection, stale and document targets, invalid titles, lease
revocation, permission changes, cancellation, and deadline expiry. A native
run must also verify the Mac settings toggle and roster update after an
opted-in rename; direct tests do not establish those UI/network success paths.
### Pane roster and terminal-content access

Every paired phone can see workspace and pane status. Terminal previews are a
separate per-phone permission, persisted as `terminalPreviewAllowed` in that
phone's companion metadata. Old metadata without the field decodes to false;
existing pairings receive the full roster/status with no `lastOutputLine`, and
the Mac never reads a native surface for their requests while permission is off.
New registrations default off; the current Mac pairing approval explicitly
discloses and enables previews when the user clicks Allow. Terminal content may
be sensitive, including secrets printed by programs. The named **Terminal
previews for <phone>** switch in Mac Companion settings enables or disables it.

An authenticated phone may deliberately enable or disable its own previews
immediately with `set_terminal_preview`; no additional Mac approval is required.
The request's connection ID must match its paired certificate grant. For example:

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"set_terminal_preview","connectionID":"<uuid>","terminalPreviewAllowed":true}
```

Missing, null, numeric, string, or unrelated arguments are rejected. The Boolean
field is rejected on every other operation. The local bearer endpoint accepts
neither this operation nor this argument. `get_connection_status` includes the
current authenticated phone's `terminalPreviewAllowed` Boolean. A successful
mutation acknowledgement includes the usual response envelope and that Boolean,
with no roster, agents, or terminal content. Clients must read status again after
reconnecting or returning to foreground because the Mac switch may have changed.
An older Mac's absent status field means previews are unavailable/off; an
`unsupported_operation` mutation must not be treated as consent or success.

Permission changes rotate the connection revision and invalidate outstanding
requests before saving. The phone mutation revalidates its original certificate
and lease immediately before changing state, and its acknowledgement checks a
fresh post-change lease on every write. Revocation or another permission change
before the acknowledgement prevents that receipt. Repeating the current value
is idempotent and does not rotate a healthy grant. If saving fails, the affected
connection is denied for this run until Retry Save persists the requested
policy, matching the existing scope-change failure behavior. Other phones and
bearer grants retain their policy. Unpairing immediately revokes access.

Release dependency: the phone-side terminal-content privacy gate (p16),
including app-switcher blurring, must land before the phone list (p9) exposes
terminal content. Its deliberate switch uses the self-only operation above.
This change grants no live-terminal viewing scope. Watch access (m786) is
separate.

`list_panes` is Companion-only. It is absent from the local bearer API's
operation catalog and capabilities. It reuses the paired certificate's status
authorization, with scope filtering before terminal reads and the same
revocation/revision checks before response writes. It does not grant bearer
context, transcript, terminal history, document content, or input access;
Companion connections retain a nil `contextGrant`.

A successful response adds `workspaces`, in native sidebar group/workspace
order. Each workspace has `workspaceID`, `name`, and `panes`, in layout leaf
order. Every terminal leaf is included, including plain shells and split
terminals. A tabbed document group is one `documentGroup` leaf, identified by
its group ID; its title is the selected document's display title, or **Files**
for an empty browser. Document tabs are not separate layout panes.

```json
{
  "workspaces": [{
    "workspaceID": "<uuid>", "name": "Project",
    "panes": [{
      "paneID": "<uuid>", "kind": "terminal", "title": "Shell",
      "availability": "attached", "state": "idle",
      "lastOutputLine": "Build complete"
    }, {
      "paneID": "<uuid>", "kind": "documentGroup", "title": "Notes",
      "availability": "attached"
    }]
  }]
}
```

`availability` reuses the native classifier: `awaitingHydration`, `attached`,
`unavailable`, or `stale`. Terminal `state` reuses the native agent/shell
projection. Document groups have no terminal `state` or `lastOutputLine`.
Consumers should tolerate future kind, availability, and state values.

`lastOutputLine` is the last nonblank line of the terminal's current active
screen, independent of the Mac user's scrollback position. It may be a shell
prompt or program UI rather than a completed output record. The existing
Ghostty text reader reads only that screen, never scrollback or disk. Existing
display-string Unicode hygiene removes unsafe display scalars; the result is
capped at 512 UTF-8 bytes on a Character (extended grapheme cluster) boundary.
Lines that sanitize to empty are skipped. There is no promise to
recognize or redact secrets. A missing/detached surface, blank screen, or failed
read omits the preview; the API does not mount panes or reconstruct old output.
Only the sanitized, capped line (including an absent result) is cached per
native surface for at most 500 ms to coalesce repeated text extraction. A new
view, native-surface incarnation, or teardown discards the cached preview;
raw screen text is never cached by Companion. Scope checks precede sampling,
and cached previews still require certificate authorization and revocation
checks on response writes. Workspace metadata, pane status, and availability
are projected fresh on every request. The roster is a synchronous SessionStore
projection, with no separate live model, persistence, selection, or
attention-acknowledgment effects. The existing
256 KiB response limit remains in force: an oversized roster returns
`response_too_large` rather than silently omitting workspaces or panes.

### Response envelope

All UUIDs are standard hyphenated UUID strings. All dates are ISO 8601 strings
in UTC. Keys whose values do not apply are omitted rather than encoded as
`null`. Every successful response contains `schemaVersion`, the request's
`requestID`, the Mac's exact `profile`, a per-launch `appInstanceID`, and
`capturedAt`:

```json
{
  "schemaVersion": 1,
  "requestID": "01234567-89ab-cdef-0123-456789abcdef",
  "profile": "development:012345abcdef",
  "appInstanceID": "89abcdef-0123-4567-89ab-cdef01234567",
  "capturedAt": "2026-10-17T18:20:00Z"
}
```

An error response contains only `schemaVersion`, `error`, and `requestID` when
the request ID could be decoded. It does not disclose a roster, profile, or app
instance:

```json
{"error":"permission_denied","requestID":"<uuid>","schemaVersion":1}
```

The possible Companion error strings are `invalid_request`,
`unsupported_version`, `unsupported_operation`, `profile_mismatch`,
`permission_denied`, `request_too_large`, `response_too_large`, `timeout`,
`cancelled`, `stale_target`, `invalid_title`, `nonterminal_target`, `invalid_cursor`, and `transport_failure`. A TLS
authentication failure closes during the handshake and has no JSON reply. A
failure after part of a response has been written closes the connection; the
phone must discard that incomplete frame.

### `get_connection_status`

Current success adds `connectionStatus`:

```json
{"schemaVersion":1,"requestID":"<uuid>","profile":"<profile>","appInstanceID":"<uuid>","capturedAt":"<date>","connectionStatus":"connected"}
```

`connected` means this exact app instance is reachable and the paired
connection is still authorized.

#### V2 route metadata

A successful Companion `get_connection_status` response for a v2 grant may additionally
contain a `routes` object using the link vocabulary: `v` is `2`, `p` is the
shared port, and optional `lan` and `tailscale` fields contain at most one IPv4
literal each. Only current, eligible, successfully bound addresses are listed.
At least one route is required when `routes` is present. A v1 grant's response
omits `routes` and retains its original single-transport behavior.
For example, the complete response with both routes is:

```json
{
  "schemaVersion": 1,
  "requestID": "01234567-89ab-cdef-0123-456789abcdef",
  "profile": "development:012345abcdef",
  "appInstanceID": "89abcdef-0123-4567-89ab-cdef01234567",
  "capturedAt": "2026-10-18T18:20:00Z",
  "connectionStatus": "connected",
  "routes": {
    "v": 2,
    "p": 43123,
    "lan": "192.168.1.20",
    "tailscale": "100.100.20.30"
  }
}
```

The phone applies these rules as one atomic update:

- Accept metadata only in a complete successful response to its own
  `get_connection_status` request on the existing paired, mutually authenticated
  connection, after verifying the saved Mac SPKI pin and matching `requestID`.
  The Mac listener enforces its exact runtime profile as described above;
  pairing links do not carry a profile for the phone to pin.
- If `routes` is absent, retain the saved route set. This is the legacy Mac
  behavior; absence does not remove routes or imply v2 support.
- If present, validate the entire object before applying any of it. Each
  reported route kind replaces the saved route of that kind; a saved kind the
  reply omits keeps its last-known address, so a reply sent while one interface
  is still coming up cannot drop that route. Require `v: 2`, an integer `p` equal to the saved shared
  port, and valid addresses in the corresponding route-class ranges. Reject
  duplicate keys, empty strings, wrong types, unsupported versions, or any
  invalid entry as a whole; retain the previous set without applying a subset.
  The Mac enforces interface eligibility; the phone cannot infer remote
  interface ownership from an IPv4 literal.
- An empty route set, such as `{"v":2,"p":43123}`, is invalid. Retain the
  previous set so a transient interface removal/rebind cannot erase every
  retry address. If no eligible listener is ready, the Mac omits `routes`.
  Retaining an address permits only a later pinned connection attempt, never
  bypassing authentication or discovering replacements.
- Metadata never replaces the Mac pin, phone identity, connection ID, profile,
  or shared port. An error, incomplete frame, authentication failure, or
  profile mismatch cannot update any route or trust state.

A v2-capable phone keeps a persisted v1 pairing single-route until the person
explicitly re-pairs with a supported v2 link. It must not apply `routes` to a
v1 pairing, guess a second address, or infer a grant upgrade. Older phones
reject v2 links and continue using their existing v1 pairing.

### `unpair`

The phone asks to revoke its own grant with:

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"unpair","connectionID":"<paired-uuid>"}
```

The paired certificate must match this non-revoked connection ID, just as for
`get_connection_status`. No target ID or operation arguments are accepted. A
phone cannot revoke another phone, and this operation is not available on the
local bearer-credential API.

After revoking and saving the grant removal, success is the standard envelope
with no additional fields:

```json
{"schemaVersion":1,"requestID":"<uuid>","profile":"<profile>","appInstanceID":"<uuid>","capturedAt":"<date>"}
```

The Mac's Companion settings update immediately. Other requests on that grant
are denied or disconnected immediately; only this acknowledgement is allowed
to finish on the requesting connection. The connection then closes. Subsequent
connections fail TLS authentication (or are denied if a pairing window is open).
A wrong connection ID returns `permission_denied`; operation arguments return
`invalid_request`. Failure to save revocation returns `transport_failure` or
closes the connection, and the Mac keeps the existing persistence warning.

The phone waits at most three seconds for the entire attempt, including TLS.
It always removes its local pairing and key afterwards. If no valid success
arrives, it keeps a reminder to also choose Unpair in awesoMux Settings on the
Mac. This includes an unreachable Mac, an interrupted reply, and an older Mac
returning `unsupported_operation` or `permission_denied`. The older phone's
local-only unpair still works; its Mac grant must be removed in Mac Settings.

### `list_agents`

Success adds `agents`, which is an empty array when no agent is visible. Each
agent has this complete shape:

```json
{
  "paneID": "<uuid>",
  "workspaceID": "<uuid>",
  "workspaceName": "Project",
  "provider": "Codex",
  "executionLocation": "local",
  "availability": "attached",
  "state": "needsAttention",
  "attentionReason": "userInputRequired",
  "unreadCount": 1,
  "stateProvenance": "native_projection_with_provider_hooks",
  "observedAt": "2026-10-17T18:19:58Z",
  "capturedAt": "2026-10-17T18:20:00Z",
  "targetVersion": "<uuid>",
  "identityEvidence": "local_process_incarnation",
  "providerSessionID": "provider-defined-session-id",
  "capabilities": ["status"]
}
```

- `provider` is currently `Claude Code`, `Codex`, `OpenCode`, `Pi`, `Grok`,
  `Hermes`, or `Generic`. A client must preserve unknown future values.
- `executionLocation` is `local` or a provider-defined SSH destination.
- `availability` is `awaitingHydration`, `attached`, `unavailable`, or `stale`.
- `state` is `idle`, `running`, `waiting`, `thinking`, `output`,
  `needsAttention`, `done`, or `error`.
- `attentionReason` is optional. When present it is `bell`,
  `desktopNotification`, `permissionPrompt`, `userInputRequired`,
  `processError`, or `unknown`.
- `stateProvenance` is currently `native_projection_with_provider_hooks` or
  `native_inference_or_restore`. `observedAt` is optional and is present for a
  runtime-established state.
- `identityEvidence` is `local_process_incarnation` or
  `process_identity_unknown`. `providerSessionID` is optional.
- `targetVersion` changes when the pane's provider session identity changes.
  Companion cannot use it to request context; it lets the phone distinguish a
  new agent incarnation in the same pane.

### `get_attention_events`

Success adds an `attentionEvents` page:

```json
{
  "events": [
    {
      "id": "<uuid>",
      "attentionID": "<uuid>",
      "change": "raised",
      "paneID": "<uuid>",
      "workspaceID": "<uuid>",
      "provider": "Codex",
      "providerSessionID": "provider-defined-session-id",
      "targetVersion": "<uuid>",
      "occurredAt": "2026-10-17T18:19:58Z",
      "reason": "userInputRequired"
    }
  ],
  "nextCursor": "<opaque string>",
  "cursorStatus": "initial",
  "hasMore": false,
  "currentStateRecoveryRequired": false
}
```

`providerSessionID` and `resolvedAt` are optional. `change` is `raised` or
`resolved`. Raised and resolved records for the same alert share
`attentionID`; a resolved record includes `resolvedAt`. `reason` is the
attention-reason string recorded at the time of the event.

#### Command completion facts

Requests receive state-attention changes by default, protecting clients that
track every raised event as an open alert. Clients that understand command facts
must set `includeCommandEvents: true` on every page request to receive them
alongside state alerts. Omission, `null`, and false exclude command facts before
pagination, so they do not consume the requested page size or affect `hasMore`.
Non-boolean, non-null values return `invalid_request`.

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"get_attention_events","connectionID":"<uuid>","limit":100,"includeCommandEvents":true}
```

Cursors bind the stream's `includeCommandEvents` mode as well as the connection.
Omission and false use the same mode. Reusing a cursor with a different mode
returns `invalid_cursor`; to change modes, start a new stream without a cursor.
App-restart, access-change, and retained-history recovery keep their existing
behavior. Filtering does not change authorization scope or journal retention.
Filtered command facts still count toward the shared 512-change limit and can
cause `history_gap` recovery for state-only consumers.

Shell integration also records completed commands, including ordinary shell
panes. A known exit code of zero produces `reason: "commandFinished"`; a known
nonzero code produces `reason: "commandFailed"`. Only commands running strictly
longer than 30 seconds qualify in this first layer. Unknown exit status, zero
duration, and commands at or below the threshold produce no command event.
Ghostty supplies the measured duration in nanoseconds; the host converts that
measurement to seconds without using wall-clock differences. An initial prompt
without a preceding command start does not produce a Ghostty completion.

These events additionally contain `exitCode` (integer 0–255) and
`durationSeconds` (positive JSON number, possibly fractional). Both fields are
optional in the event schema and omitted for existing state-attention events.
For example, the additional fields of a failed command event are:

```json
{"change":"raised","reason":"commandFailed","exitCode":7,"durationSeconds":42.5}
```

Each qualifying completion is a separate fact with a new `id` and `attentionID`,
even when successive commands have the same status. It emits one `raised`
record, with no automatic `resolved` record: completion does not imply that a
person has acknowledged the alert. Consumers must not wait for a resolution or
treat command facts as the pane's current state. Future acknowledgement or
notification delivery is outside this contract.

Command facts do not replace active state-attention alerts. Permission/state
resolution continues to reference its own attention ID; unrelated state writes,
focus changes, and target replacement do not resolve or replay command facts.
Completions neither change Mac unread state nor depend on which pane is focused.
Events retain the workspace, provider/session identity and target version at
recording; a deferred callback from a replaced surface or terminal assignment is
discarded. Existing scope filtering, cursor ownership and 512-change retention
apply unchanged. History-gap recovery cannot reconstruct discarded command
facts from `list_agents`; the phone must accept that historical gap.

The existing `list_agents` operation still excludes ordinary shells in this
layer. Shell completion events use provider `Shell`, no provider session ID,
and the pane's target version. Persistent pane/workspace and Companion scopes
can read these facts; this change does not broaden exact-agent-target grants
or the roster. The pane-list layer supplies separate shell discovery.

The first call omits `cursor`. Save `nextCursor` only after applying the page.
When `hasMore` is true, immediately request another page with that cursor.
`cursorStatus` has these meanings:

| Value | Phone behavior |
| --- | --- |
| `initial` | First page; apply its events. |
| `current` | Cursor was valid; apply its events. |
| `history_gap` | Retained history no longer reaches the cursor. |
| `app_restarted` | The cursor belongs to a previous Mac app instance. |
| `access_changed` | The paired connection's authorization revision changed. |

The last three statuses return no events, set
`currentStateRecoveryRequired` to `true`, set `hasMore` to `false`, and provide
a fresh cursor at the current end. Call `list_agents` to replace the phone's
current state, then resume with that fresh cursor. A malformed, altered,
future-position, or other-connection cursor returns `invalid_cursor`; discard
it and explicitly start again without a cursor if the person wants a new
baseline. Reads do not consume another phone's history and do not change Mac
selection or unread state.

## Confirmation word list

`W` is the following 256-entry zero-based list. Its UTF-8 file form has one word
per line and SHA-256
`f6f1e4790020080d78f10fce0413354ae2ee81a310a51a89cda5fe230b78682a`.

```text
acorn
actor
adobe
agent
alarm
album
alley
amber
anchor
angle
ankle
apple
apron
arch
arrow
aspen
atlas
attic
autumn
bacon
badge
bagel
baker
balloon
bamboo
banana
banjo
barn
basil
basket
beach
beacon
bean
bear
beaver
bell
berry
bicycle
birch
biscuit
blanket
blossom
boat
bonnet
book
boot
bottle
boulder
bow
bracelet
branch
bread
breeze
brick
bridge
brook
broom
bubble
bucket
butter
button
cabin
cactus
cake
camel
camera
candle
canoe
canyon
captain
carpet
carrot
castle
cedar
cello
chair
chalk
cherry
chess
chimney
cider
circle
citrus
clam
cliff
clock
cloud
clover
coast
cobalt
cocoa
comet
compass
cookie
coral
cotton
cradle
crane
crayon
cricket
crystal
curtain
daisy
dancer
delta
desert
diamond
dinner
dolphin
donut
dragon
drum
dune
eagle
easel
echo
elbow
ember
engine
falcon
feather
fern
ferry
fiddle
field
fig
flag
flame
flute
forest
fossil
fountain
fox
garden
garlic
gazelle
geyser
ginger
glacier
globe
glove
goose
granite
grape
harbor
harp
hazel
helmet
heron
hill
honey
hornet
igloo
island
ivory
jacket
jaguar
jelly
jewel
jungle
kayak
kettle
kitten
kiwi
koala
ladder
lagoon
lamp
lantern
lemon
lily
lime
lion
lizard
llama
lobster
locket
maple
marble
meadow
melon
mitten
moose
mosaic
moss
mountain
muffin
mushroom
nectar
needle
nest
noodle
nutmeg
oak
oasis
ocean
olive
onion
orange
orbit
orchid
otter
owl
paddle
panda
paper
parrot
pasta
peach
peanut
pebble
pencil
penguin
pepper
piano
pickle
pillow
pine
planet
plum
pocket
pony
poppy
potato
pretzel
pumpkin
puzzle
quail
quartz
quilt
rabbit
radish
rainbow
raven
reef
ribbon
river
robin
rocket
rose
saddle
salmon
sandal
sapphire
scarf
seal
shell
sierra
silver
sketch
sled
snail
sparrow
spruce
squash
stable
```

## Per-device alert delivery (#791)

The shared [alert preference contract](https://github.com/Interactive-Buffoonery/awesomux-companion/blob/850c0c923543c4161bd78dbce651ad5739bc9bbe/docs/protocol/alert-preferences.md)
adds `get_alert_preferences` and `set_alert_preferences` to the certificate-authenticated
listener. Both address only the authenticated pairing. Get accepts no operation
arguments; set accepts only `alertPreferences: {"categories": [...]}`. The categories
are `permission`, `waiting`, `error`, `commandFailed`, and `commandCompleted`.
An empty set disables these categories; generic bell, desktop-notification and
unknown reasons remain eligible. Command events still require `includeCommandEvents`.

Preferences are optional in the paired grant metadata in `access.json`; missing
means all categories. An effective change saves the grant before publishing a new
revision and invalidating outstanding requests. Save failure preserves the previous
preferences and authority. An identical set does not rotate the revision. Existing
attention cursors recover with `access_changed` after an effective change.

At event creation the Mac samples the actual pane surface: only a visible, focused
terminal on the active, visible app and unlocked console suppresses a raised event
for companions. Hidden, minimized, occluded, unfocused and inactive surfaces remain
eligible. This sample stays in the runtime journal and is not recomputed when a
phone polls. Category and presence filtering consume journal positions even for
empty pages. Resolutions remain available so previously shown alerts can clear.
Local bearer consumers retain the complete journal under their existing scopes.

Delivery uses direct LAN/Tailscale polling. Phone settings UI and push delivery
remain follow-up work.

For focused persistence, journal and event-time store verification, run
`heavy-gate swift run companion-pairing-e2e --alert-preferences-only`.
The full `heavy-gate ./script/run_companion_pairing_e2e.sh` also checks strict
preference arguments and self-only access over pinned mutual TLS. Its isolated
store fixture retains its diagnostic directory and prints the path. These host
cases do not prove native focus, visibility or lock transitions; exercise those
with the worktree app separately.
## Scoped permission decisions

`list_pending_decisions` and `decide` are Companion-only operations, separate
from the bearer local API. They require a default-off Decide grant on the Mac
for explicitly selected workspace IDs. Pairing, previews, status and pane
renaming never grant decision access. Grant changes rotate the connection
revision; deleting a workspace removes its grant.

The shared protocol's `CompanionDecisionIdentity` binds runtime instance,
workspace, pane, target version, provider session, hook invocation and request
revision. `decide` accepts `decisionAnswer` containing that complete identity,
a once-only `allow`/`deny` choice and UUID retry ID. Unknown fields and unrelated
operation arguments are rejected. Pending projections come from the authoritative
core, including queued hooks that are not the currently displayed Mac card.
Only bounded review text from verified hook ingress is shared.

The core commits the first valid app answer atomically. Retry IDs bind device,
identity and choice. An identical retry returns the original `decisionReceipt`;
conflicting reuse and losing answers cannot overwrite the winner. Fresh lists
return retained `decisionOutcomes` for later recorded/delivery/terminal state.
The remote deadline keeps its wire date and a monotonic bound on the remaining
window at admission, at most 60 elapsed seconds, with a helper return reserve.
Both deadlines must remain live; clock rollback cannot extend device authority.
Remote expiry leaves the Mac answer window intact. Bounded receipts survive
until hook expiry plus ten minutes. Unknown identities also bind their retry
ID for at most ten minutes, bounded by both wall and monotonic clocks; capacity
exhaustion refuses new retry IDs. Cache expiry never recreates a request. Recorded means the core accepted an answer; delivered requires a
helper ACK and does not prove provider execution.

Scope, exact target, device certificate and revisioned grant are checked before
commit, each response chunk, actual socket delivery and every file publication
attempt. Revocation cancels a known-unsent remote answer; an answer that may
have escaped becomes unknown. Neither state reopens for a second answer.

**Release gate:** no provider/version is enabled for real remote decisions.
ADR-0038 requires interactive native-prompt races in both orders before that
can change. The pairing harness uses a separate synthetic coordinator with no
provider hook consumer. Its list/answer fixtures cannot enable production
requests, establish Claude race behavior or prove iPhone UI.
