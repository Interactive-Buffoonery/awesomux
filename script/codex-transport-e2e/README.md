# Codex transport subprocess E2E

Run from the repository root on macOS with Swift 6 and Python 3:

```sh
python3 script/codex-transport-e2e/run.py --output /tmp/codex-transport-results
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

`--cases close echo` selects cases. `--expect-bugs` checks the original failure
signatures (close exits 1; timeout/cancel hit watchdog 124; echo succeeds).
Run that option against c96d09c2 with this harness copied into an isolated tree.
The committed before evidence was recorded before any production edits. Reports
include production source hashes because evidence can precede its owning commit.

No new unit tests are added. The root integration run owns full preflight and
application/UI verification.
