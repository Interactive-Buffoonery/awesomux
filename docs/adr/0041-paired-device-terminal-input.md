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
LAN/Tailscale first, no hosted relay. This is a docs-only decision; no
listener, frame or daemon change ships with it.

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
  claims the same way, with the phone's last `grid` applied before its bytes
  (ADR-0036). Both paths are one tap or one keystroke apart, as the plan asks.
- While a device leads, the Mac pane shows a banner naming the device and
  grid, for example "iPhone is driving · 40×24 · type here to take it back".
  The Mac pane never hides or blocks local typing; a Mac keystroke claims
  leadership back in daemon order and the phone drops to follower
  presentation with "Mac is driving". The stream's role does not change;
  only leadership does. The banner also offers **Stop**, which revokes that
  device's Input power (see Revocation). The follower Mac presentation itself
  (clipped or letterboxed grid, leader indicator) is #826/#788 work under
  ADR-0036, not redefined here.
- Automation (`amx send`) and Watch streams never claim. A phone whose Input
  grant does not cover the pane's workspace gets a Watch stream and no Take
  over control; the Mac drops any `input`, `claim` or `grid` frame on a
  Watch stream as a protocol error (ADR-0040).
- Driving requires the M1 terminal unlock gate on the phone to be satisfied;
  Take over adds no second biometric prompt. The phone's key proves the
  device, not the person, so the Mac banner and the Mac-side grant remain
  the controls that matter.

### Input authorization

- Add a default-off **Input** power per paired device, with a Mac-approved
  grant for explicitly selected workspaces, initiated on the Mac with no
  all-workspaces default. Both are required. The Terminal (Watch) grant from
  ADR-0036 is a prerequisite and uses the same workspace list; Input never
  widens Watch, and neither implies Decide or Transcript. Status, previews,
  rename, transcript and decision access cannot enable Input.
- The grant covers every terminal pane that is in a granted workspace at
  attach time, including panes created or recovered later in that workspace.
  It is persisted with the companion connection by workspace ID, survives
  app restart and lasts until revoked or unpaired, exactly as ADR-0039. The
  phone names a pane; the Mac resolves its workspace, live zmx session and
  role. Moving a pane out of a granted workspace, or deleting the workspace,
  ends its streams.
- Relation to ADR-0039: the two grants are independent switches over the
  same workspace list shape. Granting Input does not grant Transcript, and
  the Mac stores and rechecks them separately. On acceptance, the ADR-0035
  amendment and ADR-0036 get a one-line change from "a specific pane" to
  "panes in Mac-selected workspaces".
- The Mac rechecks the lease revision, Input grant, workspace assignment,
  target version and zmx session before every forwarded `input`, `claim`,
  `reply` and `grid` frame, as ADR-0040 already requires before every write.
  Remote-owned panes (`PersistenceOwner.remoteZmx`) have no local daemon and
  are not typeable from a device in this version.

### Safe paste

- **One paste is one `input` frame**, and one frame is one daemon
  `UserBatch`. The daemon never interleaves a competing batch inside it
  (ADR-0036). The composer's optional Enter is a trailing carriage return in
  the same frame, so it cannot land after a Mac keystroke.
- **Bracketed paste follows the application.** The phone's emulator tracks
  mode 2004 from the same bytes the Mac sees. When set, the phone wraps the
  text in `ESC [200~` and `ESC [201~` and leaves line terminators intact;
  when not set, it converts newlines to carriage returns and sends plain
  text. This is Ghostty's own encoding rule (`src/input/paste.zig`), reused
  on the phone rather than reimplemented on the Mac.
- **Confirmation uses Ghostty's safety rule.** A bracketed paste is unsafe
  only if it contains the bracket terminator; an unbracketed paste is unsafe
  if it contains a newline, carriage return or the terminator. Unsafe text
  shows a confirmation on the phone with the reason and a preview; the
  person can send it anyway or cancel. Text containing the terminator is
  confirmed with that reason rather than silently edited, matching the Mac
  app's `clipboard-paste-protection` behavior. Typed keystrokes and quick-key
  bar keys never confirm.
- **Size limits are enforced on the Mac.** An `input` frame is at most
  64 KiB, the same cap as output frames (ADR-0040). The phone refuses a
  larger paste before sending and says so; the Mac ends a stream that sends
  one with `protocol_error`. A frame the daemon's operation queue rejects
  (256 KiB of pending payload or 4096 operations, LEADERSHIP.md) is reported
  in the next `ack` as `rejected: [seq]`; the phone marks it not delivered
  and the person resends by hand. No frame is retried automatically.
- Keystrokes typed within a short window may be coalesced into one frame;
  a paste is never merged with keystrokes or with another paste. Recommend
  an ack budget of two seconds: an `input` frame not acknowledged within it
  is shown as delivery unknown, which ADR-0040 already defines.

