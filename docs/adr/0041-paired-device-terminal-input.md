# 0041 — Typing into a pane from a paired device

- **Status:** Proposed
- **Date:** 2026-10-21
- **Amended:** 2026-10-26 — phone opening and creation defaults (ADR-0042)
- **Deciders:** Sarah
- **Issue:** [#787](https://github.com/Interactive-Buffoonery/awesomux/issues/787)

## Context

[ADR-0036](0036-multi-client-terminal-leadership.md) decides who leads and
resizes: last typer leads, Take over is an explicit claim, watchers never
lead, and input is a separate Mac-approved grant. The merged zmx fork (#863,
`vendor/zmx/LEADERSHIP.md`) provides the typed attachment contract that makes
this enforceable: interactive and Watch roles, `UserBatch`, `TerminalReply`,
`TakeOver`, `Downgrade`, reply epochs and one bounded operation queue.
[ADR-0040](0040-live-terminal-stream.md) fixes the paired stream: a role per
stream, `input`, `reply`, `claim` and phone-sent `grid` frames, generation IDs,
`ack` with the highest forwarded input sequence, and the rule that input is
never replayed after failover. It leaves batch bounds, paste handling and the
ack budget to this record.

[ADR-0038](0038-phone-as-permission-decision-source.md) and
[ADR-0039](0039-read-only-device-transcripts.md) set the consent shape for the
other device powers: a default-off per-device switch plus Mac approval for
explicitly selected workspaces, persisted with the pairing by workspace ID.
ADR-0036 and the ADR-0035 amendment describe the Terminal grant as access to
"a specific pane" with a separate input grant. This record defines that input
grant before #788 builds the input path.

A terminal is the whole Mac account. The phone is a real terminal emulator
(libghostty, companion #30) re-emulating the daemon's bytes, so it knows the
application's modes, including bracketed paste. The Mac relay does not parse
the byte stream (ADR-0040). Sarah's standing decisions apply: direct
LAN/Tailscale first, no hosted relay. This is a docs-only decision; it
names the listener, frame and zmx fork changes #788 and its follow-ups
need and ships none of them.

## Options considered

- **Input grant per pane:** the narrowest consent and what ADR-0036 wrote
  down, but every new pane, split or recovered daemon needs a second Mac
  prompt on top of its Watch approval, and the person at the phone cannot
  fix a build in a pane they did not foresee.
- **Input grant for Mac-selected workspaces:** the same persisted shape as
  Decide and Transcript, one consent model across the three powers, and
  moving a pane out of the workspace ends access the same way; but it adds a
  second list to maintain next to the Terminal grant and a second place a
  pane can silently stop being typeable.
- **One device-wide input switch (chosen):** simplest to explain and to
  revoke; it makes every pane the device may watch typeable with one click,
  including panes granted later, and has no counterpart in the other grants.
  Sarah chose it knowing those costs; they are recorded under Consequences.
- **Phone-side paste checks only, Mac trusts the frame:** mirrors Ghostty's
  own rule, but a modified client could send anything. The Mac must bound
  size and frames; it cannot judge safety without a second emulator, so the
  confirmation lives on the phone and the hard limits live on the Mac.

## Decision

A paired device types through the ADR-0040 interactive stream, claims
leadership exactly as ADR-0036 says, and is authorized by one default-off
device-wide **Input** switch on the Mac that applies to every pane the
device's Terminal grant covers. Paste is one input frame, bracketed when the
application asked for it, confirmed on the phone when it could run commands,
and bounded on the Mac. Revocation and reconnect never restore a claim.

### Taking over

- [ADR-0042](0042-phone-terminals.md) changes the opening default: opening
  with Input on sends a fresh `claim` at the phone's grid after the snapshot;
  Watch is an explicit choice. The low-level interactive attach alone still
  starts as a follower and preserves the grid until that claim or input.
  A follower shows the leader's grid, scaled and pannable, with a **Take
  over** control. Take over sends a `claim` frame carrying the phone's
  requested grid; the Mac forwards it as a typed `TakeOver` so leadership
  moves without a dummy keystroke. The first `input` frame from a follower
  claims the same way, with the phone's last `grid` applied before its bytes,
  or the handshake's preferred grid if no `grid` frame was sent (ADR-0036).
  Both paths are one tap or one keystroke apart.
- While a device leads, the Mac pane shows a banner naming the device and
  grid (columns × rows), for example "iPhone has control · 40×24 · type here
  to take it back". The Mac pane never hides or blocks local typing; a Mac
  keystroke claims leadership back in daemon order and the phone drops to
  follower presentation naming the new leader ("Mac has control", "iPad has
  control"). The stream's role does not change; only leadership does. Until
  option B below ships, a lone Escape on the Mac does not claim (see that
  section), so the banner says "type a letter, arrow or Return to take it
  back". The banner also offers **Disconnect**, which ends that device's
  current stream without changing any grant (see Revocation). The sidebar
  row and workspace show a matching indicator while a device leads, and the
  pane keeps a "Last typed from iPhone at 14:02" note until the Mac user
  interacts with it, so typing into an off-screen pane is never invisible
  (decision 7). The follower Mac
  presentation itself (clipped or letterboxed grid, leader indicator) is
  #826/#788 work under ADR-0036, not redefined here.
- Automation (`amx send`) and Watch streams never claim. A phone whose Input
  switch is off gets a Watch stream and no Take over control; the Mac drops
  any `input`, `reply`, `claim` or `grid` frame on a Watch stream as a
  protocol error (ADR-0040). The `watch_terminal` reply names why the
  stream is Watch-only (`input_off`, `remote_pane`) so the phone can say
  "Typing from this iPhone is off. Allow it on the Mac in Settings ›
  Companion" instead of silently hiding the control.
- Driving requires the phone-side content gate that ADR-0035 keeps as a
  release requirement to be satisfied; Take over adds no second biometric
  prompt. The gate is checked
  again whenever the terminal view returns to the foreground, which is also
  when a new stream starts. The phone's key proves the device, not the
  person, so the Mac-side Input switch, Terminal grant and pairing remain
  the controls that matter; the banner only ends the current stream.
  Device input keeps working while the Mac display is locked or asleep;
  being away from the desk is the use case.

### Input authorization

- Add a default-off **Input** switch per paired device, turned on only on
  the Mac in Settings › Companion. It has no per-workspace or per-pane list:
  while it is on, the device may type into every pane its Terminal (Watch)
  grant covers, now and later. The Terminal grant from ADR-0036 keeps its
  own scope and stays the prerequisite, so Input is always a subset of
  Terminal and never widens Watch. Input implies neither Decide nor
  Transcript, and status, previews, rename, transcript and decision access
  cannot enable it.
- The switch is persisted with the companion connection, survives app
  restart and lasts until turned off or unpaired. The phone names a pane;
  the Mac resolves its live zmx session and role from the Terminal grant
  and the switch. Turning the switch on or off ends each stream of that
  device whose authorized role changes with `role_changed`; the phone
  reattaches and the handshake assigns the new role. A remote-pane Watch
  stream stays Watch either way and is left open. Losing the Terminal grant
  for the pane, revoking the lease or unpairing ends the stream with
  `revoked` and there is no reattach. A pane that becomes unavailable ends
  the stream with `pane_unavailable`; a zmx session that ends uses
  `session_ended`, preserving ADR-0040's end reasons. Revoking is done in
  the grant settings on the Mac, never from the pane banner.
- Relation to ADR-0039: Input is a different shape from Decide and
  Transcript, which are Mac-approved workspace lists. The Mac stores and
  rechecks it separately; granting Input changes nothing about the other
  powers. ADR-0035, ADR-0036 and ADR-0040 keep their "a specific pane" /
  "that device and pane" Terminal wording; this record only fills in the
  separate input grant they name.
- The Mac rechecks the lease revision, Terminal grant, Input switch,
  target version and zmx session before every inbound `input`, `claim` and
  `reply` frame it forwards, extending the recheck ADR-0040 requires before
  every frame the Mac writes. A phone-sent `grid` is applied only with that
  phone's next accepted `input` or `claim` (ADR-0040). Remote-owned panes
  (`PersistenceOwner.remoteZmx`) are typeable through their local amx carrier.
  Carrier launch metadata selects the local source; amx availability alone
  grants nothing. Direct-SSH fallback reports `remote_pane`.

### Safe paste

- **One paste is one `input` frame**, and one frame is one daemon
  `UserBatch`. The daemon never interleaves a competing batch inside it
  (ADR-0036). Anything inserted as more than one key event, whatever its
  source (paste menu, hardware Cmd-V, keyboard extension, dictation, drag
  and drop, Universal Clipboard, the composer), is a paste; a keystroke is a
  single key's bytes. Only keystrokes and quick-key bar keys skip the rules
  below.
- **The phone encodes with Ghostty's text-insertion paste path**
  (`vendor/ghostty/src/input/paste.zig`, never the clipboard paste-event
  path for mode 5522, whose follow-up clipboard read the phone renderer
  ignores). That encoder first replaces the xterm strip set (NUL, BS, ENQ,
  EOT, ESC, DEL and the tty control characters such as Ctrl-C, Ctrl-U,
  Ctrl-Z, Ctrl-O) with spaces in both modes, then frames the text in
  `ESC [200~` and `ESC [201~` when the application set mode 2004 and leaves
  line terminators intact, or converts newlines to carriage returns when it
  did not. The phone's emulator tracks mode 2004 from the same bytes the Mac
  sees. The Mac does not parse the stream and relies on this encoding plus
  the limits below.
- **Confirmation uses Ghostty's safety rule** (`isSafeWith`) on the text
  before encoding. A bracketed paste is unsafe only if it contains the
  bracket terminator; an unbracketed paste is unsafe if it contains a
  newline, carriage return or the terminator. Unsafe text shows a
  confirmation on the phone with the reason and a preview of the encoded
  text; the person can send it anyway or cancel. A confirmed terminator
  still has its ESC replaced by a space, as the Mac app does with
  `clipboard-paste-protection`, so a confirmed paste never closes the
  bracket early. Paste is disabled until `snapshot_end`, because mode 2004
  is unknown before it, and an open confirmation is discarded when the
  generation changes.
- **The composer's optional Enter** is one carriage return appended after
  encoding, outside the closing bracket, in the same frame, so it cannot land
  after a Mac keystroke and does run the pasted line. The safety check sees
  the composer text alone. Enter is not added when unbracketed text already
  ends in a line terminator, and the preview says "will press Enter".
- **Size limits are enforced on the Mac.** An `input` frame carries at most
  64 KiB of encoded terminal bytes, counted in UTF-8 after stripping,
  bracketing and the trailing Enter, excluding the frame header; exactly the
  cap is allowed. It is the same cap as output frames (ADR-0040) and is
  advertised in `get_capabilities` as `inputFrameMax`. The phone refuses a
  larger paste before sending: "Too large to paste (64 KB). Copy it to a
  file on the Mac instead." The Mac ends a stream that sends one with
  `protocol_error`, as it does for an empty `input` frame; an Enter-only
  submit is the one-byte frame `\r`.
- **Delivery state.** `ack` keeps its ADR-0040 meaning: the highest input
  sequence the Mac wrote to the daemon socket. The current zmx fork gives no
  per-batch receipt and rejects a `UserBatch` from a full queue (256 KiB of
  pending payload or 4096 operations, LEADERSHIP.md) with only a log line,
  so the Mac cannot tell acceptance from rejection and the ADR does not
  promise it. The phone therefore shows three states: **sent** (acked),
  **not sent** (never left the phone: refused on the phone or still queued
  locally when the stream ended; safe to send again) and **may have run**
  (no ack within the budget or at disconnect; check the terminal before
  sending again). Any input that left the phone and has no `ack` covering
  its sequence in the current generation within two seconds of sending
  moves to "may have run"; so does unacknowledged input when the stream
  ends. An `ack` from an earlier generation is ignored. A late `ack` in the
  same generation moves "may have run" to "sent". Composer text is kept
  on the phone in all three states with a manual Send again; nothing is
  retried automatically. The phone sends one paste at a time per stream and
  does not send a second until the first is acked or shown as may have run.
  A typed per-batch accept/reject receipt and a
  per-attachment queue cap are the zmx fork follow-ups that would turn "may
  have run" into a definite answer and keep one device from filling the
  shared queue; #788 should not depend on them. Until that cap exists,
  a device sending many small input frames can fill the shared operation
  queue and starve Mac input or other paired devices. This is an accepted
  limitation for #788, which must test that case; the frame-size cap and
  one-paste-at-a-time rule do not prevent it.
- Keystrokes typed within a short window may be coalesced into one frame;
  a paste is never merged with keystrokes or with another paste, and a lone
  ESC is never coalesced: it ends the current frame and goes alone. PTY
  delivery does not preserve frame boundaries (the daemon writes batches
  back to back), so an application can still read a fast `ESC` then `j` as
  Alt-j; separate frames only keep the relay from creating that pairing.
- **Reply provenance.** The Mac reports the daemon's authority epoch to the
  phone with every leadership change it relays, and the phone tags each
  `reply` with the epoch it held when it processed the query output that
  produced it. The Mac forwards the reply only while that stream leads and
  the tagged epoch matches the current leading epoch; otherwise it drops the
  reply. The Mac never restamps: a reply generated under an epoch the Mac
  has since reclaimed must not gain fresh authority when the phone reclaims
  later. The daemon separately rejects any stale epoch (LEADERSHIP.md).

### Revocation and reconnect

- Turning the Input switch off ends streams whose authorized role changes
  with `role_changed`; remote-pane Watch streams stay open. Removing the
  Terminal grant, revoking the lease or unpairing ends every affected stream
  with `revoked`, never `role_changed`. Each ended stream detaches the
  relay's zmx client and drops its queued bytes. The daemon's
  close-connection cleanup clears that client's leadership only if it was
  the leader, invalidates its queued replies and
  retains the grid (ADR-0036). If the phone was leading and one Mac pane is
  attached, that pane leads again at its own size (ADR-0036 amendment,
  2026-10-29). With two or more Mac panes, the pane stays leaderless at the
  phone's grid until a Mac pane types or resizes, and the banner
  reads "No one has control · 40×24 · type a letter, arrow or
  Return to take back" (same Escape caveat as above), with no Disconnect
  action; if the Mac had already taken back, nothing changes.
  The same leaderless banner applies to lock, dismissal and a dropped
  connection, where the Mac learns of the drop from the socket or the
  heartbeat deadline (ADR-0040) and the banner can lag by that much.
- Closing the relay client also discards a partially written batch: the
  fork's `dropSource` removes a started operation, so a 64 KiB paste that
  is stalled on a slow reader can land truncated, including without its
  closing `ESC [201~`. Bytes already written cannot be withdrawn, and an
  `ack` does not prove the paste drained to the PTY, so closing can truncate
  even an acknowledged paste. Letting a started batch drain before the rest
  is dropped is a zmx fork follow-up; until then the truncation is a
  documented limitation and a required #788 test.
- **Disconnect** on the Mac banner is not a revocation: it ends only that
  device's current stream to that pane with `closed` (ADR-0040) and changes
  no grant. The daemon-side effect is the same as any close: if that device
  was still leading, a sole Mac pane leads again at its own size and
  several Mac panes stay leaderless until one types or resizes; otherwise
  the current leader and grid are unchanged. The phone shows
  "Disconnected from the Mac" with a Reconnect control; reconnecting is a
  new attach as a follower, so the device cannot resume driving without
  another Take over or keystroke. Taking leadership back without ending the
  stream is simply typing on the Mac; turning typing off for good is the
  Input switch in Settings.
- A reconnect, route change or app restart is a new attach with a new
  generation and a new daemon attachment ID; the phone attaches as a
  follower with the same grant and must Take over or type again (ADR-0040).
  Input unacknowledged at disconnect is shown as "may have run" and never
  resent automatically. The phone ends the stream the moment the terminal
  view leaves the foreground, on lock and on dismissal, with no grace period
  (ADR-0040), which also ends its leadership. Copying from another app and
  returning is therefore a reattach as follower.
- Granting Input to a device that currently holds a Watch stream ends that
  stream with `role_changed`; the phone reattaches and receives the
  interactive role in the handshake. There is no in-stream upgrade.

### Escape and query replies while the Mac pane is not the leader

#863 left this open. The Mac's own pane client still uses the legacy
`attach` stream, where a standalone `ESC` from a non-leader is ambiguous
with a terminal reply prefix, so the daemon drops it and answers only DA
queries while no typed leader exists (LEADERSHIP.md). This applies whenever
the Mac pane is not the leader: while a phone drives, and while two or more
Mac panes share a leaderless session. A sole Mac pane leads again when the
phone leaves and on reattach (ADR-0036 amendment, 2026-10-29). In
practice, Sarah presses Escape in vim on the Mac to take back from the phone
and the key is lost. A paired device is unaffected: its `input` and `reply`
frames carry provenance, so a phone `ESC` is user input and claims.

| Option | Behavior | Cost |
| --- | --- | --- |
| A. Keep the limitation | Document it; a C0 control other than ESC, DEL, a printable key, arrow, Shift-Tab or Home/End claims | Lone ESC and CPR/DSR replies lost until then; vim and TUIs misbehave on every handback |
| B. Typed seam for the Mac client (chosen) | The Mac pane attaches with `AttachRole` interactive and sends `UserBatch`/`TerminalReply`, so ESC is unambiguous and a reply is a reply | Native input seam in the Mac client; LEADERSHIP.md already names it as the missing piece |
| C. Daemon answers from its own model while leaderless | Extend the DA fallback to CPR, DSR and mode reports the daemon can compute | zmx fork change; color and clipboard queries still need a real client |
| D. Sole Mac client claims on reattach with the retained grid (a variant shipped, see below) | `TakeOver` using the current rows and columns restores reply authority without a resize | Later Mac window resizes then apply, which bends the ADR-0036 keep-last-grid decision |

Sarah deferred B for #788 on 2026-10-23. Device input ships with option A's
limitation: a lone Escape on the Mac does not take back control while a
device drives. Type a letter, arrow or Return to reclaim instead.
CPR/DSR replies from a non-leading legacy Mac client remain limited too.
A variant of D shipped on 2026-10-29: a sole Mac pane claims at its own
size rather than the retained grid. B and C remain follow-ups. B does not
elect a leader or resize; it only removes the ambiguity, so ADR-0036's no-guessing rule holds.
Do not add a timeout or heuristic to elect on ESC. B and C each need their
own issue; #788 covers device input and the banner.

## Consequences

#788 can build the Mac input path and banner on the ADR-0040 frames plus the
handshake reason, the `inputFrameMax` capability, the authority epoch on
leadership changes and `reply`, and the three delivery states above, with
the Input switch stored next to the Terminal grant. The device-wide switch
has costs Sarah accepted: every pane the device may watch becomes typeable
with one click, including panes granted for Watch later, with no separate
Input prompt; the Input switch uses a different scope model from the
ADR-0039 workspace lists, so Settings shows one switch next to per-pane
Terminal grants and the Decide and Transcript lists; and a lost phone that
passes its content gate can type into every watchable pane until the Mac
turns the switch off or unpairs it. Banner Disconnect ending only the
stream means the Mac user has to open Settings to stop a device for good.
The phone owns paste encoding and confirmation because it is the emulator; the
Mac owns the limits because it is the trust boundary. A revoked or
disconnected driver hands a sole Mac pane back its own size; with several
Mac panes it leaves the phone's grid, which is the ADR-0036 trade-off and is
visible on the Mac banner. Three zmx fork
follow-ups are named and not required: a per-batch receipt, a
per-attachment queue cap, and draining a started batch on close. Option B
adds a native input seam to the Mac client before the Escape gap closes.

Implementation must test concurrent typing from Mac and phone, paste with
and without mode 2004, the strip set and terminator confirmation, oversized
and empty frames, a full daemon queue, revocation and lock mid-paste
(truncation), reconnect with unacknowledged input, Escape on the Mac while
the phone drives, and a leaderless reattach against real TUIs. These are
future acceptance checks; this record provides no runtime evidence.

## Decisions

Recorded on 2026-10-21.

1. **Grant scope:** one device-wide Input switch, not a per-workspace list
   and not per pane. Input remains a subset of the Terminal grant, whose
   scope is unchanged. The tradeoffs are recorded under Consequences.
2. **Banner Disconnect:** ends the current stream only. It is not a
   persisted revocation and the phone can reattach; revoking stays in the
   grant settings.
3. **Paste confirmation:** Ghostty's safety rule (terminator always; line
   terminators only when bracketed paste is off), not a confirmation for
   every multi-line paste.
4. **Frame cap:** 64 KiB per input frame with a refusal on the phone, and
   `ack` means forwarded, not accepted, until the zmx fork adds a per-batch
   receipt.
5. **Escape and query replies:** option B (typed seam for the Mac client)
   and C are deferred by Sarah for #788 (2026-10-23). Ship the documented
   lone-Escape limitation and the banner's explicit handback keys.
6. **Take over gate:** only the ADR-0035 phone-side content gate, with no
   extra biometric prompt per takeover.
7. **Driving indicator:** show the sidebar row and workspace indicator while
   a device leads, plus the "Last typed from iPhone" note on the pane.

## #788 implementation boundary (2026-10-23)

The initial Mac input path rejects phone `reply` frames until authority epochs
are available in the shared protocol. The pane banner and its Disconnect action
ship here; the sidebar/workspace indicator and "Last typed from iPhone" note
(decision 7) follow separately. Daemon receipts, a per-attachment queue cap and
draining an in-progress batch on close remain zmx follow-ups. An acknowledgement
means written to the daemon socket, not daemon acceptance or PTY delivery; a
close may truncate a started paste, even after acknowledgement.

Carried remote-owned panes and local-amx SSH panes use their local daemon:
Input on grants Interactive, Input off grants Watch/`input_off`, and revoking
Terminal access ends the stream. Only direct-SSH fallback receives
Watch/`remote_pane` followed by `pane_unavailable`.
