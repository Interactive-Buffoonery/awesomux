# 0035 — Pair awesoMux Companion through the local agent API

- **Status:** Proposed
- **Date:** 2026-10-17
- **Amended:** 2026-10-18 — one pairing with LAN and Tailscale routes (#782)

## Context

awesoMux Companion is a read-only iPhone app showing agent status, alerts, a
widget, and a Live Activity. Its prototype reached the Mac through a Python
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

**One pairing carries up to two routes.** The planned v2 pairing link carries
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
authenticated `get_connection_status` response may replace the whole route set,
so a DHCP change need not require re-pairing when another saved route is still
reachable. If all routes are unreachable, the phone remains offline; it does
not discover arbitrary replacement addresses or change trust after an identity
failure. The [pairing protocol](../companion-pairing-protocol.md) defines the
v2 link, route metadata, and legacy v1 rules.

This amendment is a planned contract, not shipped behavior. Mac listeners and
current-address reporting are implementation work in #783; phone v2 parsing,
persistence, and route selection also need support. The current implementation
uses a v1 link with one chosen transport. There is no silent v2 downgrade or
reinterpretation. Framed pairing messages and the local API schema remain v1.

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

**The wire is the existing contract.** Inside TLS the listener accepts the
same framed v1 requests, limited to `get_connection_status`, `list_agents`,
and `get_attention_events`, and applies the same bounds, leases, and per-write
authorization. A paired phone's key replaces the bearer credential. The phone
groups agents and drives its widget and Live Activity from those responses. No companion-specific status contract or relay
exists on the Mac.

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
