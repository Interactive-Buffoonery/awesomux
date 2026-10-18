# Codex client readiness integration

## Status and problem

This is an opt-in integration for a proposed Codex TUI callback. Stock Codex
releases do not implement `CODEX_CLIENT_EVENT_COMMAND`; exporting the variable
alone does not fix existing installations. Codex Send to Agent requires native
Ready evidence from startup, so it remains unavailable with stock Codex or
missing/failing callbacks. The matching upstream patch is required before
enabling an end-to-end rollout. Normal terminal use and the shared daemon
remain unchanged. No daemon-disable flag is used.

Codex's shared app-server can execute hooks with the environment inherited from
its first client. A writable pane event file and trusted Stop hook therefore do
not prove that a later client reports to that pane. A server thread identifier
also does not identify which client currently displays that thread.

References: [first-client environment issue](https://github.com/openai/codex/issues/48500)
and [hook client environment proposal](https://github.com/openai/codex/issues/44902).

## Contract

awesoMux supplies `CODEX_CLIENT_EVENT_COMMAND` as a JSON argv array containing
the absolute bundled helper path and `--codex-client-event`. The TUI executes
this directly, without a shell, using its own client environment. Server hooks,
shared threads, authentication, configuration and local workspace behavior stay
on their existing paths. The variable is pane-scoped and scrubbed alongside
other pane environment on remote boundaries.

The callback receives one JSON object on stdin (maximum 4096 bytes):

```json
{"v":1,"client_id":"11111111-1111-4111-8111-111111111111","sequence":1,"completed_turns":0,"thread_epoch":1,"session_id":"22222222-2222-4222-8222-222222222222","input_ready":true,"status":"ready","captured_at":1792340000.25}
```

`client_id` is a fresh UUID per TUI process. `sequence` increases across thread
switches. `completed_turns` is a monotonic counter of live successful completions
for the displayed client; replayed history does not increment it. The counter is
retained in full snapshots so callback coalescing cannot discard a completion.
`thread_epoch` increases on every selected-thread change, including switches
coalesced out of delivery; temporary nil-thread terminal handoff preserves it.
`session_id` identifies the displayed thread, or is null when no
thread is available. `status` is `ready`, `working`, `blocked`, `error` or `unavailable`.
Only `ready` permits `input_ready=true`, and it requires a thread ID.
`captured_at` is Unix seconds captured when the client observes the state,
not when a delayed callback executes.

The TUI reports full state after UI events and every five seconds. It reports
ready only when the active chat composer can accept input, with no pending turn,
modal, popup, reconnect or terminal handoff. Handoff first revokes readiness
and pauses reporting until the TUI explicitly resumes. Nested handoffs must
remain unavailable until the outermost operation finishes its final input drain.
In a running session, a recoverable input-drain timeout retains unavailability
and is retried during ordinary event/frame processing with bounded backoff;
only a successful drain permits readiness to recover. Initialization failures
and genuine terminal-restoration errors retain their existing error handling. Callback execution is
serialized, bounded and timed out. Exit zero acknowledges successful delivery;
invalid input and append failures in client-event mode exit nonzero. Before an
input handoff, failed revocation keeps reporting paused until the prior ready
lease expires (up to eleven seconds); successful delivery avoids that fallback
delay. Before a paste could reach another persistent input owner or thread, the
TUI discards buffered terminal input using its existing interactive-screen
boundary. This includes modals, transcript search, keyboard selection, new/fork/
resume navigation, session pickers and external-program handoffs.

Mouse/footer selections, copy/activity interactions, pending key chords and
preset menus suppress readiness without draining their gesture or shortcut
continuations: ordinary paste already cancels those states and reaches the
composer. Parent-owned, unavailable and unconfigured threads cannot report
ready merely because their recovery composer remains editable. Failed terminal
restoration stays unavailable until an actual successful restoration; ordinary
UI resume cannot clear it. An unset callback command leaves normal Codex
behavior unchanged.

This remains an observed readiness lease, not an atomic delivery protocol.
Abrupt process death can race with terminal input already sent; the callback
cannot guarantee delivery to the intended composer after a forced termination.

The helper derives its direct parent PID and process start time from the OS;
payloads cannot choose those fields. It appends to the existing pane sink using
the existing no-create regular-file writer. Invalid, stale, future or oversized
payloads are dropped silently. The runtime event carries this evidence in
`clientStatus`; malformed evidence drops the entire event rather than falling
back to a legacy waiting assertion.

The app accepts a report only when its parent incarnation matches the freshly
observed foreground Codex process. It binds client UUID and increasing sequence
to that incarnation, rejects pre-observation captures and expires positive
readiness after ten seconds. The Send gate drains pending runtime events before
checking trust, and watcher rearming invalidates prior observation evidence while
preserving the native-authority latch. Terminal status escapes, titles, cwd, focus and
recency cannot authorize sending. Legacy Codex lifecycle hooks can update
display state but never authorize Send, including before the first callback,
after app/watch recreation, or when callbacks fail. Only matching fresh native
Ready evidence authorizes Codex Send; a delayed daemon Stop cannot reacquire
readiness after foreground loss. Other providers retain their existing path.

## Implementation and verification

The receiver consists of the existing hook executable, runtime-event parser,
ordered client evidence tracker, pane runtime reducer and existing Send gate.
Failed-turn snapshots retain error display and the existing acknowledgement policy.
Unavailable reports revoke sending without inventing an agent completion or
exit. Display state and attention are preserved until a full selected-thread
snapshot supplies a new claim. Thread changes reset thread-local lifecycle
bookkeeping while retaining client sequence ordering. Ready heartbeats only
refresh trust. A new completion count in the same client, thread and thread epoch produces
one aggregate unread/unanswered completion when input becomes ready; first
observations and thread/client changes establish a baseline. Proven app-side shell/SSH
exit cleanup has an explicit internal route that clears native authority.
Readiness changes invalidate the Send UI; expiry work is cancelled at pane teardown.

Run the repeatable receiver fixture in `script/codex-client-events-e2e/`.
It exercises the real helper executable and compiled Core parser/tracker.
The upstream patch must separately pass its real TUI readiness tests and
multi-process callback fixture. Neither fixture proves physical keyboard,
VoiceOver or Markdown-button behavior. A release needs an isolated dev-app
run with the patched Codex, including two clients displaying the same thread,
thread switching, modal open/close, stop/relaunch and reporter expiry.
