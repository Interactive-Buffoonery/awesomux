# Codex transport verification

The original PR harness reproduced three failures against base `c96d09c2`:
repeated close left a TERM-resistant child, and blocked sends prevented both
request timeout and cancellation from returning. The subsequent transport
change made those cases pass along with echo, silent response, send-after-close,
natural exit, and deinit scenarios. These historical results are retained here
as a summary; their generated logs have been removed from Git.

For the review follow-up, the `descendant` scenario forks a helper that keeps
the app-server pipes open and ignores TERM. Before process-group cleanup, the
driver reported `child_gone=true descendant_gone=false` and exited 1. After
the change it reported both gone and exited 0. The runner writes build logs,
individual case logs, source and harness hashes, and `report.json` to its
printed temporary directory. Reproduce with:

```sh
python3 script/codex-transport-e2e/run.py --cases descendant
python3 script/codex-transport-e2e/run.py --contracts
```

The process owns a distinct process group. Close sends TERM to the group, then
KILL after 250 ms; it keeps the leader unreaped until escalation so its group
ID cannot be reused. A child that exits on its own causes the reaper to kill
remaining group members before collecting the leader. Stdin poll errors now
return `connectionClosed`, and a check after process-source activation catches
an exit that occurred before the source registered.

No new unit tests were added. The `--contracts` option runs the existing client
contract suite without changing it. See each generated report for exact run
results and artifact paths; the final task report records other checks.
