# awesoMux Companion pairing protocol

This document is the complete Mac-to-iPhone pairing, read-only API, and self-unpair contract.
All integers are decimal unless a representation is stated explicitly.

V1 wire DTOs, framing, link syntax, and confirmation words live in the root
`AwesoMuxCompanionProtocol` package in `awesomux-companion`. This app pins an exact
package release in `Package.swift` and `Package.resolved`; TLS and authorization
remain local. Package versions do not change wire versions.

The v1 link and framed protocol below describe the current implementation.
The v2 link and route metadata are the planned #782 contract, pending Mac
listener/current-address support in #783 and corresponding phone support.
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

### Legacy v1 (currently implemented)

The QR code and **Copy Link** action currently contain exactly this URL:

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

### v2 (planned)

The QR code and **Copy Link** action will contain this fixed shape:

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

The planned listeners retain the current IPv4 route-class boundaries:

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
- `get_attention_events`, with required positive `limit` (maximum 100) and an
  optional non-empty `cursor` of at most 2,048 UTF-8 bytes.

`get_agent_context`, `get_capabilities`, all input operations, context fields,
and bearer credentials are denied. The connection ID must be the value returned
by `paired`, and the presented certificate fingerprint must still match that
non-revoked connection. Unpairing revokes it immediately. Companion access is
independent of the Mac's Outside app access switch.

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
`cancelled`, `stale_target`, `invalid_cursor`, and `transport_failure`. A TLS
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

#### Planned v2 route metadata

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
- If present, validate the entire object before replacing the whole saved set,
  never merging it. Require `v: 2`, an integer `p` equal to the saved shared
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
