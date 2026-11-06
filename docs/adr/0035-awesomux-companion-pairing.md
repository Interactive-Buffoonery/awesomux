# 0035 — Pair awesoMux Companion through the local agent API

- **Status:** Proposed
- **Date:** 2026-10-17
- **Amended:** 2026-10-18 — one pairing with LAN and Tailscale routes (#782)
- **Amended:** 2026-10-20 — per-device terminal, decision and transcript grants (see Amendment)
- **Amended:** 2026-10-20 — Companion-only pane roster and bounded previews (#785)

## Context

awesoMux Companion shows agent status, alerts, a widget, and a Live Activity
on iPhone. Paired phones remain read-only unless the Mac user explicitly
enables terminal-pane renaming for that phone. Its prototype reached the Mac through a Python
relay that called `awesomux-agent` with a manually created Outside app access
grant. That works, but pairing a phone should take one scan, not a grant
editor, a connection UUID, and a script.

The local agent API already owns the authority this needs: per-connection
credentials, revisioned leases, revocation, global access, bounded requests,
and the alert history with recoverable cursors. Its endpoint is a same-user
Unix socket. A phone needs a network listener, which is a new exposure.

## Decision

Add an **awesoMux Companion** Settings pane, visible in every build with an
**Alpha** capsule. It links to the awesoMux Companion TestFlight, shows a
pairing QR code, and lists paired phones.

**A paired phone is a companion connection in the local agent API.** It is
stored with other grants in `access.json` and uses the same leases and
revocation, with a new all-workspaces status scope. Phones are managed only in
the Companion pane: they do not appear under Outside app access and do not
depend on its global switch, which is unreleased. Unpairing is revocation.
Context sharing is not offered to phones.

**Pane renaming is a separate opt-in.** The Mac's per-phone **Allow pane
renaming** control stores an optional `paneRenameScope`; absent means denied,
including existing and newly paired phones. A rename must satisfy both that
scope and the phone's status scope. Preview permission never grants mutation
authority. Only terminal panes can be renamed, using native pane and workspace
UUIDs and `SessionStore.renamePane`. [ADR-0042](0042-phone-terminals.md) adds
creation under Terminal and Input authority; close, document-group rename and
workspace rename remain outside this layer (#795). Recheck the certificate
and original revisioned lease at the synchronous MainActor mutation, holding the
authority lock through the store change. Cancellation or an expired request
deadline prevents a pending mutation. Policy changes invalidate outstanding
leases before saving and deny the phone for the run if saving fails.

**One pairing carries up to two routes.** The v2 pairing link carries
one LAN IPv4 address and one Tailscale IPv4 address, omitting unavailable
routes and requiring at least one. Both use the same stable port, Mac identity,
phone grant, and exact runtime profile. The app binds only the listed private
addresses, never a wildcard, and listens only while a phone is paired or the
QR code is showing. It does not advertise over Bonjour.

A v2 grant authorizes either eligible route; the address used to pair does not
restrict it to that transport. Existing v1 grants retain their chosen transport
and require explicit re-pairing with v2 to authorize both. Persistence must
distinguish those policies and preserve v1 grants without silently broadening
their exposure. Route metadata alone cannot upgrade a v1 grant.
V1 and v2 grants may coexist within one runtime profile, sharing its existing
stable port; adding a v2 phone must not change a v1 phone's port or transport
restriction.

LAN eligibility is RFC1918 on an UP, non-loopback, non-tunnel, non-bridge
interface. Tailscale eligibility is 100.64/10 on an UP, non-loopback `utun`
interface; this convention is not proof of Tailscale ownership. Both require
an assigned unicast IPv4 address. Public, wildcard, link-local, multicast,
broadcast, and other tunnel addresses are excluded. Choose at most one bound,
advertised address per class, preferring `en0`, then interface name, then
numeric IPv4 address for stable ties. Re-evaluate network changes and remove
ineligible or removed addresses; never fall back to a wildcard. IPv6, DNS,
Bonjour, and other VPN support are outside this decision.

The phone tries LAN first, then Tailscale, verifying the same SPKI pin on either
route before sending a secret or API request. On network change or foreground,
it prefers LAN again with a cooldown to prevent flapping. A pinned,
authenticated `get_connection_status` response updates each route kind it
reports and keeps the last-known address of any kind it omits, so a DHCP change need not require re-pairing when another saved route is still
reachable. If all routes are unreachable, the phone remains offline; it does
not discover arbitrary replacement addresses or change trust after an identity
failure. The [pairing protocol](../companion-pairing-protocol.md) defines the
v2 link, route metadata, and legacy v1 rules.

Mac listeners and current-address reporting implement this contract in #783.
Phone v2 parsing, persistence, and route selection still need phone-side support.
There is no silent v2 downgrade or reinterpretation. Framed pairing messages
and the local API schema remain v1.

**Both sides authenticate with pinned keys.** The listener requires mutual
TLS 1.3. The Mac's identity is a self-signed key in its Keychain. The phone
generates a non-exportable key in its Secure Enclave. Each side pins the
other's public key at pairing, and the Mac drops any handshake without a
paired phone key before reading a request. The Mac stores only the phone
key's fingerprint in `access.json`; no persistent shared secret exists. Failed
handshakes are rate-limited.

**Pairing is a one-time exchange with confirmation.** The QR code holds the
available route addresses, shared port, the Mac key's fingerprint, and a
single-use pairing secret that expires after five minutes or when the sheet closes, encoded as
an `awesomuxcompanion://pair` link. The system Camera can open it, and
**Copy Link** lets people paste it on the phone instead of scanning. The phone
connects, proves the secret, and presents its public key. Both devices then
show three words derived from both keys, and the Mac asks the user to allow
the named phone. A photographed QR code cannot pair without that click.
All listeners share one secret, consumed atomically by the first valid attempt;
concurrent attempts through different routes cannot create separate approvals
or grants. Unpairing or revocation invalidates the shared grant on every route.

**The wire reuses the existing framing and authorization.** Inside TLS the
listener accepts framed v1 requests for `get_connection_status`, `unpair`,
`list_agents`, `get_attention_events`, and Companion-only `list_panes` and
`set_terminal_preview`, plus separately Mac-approved `rename_pane`, with the
same bounds, leases, and per-write authorization. A paired phone's key replaces
the bearer credential. The #785 amendment adds an ordered workspace/pane roster
and a bounded last-output preview from each terminal's active screen; it does
not expose previews through the local bearer API or grant context/history.
The shared wire DTOs and current payload/privacy rules are defined in the
[pairing protocol](../companion-pairing-protocol.md#pane-roster-and-terminal-content-access).
Terminal previews default off for existing pairings. Explicit Mac pairing
approval or the named per-phone Mac switch can enable them; an authenticated
phone can also enable or disable only its own previews through
`set_terminal_preview` without further Mac approval. Permission revisions and
per-write authorization protect both previews and mutation acknowledgements.
The phone-side content gate remains a release requirement there. No relay or parallel workspace model is introduced. The amendment below defines
additional independently granted capabilities.

**Delivery is pull-only in this stage.** The phone reads while open and when
iOS grants background time, and posts local notifications for new alerts.
iCloud (CloudKit) delivery and a hosted relay may follow as additional
transports for the same paired connection; each needs its own ADR because
they change signing or data custody.

## Consequences

- Phones reuse the existing grant engine and denial behavior without
  exposing Outside app access, which stays hidden in release builds.
- awesoMux gains its first network listener. Unpaired devices cannot get
  past the TLS handshake, but anyone with reachability to either listed address
  can attempt to flood the port. A genuine Tailscale route limits reachability
  to the user's tailnet; the interface eligibility convention alone does not
  guarantee that. LAN exposure is suited to trusted networks.
- The first pairing shows the macOS and iOS Local Network permission prompts.
- Without push, alerts are late or missing while the phone app is suspended,
  and the Live Activity updates only when iOS runs the app. The Alpha label
  stays until a push-capable transport ships.
- The prototype's Python relay and its glance contract are retired.
- ADR-0019 is unchanged: the app is not sandboxed, so listening needs no
  entitlement. Physical-device and TestFlight builds of the iPhone app need
  Developer Team signing.

## Amendment (2026-10-20): per-device capability grants

The status-only operation limit above is extended by capabilities that each
need a separate, default-off, Mac-approved grant per paired phone. Pairing
identity, mutual TLS, route rules, leases and revocation are unchanged, and
none of these grants is implied by pairing or by another grant:

- **Terminal** ([ADR-0036](0036-multi-client-terminal-leadership.md)): Mac-approved
  access to a specific pane, defaulting to Watch, with a separate input grant.
- **Decide** (ADR-0038, #793):
  pending-decision reads and once-only answers for Mac-selected workspaces.
- **Transcript** (ADR-0039, #829):
  `get_agent_context` with `source: transcript` for Mac-selected workspaces.

Each grant is stored with the companion connection, is removed by unpairing or
revocation, and is enforced on the Mac rather than by hiding phone controls.
ADR-0038 and ADR-0039 land in their own pull requests; this amendment covers
all three so the scope change is recorded once.
