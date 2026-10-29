# 0040 — A snapshot-first stream for live terminals

- **Status:** Accepted
- **Date:** 2026-10-20
- **Accepted:** 2026-10-20 — Sarah accepted the recommendation as written
- **Amended:** 2026-10-26 — lazy-pane opening and initial phone claims (ADR-0042)
- **Deciders:** Sarah
- **Issue:** [#826](https://github.com/Interactive-Buffoonery/awesomux/issues/826)

## Context

The companion wire is one request and one reply per connection, with a
5-second timeout, an 8 KiB request limit and a 256 KiB response limit
(`LocalAPIContract.swift`, [pairing protocol](../companion-pairing-protocol.md#framing)).
A live terminal cannot fit that shape: output is unbounded in time and size,
and the phone must learn about grid and leader changes as they happen.

[ADR-0036](0036-multi-client-terminal-leadership.md) settles who leads and
resizes, requires ordered live output after a fresh snapshot that identifies
its session generation and grid, and asks this record to account for the
nested emulator boundary. [ADR-0039](0039-read-only-device-transcripts.md)
shows the consent and recheck shape for a bounded device read. The Companion
[snapshot findings](https://github.com/Interactive-Buffoonery/awesomux-companion/blob/main/spikes/snapshot-reconnect/README.md)
(#17) show that a zmx attach returns retained cells, not a byte journal: prompt
marks, soft wraps, cursor edits and exit codes do not survive. The renderer
spike (companion #30) proved libghostty can render fed bytes on a device.

Sarah's standing decisions apply: no hosted relay for now, and the direct
LAN/Tailscale connection from [ADR-0035](0035-awesomux-companion-pairing.md)
comes first. Watch-only roles and explicit takeover in the zmx fork are #827.
This is a docs-only decision; no listener, frame or daemon change ships with it.
Sarah accepted this record on 2026-10-20; it is now policy for that work.

## Options considered

- **Poll a snapshot endpoint:** fits the existing one-shot wire, but every
  refresh costs a full scrollback serialization and output between polls is
  invisible, so progress bars and TUIs cannot be watched.
- **Tee the Mac surface's bytes:** reuses the pane's own client, but ties the
  phone to that pane's libghostty state and client lifetime, and the Mac's
  surface has no snapshot to offer a late joiner.
- **One dedicated zmx client per stream, snapshot first, then ordered output
  (chosen):** the daemon already serializes a snapshot at attach and then
  forwards output on the same connection, so ordering is free; the Mac relays
  that client's bytes over the paired connection.
- **Resumable stream with replay from a sequence number:** avoids a second
  snapshot after a short drop, but needs a per-stream journal on the Mac and a
  gap policy; the daemon snapshot already covers the catch-up case.

## Decision

**Decision:** add a `watch_terminal` operation that converts one paired
connection into a long-lived terminal stream backed by a dedicated zmx client
the Mac opens for that device and pane. The stream always begins with a
snapshot, then carries output in daemon order. Every reconnect is a new attach
with a new snapshot. Nothing is replayed, and no stream crosses a relay.

[ADR-0042](0042-phone-terminals.md) adds authorized lazy-pane hydration before
acceptance and changes the phone's Input-on opening default to a fresh `claim`
after the snapshot. The stream format and daemon attach semantics are unchanged.

### Stream source and the emulator boundary

- For each accepted stream the Mac relay attaches its own zmx client to the
  pane's session in the Watch role from #827, or the interactive role when the
  device holds an input grant. The phone receives exactly what that client
  receives: the daemon's reconstructed snapshot, then live PTY output.
- The stream is not taken from the Mac surface's libghostty state. The Mac
  pane, a follower Mac surface and the phone are sibling clients of one daemon
  terminal model; selection, theme, scrollback limits and host effects of the
  Mac emulator are not involved. This is the nested emulator boundary: the
  daemon model is authoritative, each client re-emulates its bytes, and a
  client never reads another client's grid.
- The Mac relay never exposes the zmx socket, forwards arbitrary zmx messages
  or passes bytes from a Watch stream to the PTY. The daemon enforces the role
  as well ([ADR-0036](0036-multi-client-terminal-leadership.md)).

Remote-owned panes use a local amx carrier for their SSH connection when
available. The phone joins that carrier as a sibling client, using the same
snapshot, output, input, grid and leadership relay. Only direct-SSH fallback
panes lack a local stream source and report Watch/`remote_pane` followed by
`pane_unavailable`.

### Handshake and versioning

- The phone sends a standard v1 request frame, operation `watch_terminal`, with
  `paneID`, `targetVersion`, `streamVersion` and its preferred grid. The Mac
  checks the Terminal grant for that device and pane (default Watch, separate
  input grant), the lease, route rules and the pane's live zmx session, then
  replies with the standard envelope. On success the reply carries the accepted
  role and `streamVersion`, and the same TLS connection switches to stream
  framing; the 5-second request timeout ends with that reply.
- `get_capabilities` advertises `terminalStream: 1` and the stream limits below.
  An unknown or unsupported `streamVersion` returns `unsupported_version`. The
  framed API stays `schemaVersion: 1`; the stream has its own integer version
  that changes only for an incompatible frame layout. Within a version,
  unknown control fields are ignored and an unknown frame type closes the
  stream with an error rather than being skipped.
- Stream frames reuse the four-byte big-endian length prefix. The first byte
  of each frame is its type. Control frames (`snapshot_begin`, `snapshot_end`,
  `grid`, `leader`, `claim`, `heartbeat`, `end`, and `ack`) carry UTF-8 JSON.
  Data frames (`snapshot` chunk, `output`, `input`, `reply`) carry an eight-byte
  sequence number and raw bytes; terminal bytes are never base64-encoded or
  re-framed as JSON. Every frame after `snapshot_begin`, in both directions,
  carries the four-byte generation ID. `input` is what the person typed or
  pasted; `reply` is a terminal-generated answer to a query (for example DSR).
  Only `input` can claim leadership; the Mac forwards a `reply` only from the
  current leader's stream and drops queued replies when the leader or the
  stream's role changes (ADR-0036).

### Snapshot, then output

- A new **generation** starts whenever the Mac relay attaches a zmx client:
  first attach, reconnect, resync after overflow, and daemon or app restart.
  `snapshot_begin` carries the generation ID, pane ID, target version, grid,
  current leader, `historyIncomplete: true` and the daemon's scrollback bound.
  Snapshot chunks follow, then `snapshot_end`, then `output` frames. No
  `output` is sent before `snapshot_end`, and sequence numbers restart at zero
  for each generation.
- The phone renders into a model at the snapshot grid, labels earlier history
  as incomplete and never infers commands, soft wraps or exit codes from text
  (companion #17). A sequence gap, a frame for an older generation, or a
  snapshot larger than the advertised snapshot bound discards the model and
  closes the stream; the phone reconnects for a fresh generation. The Mac
  passes the daemon snapshot through unmodified and never truncates it, since
  cutting a byte stream can split a control sequence; the snapshot bound
  (recommend 8 MiB) is derived from the daemon's configured scrollback limit
  and advertised in capabilities so the phone can size its model. Snapshot
  chunks share the output frame cap below.
- `grid` and `leader` control frames are sent at snapshot and whenever the
  daemon reports a change, in order with output. The phone presents the
  authoritative grid with scaling and panning; rotation never sends a resize.
  A phone with the interactive role sends its requested dimensions in a `grid`
  frame; the Mac applies them only with that phone's next accepted `input` or
  explicit `claim` (Take over, ADR-0036), never on receipt. A Watch stream
  carries no `input`, `reply`, `claim` or phone-sent `grid` frames; the Mac
  drops any it receives and ends the stream as a protocol error. Any frame
  whose generation ID is not the stream's current one is dropped before any
  forwarding, so input or a grid delayed across an overflow resync cannot
  reach the PTY.
- A stream's role is fixed at attach from the device's grants. Granting or
  revoking the input grant ends every stream for that device with
  `role_changed`; the phone attaches again and receives its new role in the
  handshake reply. There is no in-stream role upgrade.

### Buffers and a slow phone

- The Mac never applies back-pressure to the PTY or to the Mac pane because a
  phone is slow. Each stream has a bounded pending buffer (recommend 4 MiB) and
  an output frame cap (recommend 64 KiB), with at most one stream per device
  and pane, two streams per device and four streams per Mac, counted apart
  from the existing eight-client limit.
- When a stream's pending buffer would overflow, the Mac discards the buffered
  output, detaches that stream's zmx client and, once the socket drains,
  attaches a new one so the phone receives a new generation beginning with a
  snapshot. The restart is bounded: if the buffer overflows again before the
  new generation's `snapshot_end` is written, or more than three times within
  one minute, the Mac ends the stream with `overflow` and the phone must
  reconnect, so a phone that cannot keep up sees a closed stream rather than
  an empty generation. Output lost between generations is reported as
  incomplete history, never silently skipped inside one generation.
- The Mac sends `heartbeat` every 15 seconds while idle and closes a stream
  with no readable frame or TCP progress for 45 seconds. The phone keeps a
  stream open only while the terminal view is foreground and visible and ends it
  the moment the view leaves the foreground, on lock or on dismissal, with no
  grace period, matching ADR-0039's memory-only posture. Received bytes are not
  written to disk, widgets, notifications, logs or analytics.

### Cancel, revocation and every write

- Either side ends a stream with an `end` frame naming a reason (`closed`,
  `superseded`, `revoked`, `pane_unavailable`, `session_ended`, `role_changed`,
  `protocol_error`, `overflow`) or by closing TLS. A new `watch_terminal` for
  the same device and pane supersedes the previous stream; the old one ends.
- Before every frame it writes, the Mac rechecks the device's lease revision,
  Terminal grant and role, the pane's workspace assignment, the pane's target
  version and the zmx session identity. Any failure ends the stream with the
  matching reason, detaches the relay's zmx client and drops queued bytes.
  Revocation or unpairing ends every stream for that device immediately;
  these checks are the same evidence the Mac uses before serving a request and
  do not add a consent prompt.
- Terminal queries from the application are answered only by the leader's
  client (ADR-0036). The phone renderer suppresses automatic replies on a Watch
  stream, and the Mac drops them. Clipboard, notification, hyperlink and other
  host-effect sequences arrive unfiltered; the phone renderer ignores them.
  The Mac does not parse or rewrite the byte stream, which would require a
  second emulator in the relay and could split control sequences.

### Reconnect and route changes

- A dropped or route-changed connection is a new attach. The phone chooses a
  route under ADR-0035 (LAN first, then Tailscale, same pin, with cooldown),
  sends a new `watch_terminal` and receives a new generation. There is no
  resume token, no sequence-based replay and no cross-route handoff of a live
  stream. The Mac learns of the drop from the socket or the heartbeat deadline
  and detaches the old zmx client; a reconnect before that detach supersedes it.
  If the device was leading, the daemon waits 5 seconds before handing the
  grid to a Mac pane, so a reconnect that claims within that wait reflows
  only once. A Mac keystroke, resize or focus ends the wait early
  (ADR-0036 amendment).
- Reconnect never restores leadership. A device that led before the drop
  attaches as a follower until a fresh accepted input or claim. ADR-0042's
  Input-on opening policy sends that new claim after the new snapshot; it never
  restores queued input or an old claim.
- **Input after failover is never replayed.** Each `input` frame carries its
  generation and sequence; the Mac answers `ack` with the highest input
  sequence it forwarded to the daemon within that generation. Input that is
  unacknowledged at disconnect may or may not have reached the PTY, so the
  phone shows it as delivery unknown, discards it with the generation, and the
  person resends it only by typing again. Batch bounds, paste handling
  and the ack latency budget belong to the input milestone; this record fixes
  the rule and the frames that make it enforceable.

## Consequences

Watch can ship on the direct connection with the Watch role from #827 and no
daemon journal; the snapshot path already exists in zmx. Every reconnect, resync
and app restart costs one scrollback serialization and briefly shows a fresh
snapshot, and a phone that is slower than the pane's output sees generation
restarts instead of a stalled Mac. Because the daemon snapshot drops marks and
wrap provenance, incomplete history is the normal state of every generation,
not an error. A hosted relay would need its own ADR; sealed push
([ADR-0037](0037-sealed-push-relay.md)) carries no terminal bytes.

Implementation must prove ordering across snapshot and output, overflow
resync, revocation mid-stream, heartbeat expiry, route change on both LAN and
Tailscale, superseding reconnects and the no-replay input rule against real
TUIs and a real device. These are future acceptance checks; this docs-only
change provides no runtime evidence.

## Open questions for Sarah

Answered by Sarah on 2026-10-20; the recommendation is accepted as written.

1. Confirm the slow-phone policy: the Mac never stalls the pane, discards the
   stream's pending buffer at the 4 MiB bound and restarts the stream with a
   fresh snapshot, rather than pausing output or buffering without limit?
   **Decision:** yes. Drop the pending buffer at 4 MiB and restart with a
   fresh snapshot; never stall the pane or buffer without limit.
2. Confirm that every reconnect, including a LAN-to-Tailscale route change, is
   a new attach with a new snapshot and "earlier history incomplete", with no
   resume token or replay journal on the Mac?
   **Decision:** yes. Every reconnect is a new attach with no replay.
3. Accept raw daemon bytes on the stream, relying on the phone renderer to
   suppress replies and ignore host-effect sequences, instead of Mac-side
   filtering that would need a second emulator in the relay?
   **Decision:** yes. The stream carries raw daemon bytes; the phone renderer
   suppresses replies and ignores host-effect sequences. No filtering on the
   Mac.
4. End the stream the moment the phone view leaves the foreground, matching
   ADR-0039, or allow a short grace period (for example 30 seconds) before the
   Mac detaches the relay client?
   **Decision:** end the stream the moment the view leaves the foreground,
   matching ADR-0039. No grace period.
