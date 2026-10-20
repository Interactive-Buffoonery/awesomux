# 0037 — An opt-in sealed push relay

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** Sarah
- **Issue:** [#789](https://github.com/Interactive-Buffoonery/awesomux/issues/789)

## Context

[ADR-0035](0035-awesomux-companion-pairing.md) defines direct pinned mutual TLS
and pull-only delivery. iOS background reads cannot promise timely alerts.
Push introduces a service outside the Mac, so custody and removal must be
explicit. This is a proposed extension to that delivery boundary, not a change
to the direct API transport or its allowed operations. Sarah must accept it first.

## Options considered

- **Polling only:** no hosted custody or operating cost; alerts remain best-effort
  while the app is suspended. Keep this as the fallback.
- **CloudKit:** uses Apple's infrastructure, but ties delivery to Apple account
  availability and adds a second synchronization model.
- **Sealed APNs relay (recommended):** timely notification delivery without
  plaintext at the relay; adds service operations and visible routing metadata.

## Decision

**Recommendation:** make sealed push opt-in per pairing. The Mac chooses when
and what to notify; the relay authenticates, limits and forwards an encrypted
envelope to APNs. It is content-blind, not literally stateless.

### Custody and retention

| Location | Allowed data | Lifetime |
| --- | --- | --- |
| Mac | Pairing-bound push encryption material, sender and pending-deletion credentials, route ID; alert content, presence, filters and source event history | Keys/credentials until opt-out or unpair; event history follows the Mac's separately bounded local policy |
| Phone / notification extension | Decryption key in a shared Keychain group, available only while unlocked; recipient registration/revocation credential, APNs token, pairing/epoch and replay state | Until opt-out/unpair; replay state bounded by the envelope expiry window |
| Relay | APNs provider signing credential; random route ID, APNs token, pairing-specific sender and recipient verification keys, expiry, revocation epoch and bounded replay/rate counters | Registration expires after 30 days without authenticated renewal; removal on opt-out/unpair; dedupe at most the 5-minute envelope lifetime |
| Relay transit | Ciphertext and delivery result | Memory only for one bounded APNs attempt; no durable alert queue or content archive |
| Relay operations | Allowlisted attempt count and latency buckets by fixed delivery outcome only; no request bodies, tokens, route IDs, IPs or device identifiers in logs | Aggregate metrics up to 7 days; infrastructure logging must honor the same exclusions before launch |

The service can observe IP addresses, device routing, timing and sizes; encryption
does not hide those. A shared APNs token also links pairings from different
Macs to the same app installation. APNs retains its own delivery metadata and
may queue the
sealed payload until its expiry. Do not promise immediate erasure from APNs or
already delivered notifications. No account, pane name, terminal output,
transcript, decision content or decryption key belongs in relay storage.
A compromised relay can send spoofed plaintext pushes, drop/delay delivery and
observe metadata. It cannot decrypt genuine envelopes, forge authenticated
content or authorize a direct API action. Never trust a push as an instruction.

[ADR-0008](0008-privacy-boundaries-for-diagnostics-and-feedback.md) continues to
bar automatic client diagnostics. These proposed relay-only operational metrics
are disclosed in push consent, contain only the table's allowlist, expire after
seven days and have no per-user identifier to delete. Operator/hosting provider
and measured client cost must be recorded before implementation ships; this
proposal does not authorize a separate analytics provider or client telemetry.

### Registration and delivery

- Negotiate push after authenticated pairing, Mac-side opt-in and phone-side
  recipient confirmation; iOS notification permission is a separate requirement.
  Exchange a
  fresh per-pairing content key (or equivalent public-key sealing material)
  through ADR-0035's pinned mutual-TLS channel. Never reuse the QR secret, TLS
  private key
  or local API credential. Existing pairings remain pull-only until enrolled.
  This explicitly extends ADR-0035's no-persistent-shared-secret statement for
  optional push encryption only; it does not change mutual TLS authentication.
- Bind registration to both the phone's recipient authorization and the Mac's
  sender key. Require proof of possession and recipient confirmation; knowing
  an APNs token is not authority to send. A Mac credential authorizes only its
  registered pairing route. Token rotation must be authenticated and cannot
  transfer authority to another recipient. Exact enrollment and cryptographic
  formats require security review before implementation ships. Bound enrollment
  and renewal work as well as sends, with per-IP and global limits; do not expose
  an unbounded registration endpoint. App attestation is a separate hardening
  choice, not a substitute for pairing authority.
- Authenticate envelopes with a standard authenticated-encryption construction,
  unique nonces, version, pairing epoch, event ID and expiry bound to the
  ciphertext. Sign the outer routing/expiry fields for relay verification.
  Reject unknown, expired or revoked senders, duplicate IDs and invalid sizes;
  apply bounded per-route and per-sender limits before forwarding. The phone
  independently verifies authentication, expiry, epoch and replay state.
- Recommend a five-minute maximum lifetime and no relay retries. A Mac retry
  uses the same event ID and expiry; uncertain delivery is not a new alert.
  Relay acceptance means attempted delivery, not that the phone displayed it.
- Keep presence gating and filters on the Mac. A notification is a hint; opening
  it refreshes current state through the direct connection. No terminal stream,
  transcript fetch or future input/approval operation is carried through it.
- Default lock-screen text is **Open awesoMux**, even if decryption succeeds.
  Detailed previews require a separate user choice. Failed decryption or locked
  key storage produces only that generic text. Recommend unlock-only decryption
  keys in v1, so detailed content waits for unlock even when previews are enabled.
  Replay, expiry and revocation checks prevent using stale content; they do not
  promise suppression of an OS notification. A delayed generic alert may still
  appear after opt-out or unpairing.

### Removal and failure

The phone renews registration while directly connected to the paired Mac; the
Mac cannot renew indefinitely on its behalf. After 30 days without renewal,
push pauses until re-enrollment. An APNs invalid-token result deletes the route.
Either endpoint may revoke its route with its own authenticated credential.
Opt-out/unpair deletes local push material and requests relay deletion of the
token, sender/recipient verification keys and route. Keep only a bounded local deletion credential/job
until confirmed or the 30-day registration expiry; show removal as pending when
offline. Stop sending immediately. Revoked routes cannot be renewed or recreated
with old credentials; new enrollment requires fresh recipient confirmation.
Delete replay/rate state with the route. In-flight APNs delivery may still occur;
the phone refuses stale content after revocation and removes local notifications
when it learns of unpairing. No cloud backup may retain deleted route records.

If the relay or APNs is unavailable, direct access still works and polling stays
best-effort. Do not replay old alerts after recovery or widen notification consent.

## Consequences

The service needs abuse controls, credential rotation, a deletion path and an
operator before release. Encryption limits content exposure, not traffic analysis
or denial of service. Delivery, retention, unpairing while offline and locked-phone
key access need future verification; this record supplies no runtime evidence.

## Open questions for Sarah

1. Choose the opt-in sealed relay, keeping polling as the fallback?
2. Accept five-minute alerts, no durable relay queue, 30-day registration expiry
   and seven-day aggregate metrics, including pending deletion while offline?
3. Keep unlock-only keys and generic locked-phone previews, accepting that stale
   generic notifications may still appear? Accept token linkage across Macs and
   spoofed-push risk on relay compromise?
4. Use phone-owned renewal (push pauses after 30 days away), and who owns the
   service/hosting and its bounded operational metrics before release?
