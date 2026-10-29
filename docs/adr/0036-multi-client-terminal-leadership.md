# 0036 — Many terminal clients, last typer leads

- **Status:** Accepted (amended 2026-10-29: a Mac pane recovers a leaderless session — see Amendment)
- **Date:** 2026-10-20
- **Accepted:** 2026-10-20 — Sarah accepted the recommendation as written
- **Deciders:** Sarah
- **Issue:** [#784](https://github.com/Interactive-Buffoonery/awesomux/issues/784)

## Context

[ADR-0011](0011-persistent-session-daemon-command-bridge.md) leaves multi-attach
and resize authority open. A phone watches the same Mac-owned PTY; it does not
create a second session. This proposal sets the policy for #826 (stream)
and #827 (watch-only clients). Those issues implement the wire and daemon changes;
this docs-only record neither implements them nor accepts ADR-0011 as a whole.
Sarah accepted this record on 2026-10-20; it is now policy for that work.

The Companion [snapshot findings](https://github.com/Interactive-Buffoonery/awesomux-companion/blob/main/spikes/snapshot-reconnect/README.md)
show retained cells but lost soft-wrap provenance, command marks and exit codes.
The [verification ledger](https://github.com/Interactive-Buffoonery/awesomux-companion/blob/main/spikes/snapshot-reconnect/verification.md)
separates diagnostic reconnect evidence from production transport acceptance.
Watching must preserve the authoritative grid, not invent device-width reflow.

## Options considered

- **One writable client, explicit handoff:** prevents interleaved typing, but
  adds a lock and recovery UI to every move between desk and phone.
- **Many clients, last typer leads (chosen):** matches the intended desk
  handoff; simultaneous typing can interleave and resize the shared application.
- **Mac always sets size:** steady at the desk, but makes phone takeover cramped
  and contradicts the intended last-typer behavior.

## Decision

**Recommendation:** allow several interactive clients and watch-only clients;
the most recent accepted user input from an attached interactive client sets
the size leader and its grid. Below, "leader" means this size authority, not an
assumption that the current zmx Init/leader behavior already satisfies it.

- Leadership controls PTY size, not exclusive permission to type. Serialize
  accepted input at the daemon; server order, not device clocks, breaks ties.
  Each accepted input batch changes leader and applies that client's validated
  dimensions before forwarding its bytes. Do not interleave a paste batch with
  a competing batch. Batch bounds and input retry behavior belong to the later
  input protocol; disconnected input must never be replayed automatically.
  Automation such as `amx send` never claims leadership or changes dimensions.
- An interactive client's explicit **Take over** claims leadership without
  injecting a dummy keystroke. Otherwise attach, focus, polling, terminal
  replies and output do not claim leadership. The client that creates a new
  session is its first leader and supplies the initial grid. It retains that
  authority until another client claims, it disconnects, or it returns to Watch.
  Attaching to an existing session never claims leadership and preserves its
  current grid (narrowed for Mac panes by the 2026-10-29 amendment).
- Only the leader's resize changes the PTY. Followers retain their requested
  dimensions for their next claim. A watch client cannot send input, claim,
  resize or send terminal-generated replies to the PTY. Enforce this in the
  daemon as well as the Mac relay; hiding controls on the phone is insufficient.
- A non-leading interactive renderer must also suppress automatic terminal
  replies; only the leader can answer terminal queries. Replies never claim
  leadership. Changing roles or leader must invalidate queued replies from the
  previous authority. Drop queued, not-yet-forwarded input on revocation or
  downgrade to Watch as well. The wire design must distinguish user input from
  replies. Remote renderers ignore clipboard, notification and other host-effect
  sequences; links never open automatically.
- On leader disconnect, revocation, or return to Watch, clear leadership and
  retain the last grid. Do not elect a watcher or resize to another client.
  The next eligible user input or explicit claim selects a leader (narrowed
  for Mac panes by the 2026-10-29 amendment). With no
  clients, the daemon and process survive under existing lifecycle policy.
  Reconnect is a new attachment, never restoration of a previous claim.
- Watch uses the authoritative grid with scaling and panning. Rotation changes
  presentation only. A follower Mac surface must likewise present the leader's
  grid without rewrapping (for example, clipped or letterboxed), with a leader
  indicator; #826 must account for the nested emulator boundary. Watching does
  not change Mac selection, focus or unread state. A fresh snapshot plus ordered live output must identify its session
  generation and grid; a gap or restart requires a new snapshot, with incomplete
  history visible. Do not infer command history or soft wraps from plain rows.
- The Mac maps a paired, authorized device to a specific pane and role. No raw
  zmx socket or arbitrary command forwarding is exposed. Revocation stops that
  device's stream and any input authority. Pairing identity, mutual TLS and route
  rules from [ADR-0035](0035-awesomux-companion-pairing.md) remain unchanged.
  Its status-only operation limit is extended by a new terminal capability:
  recommend Mac-approved, per-device access, defaulting to Watch, with a separate
  input grant. The corresponding ADR-0035 scope amendment is recorded in
  that ADR's Amendment (2026-10-20) section.

## Consequences

Watch can ship before Take over and before any device input path. #827 must
prove that a watcher never leads,
including when the Mac detaches. #826 must preserve ordering and snapshot
boundaries. Later input work must test concurrent typing, paste, terminal
replies, rapid resize, role changes, revocation and reconnect against real TUIs.
These are future acceptance checks, not results of this documentation change.

Keeping the last size avoids disruptive fallback resizes but may leave a
phone-sized grid after its disconnect. Even a sole Mac reattachment retains
the old grid until input or Take over; this intentionally differs from current
reattach resizing and has Sarah's explicit approval (question 2 below). The
2026-10-29 amendment reverses this for Mac panes. "Mac-sized Watch" is the
M1 case; after takeover, Watch follows the last authoritative grid. Concurrent
typers share one input stream;
this is not collaborative editing. The Mac must show when another client leads.
Reflow and durable command history need separately proven formats.

## Open questions for Sarah

Answered by Sarah on 2026-10-20; the recommendation is accepted as written.

1. Confirm last-typer leadership, including an explicit Take over claim, rather
   than an exclusive writer lock?
   **Decision:** yes. Last typer leads; Take over is an explicit claim.
2. Keep the last grid with no leader after disconnect or return to Watch, until
   the next input/claim, including sole-Mac restore, rather than reverting to
   the Mac's size? This qualifies the plan's "Mac-sized Watch" wording after M2.
   **Decision:** yes. Keep the last grid after the leader disconnects; no
   automatic fallback resize. (Narrowed for Mac panes by the 2026-10-29
   amendment.)
3. Accept concurrent input in daemon order with a visible leader indicator, or
   require an exclusive handoff before the input milestone? Alternating typers
   can repeatedly resize a TUI. Confirm Mac-approved per-device Watch access
   with a separate input grant?
   **Decision:** concurrent input in daemon order with a leader indicator; no
   exclusive handoff. Watch is Mac-approved per device and defaults on grant;
   input is a separate grant.

## Amendment (2026-10-29): a Mac pane recovers a leaderless session

Question 2 is narrowed for the Mac's own panes. Keeping the old grid left a
Mac pane stuck at a phone-sized or stale grid after the phone left or after
a reattach, and resizing the pane did nothing until a keystroke. Every
resize then reflowed at the wrong width, which garbled TUIs such as Claude
Code over SSH.

- A leaderless session is claimed by a Mac pane's attach or resize. The
  claim is an ordered operation that is checked again when it runs, so an
  earlier Take over or keystroke still wins.
- When any client leaves a leaderless session, or the leader disconnects or
  returns to Watch, and exactly one Mac pane remains attached, that pane
  becomes leader at its own size.
- With two or more Mac panes and no leader, the session stays leaderless
  until one of them types or resizes, so two windows never fight over the
  grid.
- A phone or iPad, a watcher and automation never recover leadership on
  attach or resize; they still claim only by typing or Take over.

Recovery keys on the Mac pane's legacy `attach` stream. If ADR-0041 option B
moves the Mac pane to the typed seam, that client needs an explicit
"recovers leadership" flag in the handshake instead.
