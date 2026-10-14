# Codex transport verification — 2026-10-14

Base: `c96d09c2`. Production changes are confined to
`ProcessCodexAppServerTransport.swift` and `ProcessCodexAppServerClient.swift`.

## Before production changes

`evidence/before/` records the original production sources compiled by the
standalone driver:

- Repeated `close()`: TERM-resistant child still present after 1.5 seconds;
  driver exit 1.
- Pipe backpressure after successful initialize: 300 ms request timeout never
  reached while sending a 4 MiB config write; external six-second watchdog
  stopped the driver (exit 124).
- Cancellation during that send: same watchdog failure (exit 124).
- Normal large config write and hooks/list: passed (exit 0).

`evidence/before-recheck/` reproduces these signatures using the final harness
and original sources extracted from Git. Neither run launches user Codex or
reads its configuration.

## Fixes

The transport owns its child with `posix_spawn` and an exit dispatch source.
Only its locked reaper releases the PID; TERM and delayed KILL use the same
lock. A terminated-but-unreaped child still reserves its PID. Close remains
idempotent; a 250 ms escalation retains ownership even after transport deinit.
Only the direct child is signaled. Standard descriptors, literal arguments,
minimal PATH/CODEX_HOME environment, and executable resolution are preserved.

Stdin is nonblocking with per-descriptor SIGPIPE suppression. One serial queue
writes complete frames and closes its descriptor, so close cannot recycle the
FD underneath a writer. Backpressure waits in 25 ms poll intervals off the
cooperative executor; close/cancellation interrupts the loop. The client's
absolute request deadline and cancellation scope now enclose transmission and
response correlation. JSON-RPC envelopes and public protocols are unchanged.

## After

`evidence/after/` contains source/harness hashes, build commands, and all logs:

- Eight real subprocess scenarios passed: repeated close, blocked-send timeout,
  blocked-send cancellation, large-message round trip, silent-response timeout,
  send after close, natural exit, and deinit.
- Blocked-send timeout: `requestTimedOut(config/batchWrite)` in 0.379 seconds
  including encoding/handshake. Cancellation: `CancellationError` in 0.232
  seconds. Silent-response timeout: 0.353 seconds.
- Every fixed scenario checked that its child was gone/reaped. An additional
  process inventory found zero remaining fixture processes.
- All 16 existing client tests passed, copied without edits with their existing
  fake transport into a standalone Swift package. This is focused contract
  evidence, not the repository's full integrated Swift suite.
- Changed-line Swift formatting lint and `git diff --check` passed.

Exact final checks (from the isolated worktree):

```sh
python3 script/codex-transport-e2e/run.py --source-ref c96d09c2 \
  --cases close timeout cancel echo --expect-bugs \
  --output script/codex-transport-e2e/evidence/before-recheck
python3 script/codex-transport-e2e/run.py \
  --output script/codex-transport-e2e/evidence/after --contracts
./script/format.sh --lint
git diff --check
```

No unit tests were added. Full preflight, Ghostty/app build, UI checks, and live
Codex compatibility were not run; the root integration run owns those checks.
No submodules or integration-tree files were changed. No push, PR, tracker, or
comment actions were performed. PID reuse itself was not forced experimentally;
its safety follows from exclusive reaping and signaling under one lock.
