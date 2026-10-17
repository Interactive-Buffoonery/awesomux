# 0035 — Pair awesoMux Companion through the local agent API

- **Status:** Proposed
- **Date:** 2026-10-17

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

**Transport is chosen per QR code.** The pane offers **Local network** or
**Tailscale**. Tailscale is offered only when the Mac has a Tailscale address.
The app listens on the chosen interface only, never on all interfaces, and
only while a phone is paired or the QR code is showing. It does not advertise over Bonjour.

**Both sides authenticate with pinned keys.** The listener requires mutual
TLS 1.3. The Mac's identity is a self-signed key in its Keychain. The phone
generates a non-exportable key in its Secure Enclave. Each side pins the
other's public key at pairing, and the Mac drops any handshake without a
paired phone key before reading a request. The Mac stores only the phone
key's fingerprint in `access.json`; no shared secret exists. Failed
handshakes are rate-limited.

**Pairing is a one-time exchange with confirmation.** The QR code holds the
host, port, profile, the Mac key's fingerprint, and a single-use pairing
secret that expires after five minutes or when the sheet closes, encoded as
an `awesomuxcompanion://pair` link. The system Camera can open it, and
**Copy Link** lets people paste it on the phone instead of scanning. The phone
connects, proves the secret, and presents its public key. Both devices then
show three words derived from both keys, and the Mac asks the user to allow
the named phone. A photographed QR code cannot pair without that click.

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
  past the TLS handshake, but anyone on the chosen network can reach the port
  and attempt to flood it. Tailscale limits reachability to the user's
  tailnet; local network mode is suited to trusted networks.
- The first pairing shows the macOS and iOS Local Network permission prompts.
- Without push, alerts are late or missing while the phone app is suspended,
  and the Live Activity updates only when iOS runs the app. The Alpha label
  stays until a push-capable transport ships.
- The prototype's Python relay and its glance contract are retired.
- ADR-0019 is unchanged: the app is not sandboxed, so listening needs no
  entitlement. Physical-device and TestFlight builds of the iPhone app need
  Developer Team signing.
