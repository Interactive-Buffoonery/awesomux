# Codex transport subprocess E2E

Run from the repository root on macOS with Swift 6 and Python 3:

```sh
python3 script/codex-transport-e2e/run.py --output /tmp/codex-transport-results --contracts
```

The driver compiles the actual production transport, client, wire models,
executable resolver, and clock. It does not launch Codex, inspect provider data,
or build Ghostty. Each case gets a disposable CODEX_HOME and Python subprocess.
The external runner applies a six-second watchdog; each fixture also has an
independent ten-second alarm in case its process group differs from the driver.
Temporary builds are retained and named in report.json for inspection.

Failure surfaces covered by the harness:

- Repeated close with a child that ignores TERM: child must exit and be reaped.
- A completed initialize followed by a 4 MiB config write to a child that stops
  reading: the request deadline must include pipe transmission.
- External cancellation during the same blocked write: the task must return,
  and the child must exit and be reaped.
- Normal initialize, large config write, and hooks/list round trip: newline
  framing, request IDs, `edits`, `upsert`, and reload flag remain usable.

Additional cases cover a silent response wait, sending after close, a naturally
exiting child, and teardown from deinit. `--cases close echo` selects cases.
`--contracts` copies the existing, unmodified client tests and their fake into a
temporary Swift package and requires a nonzero passing Swift Testing count.

To reproduce the original failures without changing the checkout:

```sh
python3 script/codex-transport-e2e/run.py --source-ref c96d09c2 \
  --cases close timeout cancel echo --expect-bugs --output /tmp/codex-transport-before
```

`--expect-bugs` requires close to exit 1, timeout/cancel to hit watchdog 124, and
echo to succeed. The committed `before` evidence was recorded before any
production edits; `before-recheck` uses the final harness against those same
original sources. Reports include source and harness hashes because evidence
can precede its owning commit.

No new unit tests are added. The root integration run owns full preflight and
application/UI verification.

To exercise an exit notification that arrives before the child is reapable:

```sh
python3 script/codex-transport-e2e/run.py --defer-first-reap --cases exit \
  --output /tmp/codex-reap-race
```

This explicitly labeled syscall fault injection returns zero from the first
`waitpid` call in a temporary source copy. Later calls reap the real subprocess.
Production source is unchanged; the report hashes the compiled copy and names
the injection. Build logs redact checkout and temporary build paths. Historical
committed build logs have only their checkout paths redacted.
