# awesoMux Beachball Investigation

Use this when awesoMux beachballs or visibly stalls, especially when Activity
Monitor memory is not obviously high. Low memory use does not clear the app:
beachballs usually mean the main thread is blocked, WindowServer is saturated,
or a high-rate callback is flooding the main queue.

## What We Already Know

- The old daily-driver sluggishness had a concrete build cause:
  `script/build_and_run.sh` used to launch debug builds. Daily run and install
  paths now build release by default.
- The big RAM spike was a separate Ghostty surface lifetime bug. The useful
  cheap counter is `surfaces`, because persisted session state can say one pane
  while `GhosttyRuntime` still retains more graphics-backed surfaces.
- The one-surface warm baseline on this machine is currently around
  268-283 MB `phys_footprint_bytes`; no single `vmmap` bucket dominated that
  baseline. Do not treat every warm footprint as a leak.
- A 7-pane / 5-agent workload with less than 1 GB RAM but many beachballs is
  therefore a stall investigation first, not a memory-tuning investigation.

## Capture Protocol

Start from the installed daily-driver bundle when testing what eD actually
uses:

```sh
AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS=5 ./script/build_and_run.sh --perf-install \
  | tee "docs/debugging/perf-traces/beachball-$(date +%Y%m%d-%H%M%S).log"
```

Recreate the workload: roughly three workspaces, seven terminal panes, and five
LLM sessions actively producing or waiting on output. When the beachball starts,
leave awesoMux stuck and run this from a separate terminal:

```sh
script/capture-awesomux-hang.sh --label 7-panes-5-llms
```

Repeat two or three times if the stall is intermittent. One sample can catch a
coincidence; repeated samples showing the same top frames are evidence.

The script writes raw artifacts under:

```sh
docs/debugging/perf-traces/hang-captures/
```

That directory is intentionally ignored by Git. Raw samples can include local
paths and terminal text; commit only short summaries.

## What To Look For

If the `sample.txt` main thread is inside `visibleStateSamplingTask`,
`sampleAgentStateFromVisibleText`, `visibleTerminalText`, or
`ghostty_surface_read_text`, the likely fix is to gate the visible-text fallback
more aggressively. The runtime side channel should carry most agent state, so
visible text should not get unlimited sampling budget under heavy output.

If the main thread is in SwiftUI/sidebar rendering, inspect whether agent state
updates are causing excessive row recomputation or animations while several
background agents churn.

If the main thread is doing JSON or file I/O, inspect `SessionPersistence` and
`AgentRuntimeEventBridge`. The kqueue side channel should be cheap, but the
capture should decide whether event-file reads need batching or off-main work.

If `top.txt` shows high WindowServer, high awesoMux CPU, or high thread/port
counts without matching `surfaces`, pivot to renderer pressure or observer/task
lifetime rather than scrollback.

If `surfaces` grows and does not return after closing panes/workspaces, this is
back in surface-lifetime territory. Use
[`memory-surface-investigation.md`](memory-surface-investigation.md) instead.

## Current Suspect To Prove Or Clear

**Update (INT-523, 2026-06-30):** the draw path described below was removed. The
`draw(_:)` override no longer exists — it used to call `ghostty_surface_draw`
synchronously on the main thread (up to ~120Hz/pane), redundantly with
libghostty's own renderer thread, and ran the samplers after it. That redundant
main-thread present was the larger main-actor stall risk and is now gone; the
samplers moved onto `GhosttySurfaceNSView.visibleStateSamplingTask` (a ~250ms
poll, suspended while occluded). So this suspect is **cleared by construction**
for the synchronous-present path. The residual cost — `sampleAgentStateFromVisibleText`
reading the viewport via `ghostty_surface_read_text` at most every 0.5s per
*visible* pane on the main actor — remains, now poll-driven rather than
frame-driven. If a beachball still shows that read in the stall stack, the
upgrade path is to gate the read on a libghostty content-change signal (see the
ceiling note on `visibleStateSamplingTask`).

The original hypothesis, retained for context: that read converts to a Swift
`String` and runs agent-output detection on the main actor — plausible beachball
fuel when multiple visible panes have LLMs writing rapidly. Fix the residual only
after `sample.txt` shows it in the stall stack.
