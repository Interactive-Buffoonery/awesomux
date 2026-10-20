# Codex shared-server hook attribution E2E

Run from the repository root on macOS with Swift 6.3+, Python 3, and a released
`codex` on `PATH`:

```sh
python3 script/codex-shared-server-e2e/run.py --output /tmp/codex-shared-server-evidence
```

The runner builds `awesoMuxAgentHook` from this checkout (a cold checkout may
fetch package dependencies), starts a local mock Responses server, and gives
each scenario a fresh `HOME` and `CODEX_HOME` under a new `run-*` directory. Codex
processes get an allowlisted environment, so no `AWESOMUX_*`, `CLAUDE_*`, or
Codex control variables leak in, and `~/.codex` is never read. Model requests
go to the local mock; no credentials are used.

Two real Codex TUIs run in separate PTYs as panes A and B, each with its own
`AWESOMUX_AGENT_EVENT_FILE`, matching awesoMux's per-pane export. The
repository's Codex `hooks.json` is trusted through the TUI's own startup review
("Trust all and continue"). `AWESOMUX_AGENT_HOOK` points at a wrapper that logs
each invocation (event, thread id, the pane identity it ran with, and the
synthetic prompt text), then hands the unchanged payload to the built helper.
The prompt text ties each thread to the TUI that submitted it.

Scenarios (`--scenarios` selects a subset):

- `shared-daemon`: A starts Codex's managed app-server, then B attaches. On the
  tested Codex 0.163.0, B's lifecycle events and thread id land in A's file, the
  hooks run with A's pane identity, and B's file stays empty (openai/codex#48500
  reports the behavior since 0.157).
- `no-daemon`: both clients run `codex --no-daemon`, so hooks run in each TUI
  with its own environment. Each file holds only its own client's thread, and no
  app-server process exists.
- `founder-closed`: A and B both finish a turn, then A exits and its file is
  removed, as awesoMux does when a pane closes. B's next turn completes and its
  hooks still run as pane A, but no pane file receives the events.

Each scenario checks named conditions, so an unanswered trust screen or a
stalled client reports `FAIL`, not a reproduction. A turn counts as complete only
when a Stop hook for its thread follows that prompt's own submit record. File
routing is checked both before and after daemon shutdown. Scenario errors,
cleanup errors, and processes that survive cleanup also fail the run. The exit
status is nonzero unless every selected scenario matches.

Cleanup stops each TUI's process group and runs `codex app-server daemon stop`.
It then kills only processes whose executable lives under that scenario's
`CODEX_HOME`, plus their descendants, and checks for survivors. The
`report.json` file records the Codex CLI and running daemon versions, the git
head, and hashes of the helper, `hooks.json`, and harness. It also records hook
invocations, event-file snapshots, and any processes cleanup had to kill. PTY
output is kept as `screen-*.bin`. Generated evidence is not committed.

This harness exercises the hook helper and event files. It does not cover the
app's reducer, Send gate, approvals, tool execution, or UI.
