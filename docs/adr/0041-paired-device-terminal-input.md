# 0041 — Typing into a pane from a paired device

- **Status:** Proposed
- **Date:** 2026-10-21
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
"a specific pane". This record has to settle that scope before #788 builds the
input path.

A terminal is the whole Mac account. The phone is a real terminal emulator
(libghostty, companion #30) re-emulating the daemon's bytes, so it knows the
application's modes, including bracketed paste. The Mac relay does not parse
the byte stream (ADR-0040). Sarah's standing decisions apply: direct
LAN/Tailscale first, no hosted relay. This is a docs-only decision; it
names the listener, frame and zmx fork changes #788 and its follow-ups
need and ships none of them.

## Options considered

- **Input grant per pane:** the narrowest consent and what ADR-0036 wrote
  down, but every new pane, split or recovered daemon needs a new Mac prompt,
  and the person at the phone cannot fix a build in a pane they did not
  foresee.
- **Input grant for Mac-selected workspaces (chosen):** the same persisted
  shape as Decide and Transcript, one consent model across the three powers,
  and moving a pane out of the workspace ends access the same way.
- **One device-wide input switch:** simplest to explain, but it grants typing
  into every future pane with one click and has no counterpart in the other
  grants.
- **Phone-side paste checks only, Mac trusts the frame:** mirrors Ghostty's
  own rule, but a modified client could send anything. The Mac must bound
  size and frames; it cannot judge safety without a second emulator, so the
  confirmation lives on the phone and the hard limits live on the Mac.

## Decision

**Recommendation:** a paired device types through the ADR-0040 interactive
stream, claims leadership exactly as ADR-0036 says, and is authorized by a
default-off per-device **Input** power plus a Mac-approved workspace list that
mirrors ADR-0039. Paste is one input frame, bracketed when the application
asked for it, confirmed on the phone when it could run commands, and bounded
on the Mac. Revocation and reconnect never restore a claim.

### Taking over

- A device with the Input grant attaches its stream in the interactive role
  (ADR-0040) but starts as a follower: attaching never claims or resizes.
  The phone shows the leader's grid, scaled and pannable, with a **Take
  over** control. Take over sends a `claim` frame carrying the phone's
  requested grid; the Mac forwards it as a typed `TakeOver` so leadership
  moves without a dummy keystroke. The first `input` frame from a follower
  claims the same way, with the phone's last `grid` applied before its bytes,
  or the handshake's preferred grid if no `grid` frame was sent (ADR-0036).
  Both paths are one tap or one keystroke apart.
- While a device leads, the Mac pane shows a banner naming the device and
  grid (columns × rows), for example "iPhone is driving · 40×24 · type here
  to take it back". The Mac pane never hides or blocks local typing; a Mac
  keystroke claims leadership back in daemon order and the phone drops to
  follower presentation naming the new leader ("Mac is driving", "iPad is
  driving"). The stream's role does not change; only leadership does. Until
  option B below ships, a lone Escape on the Mac does not claim (see that
  section), so the banner says "type a letter, arrow or Return to take it
  back". The banner also offers **Stop**, which revokes that device's Input
  power (see Revocation). Recommend a matching indicator on the sidebar row
  and workspace while a device leads, and a "Last typed from iPhone at
  14:02" note on the pane until the Mac user interacts with it, so typing
  into an off-screen pane is never invisible (Decision 7). The follower Mac
  presentation itself (clipped or letterboxed grid, leader indicator) is
  #826/#788 work under ADR-0036, not redefined here.
- Automation (`amx send`) and Watch streams never claim. A phone whose Input
  grant does not cover the pane's workspace gets a Watch stream and no Take
  over control; the Mac drops any `input`, `reply`, `claim` or `grid` frame
  on a Watch stream as a protocol error (ADR-0040). The `watch_terminal`
  reply names why the stream is Watch-only (`power_off`,
  `workspace_not_granted`, `remote_pane`) so the phone can say "Typing is
  not allowed for this workspace. Allow it on the Mac in Settings ›
  Companion" instead of silently hiding the control.
- Driving requires the phone-side content gate that ADR-0035 keeps as a
  release requirement to be satisfied; Take over adds no second biometric
  prompt. The gate is checked
  again whenever the terminal view returns to the foreground, which is also
  when a new stream starts. The phone's key proves the device, not the
  person, so the Mac banner and the Mac-side grant remain the controls that
  matter. Device input keeps working while the Mac display is locked or
  asleep; being away from the desk is the use case.

### Input authorization

- Add a default-off **Input** power per paired device, with a Mac-approved
  grant for explicitly selected workspaces, initiated on the Mac with no
  all-workspaces default. Both are required. The Terminal (Watch) grant from
  ADR-0036 is a prerequisite: each power keeps its own workspace list of the
  same shape, and a workspace can be on the Input list only while it is on
  the Terminal list. Input never widens Watch, and neither implies Decide or
  Transcript. Status, previews, rename, transcript and decision access cannot
  enable Input.
- The grant covers every terminal pane that is in a granted workspace at
  attach time, including panes created or recovered later in that workspace.
  It is persisted with the companion connection by workspace ID, survives
  app restart and lasts until revoked or unpaired, exactly as ADR-0039. The
  phone names a pane; the Mac resolves its workspace, live zmx session and
  role. Moving a pane out of a granted workspace, or deleting the workspace,
  ends its streams. Any change that moves an open stream between Watch and
  Input (Input power toggled, workspace added to or removed from the Input
  list, pane moved between an Input-granted and a Watch-only workspace) ends
  the stream with `role_changed`; the phone reattaches and the handshake
  assigns the new role. Losing Terminal coverage of the pane's workspace
  (workspace removed from the Terminal list, pane moved out of every
  Terminal-granted workspace, Terminal grant removed), revoking the lease or
  unpairing ends the stream with `revoked` and there is no reattach.
  Removing a workspace from the Terminal list also removes it from the Input
  list, keeping the subset rule.
- Relation to ADR-0039: the two grants are independent switches over the
  same workspace list shape. Granting Input does not grant Transcript, and
  the Mac stores and rechecks them separately. On acceptance, the ADR-0035
  amendment, ADR-0036 and ADR-0040 get a one-line change from "a specific
  pane" / "that device and pane" to "panes in Mac-selected workspaces". That
  moves the Terminal (Watch) grant to workspace scope as well; existing
  per-pane Watch grants are not widened automatically and need re-approval
  on the Mac.
- The Mac rechecks the lease revision, Input grant, workspace assignment,
  target version and zmx session before every inbound `input`, `claim` and
  `reply` frame it forwards, extending the recheck ADR-0040 requires before
  every frame the Mac writes. A phone-sent `grid` is applied only with that
  phone's next accepted `input` or `claim` (ADR-0040). Remote-owned panes
  (`PersistenceOwner.remoteZmx`) have no local daemon and are not typeable
  from a device in this version; the handshake reports `remote_pane`.

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
  sending again). A late `ack` in the same generation moves "may have run"
  to "sent". Recommend an ack budget of two seconds. Composer text is kept
  on the phone in all three states with a manual Send again; nothing is
  retried automatically. The phone sends one paste at a time per stream and
  does not send a second until the first is acked or shown as may have run.
  A typed per-batch accept/reject receipt and a
  per-attachment queue cap are the zmx fork follow-ups that would turn "may
  have run" into a definite answer and keep one device from filling the
  shared queue; #788 should not depend on them.
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

- Turning the Input power off, removing a workspace from a list, revoking
  the lease or unpairing ends every affected stream with `role_changed` or
  `revoked` as set out above, detaches the relay's zmx client and drops its
  queued bytes. The daemon's close-connection cleanup clears that client's
  leadership only if it was the leader, invalidates its queued replies and
  retains the grid (ADR-0036). If the phone was leading, the pane is then
  leaderless at the phone's grid until the next Mac keystroke or Take over
  and the banner reads "No one is driving · 40×24 · type a letter, arrow or
  Return to take back" (same Escape caveat as above), with no Stop action;
  if the Mac had already taken back, nothing changes.
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
- **Stop** on the Mac banner is that revocation: it turns the device's Input
  power off, persists that before sending `end` so a concurrent reconnect
  cannot pass the handshake, keeps the workspace list for re-enabling, and
  ends all of that device's streams. The phone reattaches as Watch and says
  "Typing was turned off on the Mac". Taking leadership back without
  revoking is simply typing on the Mac.
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
the Mac pane is not the leader: while a phone drives, after the phone
leaves and the pane is leaderless, and after a leaderless reattach. In
practice, Sarah presses Escape in vim on the Mac to take back from the phone
and the key is lost. A paired device is unaffected: its `input` and `reply`
frames carry provenance, so a phone `ESC` is user input and claims.

| Option | Behavior | Cost |
| --- | --- | --- |
| A. Keep the limitation | Document it; a C0 control other than ESC, DEL, a printable key, arrow, Shift-Tab or Home/End claims | Lone ESC and CPR/DSR replies lost until then; vim and TUIs misbehave on every handback |
| B. Typed seam for the Mac client (recommended) | The Mac pane attaches with `AttachRole` interactive and sends `UserBatch`/`TerminalReply`, so ESC is unambiguous and a reply is a reply | Native input seam in the Mac client; LEADERSHIP.md already names it as the missing piece |
| C. Daemon answers from its own model while leaderless | Extend the DA fallback to CPR, DSR and mode reports the daemon can compute | zmx fork change; color and clipboard queries still need a real client |
| D. Sole Mac client claims on reattach with the retained grid | `TakeOver` using the current rows and columns restores reply authority without a resize | Later Mac window resizes then apply, which bends the ADR-0036 keep-last-grid decision |

Recommend B before #788 ships device input, and C as a follow-up to make a
leaderless pane answer the queries it can. B does not elect a leader or
resize; it only removes the ambiguity, so ADR-0036's no-guessing rule holds.
Do not add a timeout or heuristic to elect on ESC. B and C each need their
own issue; #788 covers device input and the banner.

## Consequences

#788 can build the Mac input path and banner on the ADR-0040 frames plus the
handshake reason, the `inputFrameMax` capability, the authority epoch on
leadership changes and `reply`, and the three delivery states above, with
the grant stored like Decide and Transcript. One workspace list per power
keeps Settings consistent, at the cost that a pane created later in a
granted workspace is typeable without a new prompt. The
phone owns paste encoding and confirmation because it is the emulator; the
Mac owns the limits because it is the trust boundary. A revoked or
disconnected driver leaves the pane at the phone's grid, which is the
ADR-0036 trade-off and is visible on the Mac banner. Three zmx fork
follow-ups are named and not required: a per-batch receipt, a
per-attachment queue cap, and draining a started batch on close. Option B
adds a native input seam to the Mac client before the Escape gap closes.

Implementation must test concurrent typing from Mac and phone, paste with
and without mode 2004, the strip set and terminator confirmation, oversized
and empty frames, a full daemon queue, revocation and lock mid-paste
(truncation), reconnect with unacknowledged input, Escape on the Mac while
the phone drives, and a leaderless reattach against real TUIs. These are
future acceptance checks; this record provides no runtime evidence.

## Decisions for Sarah

1. Scope both the Terminal (Watch) and the Input grant to Mac-selected
   workspaces, mirroring ADR-0039, with Input a subset of Terminal, rather
   than per pane as ADR-0036 wrote or one device-wide switch? Existing
   per-pane Watch grants would need re-approval.
2. Make **Stop** on the Mac banner a persisted revocation of that device's
   Input power across all its streams, with typing on the Mac as the
   non-revoking way to take back, rather than a one-time end of the stream
   the phone can reattach past? Suggested label: "Turn off typing from
   iPhone".
3. Adopt Ghostty's paste safety rule as the confirmation trigger (terminator
   always; line terminators only when bracketed paste is off), rather than
   confirming every multi-line paste regardless of mode?
4. Cap an input frame, and therefore a paste, at 64 KiB with a phone-side
   refusal above it, rather than allowing up to the daemon's 256 KiB queue?
   And accept that `ack` means forwarded, not accepted, until the zmx fork
   gains a per-batch receipt?
5. For Escape and query replies while the Mac pane is not the leader, take
   option B (typed seam for the Mac client) before #788 ships, with C as a
   follow-up, rather than keeping the limitation or letting a sole Mac client
   claim on reattach?
6. Require only the ADR-0035 phone-side content gate before Take over, with
   no additional biometric prompt per takeover?
7. Show a driving indicator beyond the pane (sidebar row and workspace)
   while a device leads, and keep a "Last typed from iPhone at 14:02" note on
   the pane until the Mac user interacts with it, so typing into an
   off-screen pane is never invisible?