### Revocation and reconnect

- Turning the Input power off, removing a workspace from its list, revoking
  the lease or unpairing ends every affected stream with `role_changed` or
  `revoked`, detaches the relay's zmx client and drops queued bytes. The
  daemon's close-connection cleanup clears that client's leadership and
  invalidates its queued replies while retaining the grid (ADR-0036). The
  pane is then leaderless at the phone's grid until the next Mac keystroke
  or Take over; the Mac banner changes to "No one is driving · 40×24 · type
  to take back". Bytes already forwarded cannot be withdrawn.
- **Stop** on the Mac banner is that revocation: it turns the device's Input
  power off and persists it, so the phone cannot reattach as interactive
  until re-enabled in Settings. Taking leadership back without revoking is
  simply typing on the Mac.
- A reconnect, route change or app restart is a new attach with a new
  generation and a new daemon attachment ID; the phone attaches as a
  follower with the same grant and must Take over or type again (ADR-0040).
  Input unacknowledged at disconnect is shown as delivery unknown and never
  resent. The phone ends the stream the moment the terminal view leaves the
  foreground, on lock and on dismissal, which also ends its leadership.
- Granting Input to a device that currently holds a Watch stream ends that
  stream with `role_changed`; the phone reattaches and receives the
  interactive role in the handshake. There is no in-stream upgrade.

### Escape and query replies after a leaderless reattach

#863 left this open. The Mac's own pane client still uses the legacy
`attach` stream, where a standalone `ESC` from a non-leader is ambiguous
with a terminal reply prefix, so after a leaderless reattach the daemon drops
it and answers only DA queries until recognized input or takeover
(LEADERSHIP.md). A paired device is unaffected: its `input` and `reply`
frames carry provenance, so a phone `ESC` is user input and claims.

| Option | Behavior | Cost |
| --- | --- | --- |
| A. Keep the limitation | Document it; first printable key or arrow claims | Lone ESC and CPR/DSR replies lost until then; vim and TUIs misbehave after reopen |
| B. Typed seam for the Mac client (recommended) | The Mac pane attaches with `AttachRole` interactive and sends `UserBatch`/`TerminalReply`, so ESC is unambiguous and a reply is a reply | Native input seam in the Mac client; LEADERSHIP.md already names it as the missing piece |
| C. Daemon answers from its own model while leaderless | Extend the DA fallback to CPR, DSR and mode reports the daemon can compute | zmx fork change; colour and clipboard queries still need a real client |
| D. Sole Mac client claims on reattach with the retained grid | `TakeOver` using the current rows and columns restores reply authority without a resize | Later Mac window resizes then apply, which bends the ADR-0036 keep-last-grid decision |

Recommend B now and C as a follow-up to make a leaderless pane answer the
queries it can. B does not elect a leader or resize; it only removes the
ambiguity, so ADR-0036's no-guessing rule holds. Do not add a timeout or
heuristic to elect on ESC.

## Consequences

#788 can build the Mac input path and banner on frames ADR-0040 already
defines, with the grant stored like Decide and Transcript. One workspace list
per power keeps Settings consistent, at the cost that a pane created later in
a granted workspace is typeable without a new prompt. The phone owns paste
encoding and confirmation because it is the emulator; the Mac owns the limits
because it is the trust boundary. A revoked or disconnected driver leaves the
pane at the phone's grid, which is the ADR-0036 trade-off and is visible on
the Mac banner. Option B adds a native input seam to the Mac client before
the Escape gap closes; until then the limitation stays documented.

Implementation must test concurrent typing from Mac and phone, paste with and
without mode 2004, the terminator confirmation, oversized and queue-rejected
frames, revocation mid-paste, reconnect with unacknowledged input, and a
leaderless reattach against real TUIs. These are future acceptance checks;
this record provides no runtime evidence.

## Decisions for Sarah

1. Scope the Input grant to Mac-selected workspaces, mirroring ADR-0039,
   rather than per pane as ADR-0036 wrote or one device-wide switch?
2. Make **Stop** on the Mac banner a persisted revocation of that device's
   Input power, with typing on the Mac as the non-revoking way to take back,
   rather than a one-time end of the stream the phone can reattach past?
3. Adopt Ghostty's paste safety rule as the confirmation trigger (terminator
   always; line terminators only when bracketed paste is off), rather than
   confirming every multi-line paste regardless of mode?
4. Cap an input frame, and therefore a paste, at 64 KiB with a phone-side
   refusal above it, rather than allowing up to the daemon's 256 KiB queue?
5. For Escape and query replies after a leaderless reattach, take option B
   (typed seam for the Mac client) now with C as a follow-up, rather than
   keeping the limitation or letting a sole Mac client claim on reattach?
6. Require only the M1 terminal unlock gate before Take over, with no
   additional biometric prompt per takeover?
