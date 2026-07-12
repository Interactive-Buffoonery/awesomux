# Memory and Ghostty Surface Investigation

Use this checklist when checking whether high memory use is expected live
surface cost or a leak. The daily-driver memory issue tracked in INT-390
was observed in a release build, so release sampling is the primary path.
The older DEBUG-only surface-cache logs are still useful for close/recycle
lifecycle debugging, but they are not enough for steady-state drift.

## Release Build Sampling

Run awesoMux in release with opt-in performance sampling:

```sh
./script/build_and_run.sh --perf
```

The script enables `perfSampleIntervalSeconds` for the app domain, launches
the staged bundle, streams the relevant unified logs, and deletes the default
again when the log stream exits. Mach port enumeration is deliberately off by
default because `mach_port_names` is an expensive process-wide snapshot; the
script writes `perfSamplePorts=false` unless explicitly requested. The running
app reads the sampling flags at startup, so pressing `Ctrl-C` stops the log
stream but not an already-running sampler; quit awesoMux to stop in-process
sampling.

Override the interval when needed:

```sh
AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS=10 ./script/build_and_run.sh --perf
```

Opt into Mach port-name enumeration only when a port leak is part of the
question:

```sh
AWESOMUX_PERF_SAMPLE_PORTS=1 ./script/build_and_run.sh --perf
```

To measure the installed daily-driver bundle instead of the staged `dist`
bundle, use:

```sh
./script/build_and_run.sh --perf-install
```

Each `perf-sample` log line includes:

- `surfaces`: current `GhosttyRuntime.surfaceViews.count`. This is the cache
  count, not a guarantee that every cached view has a native surface at that
  exact instant.
- `resident_bytes`: resident size from `task_info(TASK_VM_INFO)`.
- `phys_footprint_bytes`: physical footprint from `task_info(TASK_VM_INFO)`.
- `threads`: current thread count from `task_threads`.
- `mach_ports`: `disabled` unless `AWESOMUX_PERF_SAMPLE_PORTS=1` or
  `perfSamplePorts=true` was set before launch; when enabled, this is the
  current Mach port-name count from `mach_port_names`.

A value of `-1` means that specific enabled system snapshot failed. Do not
treat it as a real zero.

When testing local daily-driver behavior, record which bundle you launched:

- `dist/awesoMux.app` from `./script/build_and_run.sh --perf`
- `~/Applications/awesoMux.app` from
  `./script/build_and_run.sh --perf-install`

For install-loop bugs, verify the installed bundle. A fresh `dist` bundle can
exist while the daily-driven app in `~/Applications` is stale.

## DEBUG Surface Cache Logs

For mutation-level lifecycle debugging, run a DEBUG build:

```sh
./script/build_and_run.sh debug
```

This opens `lldb` for the debug binary. Type `run` at the `(lldb)` prompt to
launch the app, then stream logs from another terminal.

Stream the surface cache logs in another terminal. The `--level debug` flag is
load-bearing because `Logger.debug` messages are filtered out by default:

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "com.interactivebuffoonery.awesomux" AND category == "GhosttyRuntimeMemory"' \
  | tee "surface-cache-$(date +%Y%m%d-%H%M%S).log"
```

Each cache log line includes:

- `event`: lifecycle event such as `create-finish`, `discard`,
  `discard-all-start`, or `reload-finish`.
- `session` and `pane`: UUIDs when the runtime call has that context.
- `surfaces`: current `GhosttyRuntime.surfaceViews.count`.
- `snapshot_ok`: `true` if `task_info` succeeded. If `false`, byte fields are
  zeroed because the snapshot failed.
- `resident_bytes`: resident size from `task_info(TASK_VM_INFO)`.
- `phys_footprint_bytes`: physical footprint from `task_info(TASK_VM_INFO)`.

Cache reuse is intentionally not logged because it fires on SwiftUI re-render.

## Baseline Measurement Pass

For each checkpoint, wait 20-30 seconds after the final workspace opens before
recording memory. Repeat the close/reopen step once to check whether discarded
surfaces return memory or keep growing.

1. Launch awesoMux with one workspace and one pane.
2. Record Activity Monitor memory, `resident_bytes`, `phys_footprint_bytes`,
   `threads`, and `mach_ports` when port sampling was enabled.
3. Add workspaces until there are 2, 4, and 8 workspaces.
4. Record the same values after each step.
5. Run output-heavy commands in at least two panes.
6. Use the floating panel once with an idle slot and once with running work.
7. Paste one medium image-only clipboard item.
8. Close workspaces back down to one.
9. Record whether `surfaces` follows the visible pane count and whether memory
   drops, plateaus, or keeps increasing.

For a port-count pass, rerun the same checkpoints with
`AWESOMUX_PERF_SAMPLE_PORTS=1`; otherwise `mach_ports=disabled` is the expected
cheap-sampling sentinel.

For INT-390, the first useful capture is an hour-long normal workflow, not
only a synthetic stress loop. The synthetic steps above give landmarks inside
the trace; the remaining time should be normal daily-driving.

## Cross-Checks

Use `vmmap` against the running app process when the 4-workspace case looks
large:

```sh
vmmap "$(pgrep -x awesoMux | head -1)" | less
```

`pgrep -x` requires an exact name match to avoid helper-name collisions, but
it can still return multiple PIDs if multiple awesoMux instances are running
(e.g. when launched with `open -n`). Pipe through `head -1` if you need a
single PID.

Use `leaks` only after the app has been idle for a short period. For actionable
backtraces, launch the app with `MallocStackLogging=1` in the environment;
without it `leaks` reports addresses without call sites:

```sh
./script/build_and_run.sh --malloc-stack-logging
leaks "$(pgrep -x awesoMux | head -1)"
```

The `--malloc-stack-logging` mode launches the staged executable directly
instead of going through `/usr/bin/open`, so the environment reaches the app
process.

> **Heads up.** `MallocStackLogging=1` writes allocation backtraces (and on some
> macOS versions allocation contents) to `/tmp/stack-logs.*`, world-traversable
> by anything running as the same user. Don't run this mode while handling
> secrets in the terminal, and clean up `/tmp/stack-logs.*` after the session.

Use Instruments when the sampler points at a class of problem:

- Allocations if `surfaces` returns to baseline but footprint does not.
- Time Profiler and Hangs if beachballing aligns with workspace switch,
  pane split/close, paste, draw, or visible-text sampling.
- Leaks after a stable repro exists.

## Ghostty config precedence (INT-396 AC #2)

awesoMux's libghostty config is built in `GhosttyRuntime.makeGhosttyConfig`
in this order:

1. `GhosttyRuntimeDefaults.defaultConfigContents` (awesoMux suggestions,
   including `scrollback-limit = 5_000_000`).
2. `ghostty_config_load_default_files` (user's `config.ghostty` or legacy
   `config` in Ghostty's default config locations).
3. `ghostty_config_load_recursive_files` (user's recursive imports).
4. Appearance overrides (awesoMux theme/runtime values).
5. `ghostty_config_finalize`.

libghostty is last-write-wins, so user config does and SHOULD override
`scrollback-limit`. This is intentional product behavior — the user is the
source of truth for their own machine. If your warm-baseline footprint is
high and you have a user-set `scrollback-limit`, that value is what is in
effect, not the 5MB default.

The empirical question — which memory bucket dominates the warm baseline
(graphics / heap / scrollback / framework caches) — is tracked as a follow-up
to INT-396 and requires release-build vmmap captures rather than code reading.

## Decision Table

- `surfaces` grows and never returns after close: fix lifecycle/discard paths.
- `surfaces` returns but footprint does not: inspect native allocations with
  `vmmap`, `leaks`, and Instruments Allocations.
- Memory scales linearly with live surfaces and recovers after close: tune
  per-surface policy such as scrollback and renderer/resource defaults.
- Beachballing aligns with `GhosttySurfaceView.draw` or visible-text reads:
  profile and gate visible-text sampling before deeper memory work.
- Thread count grows without surface growth: inspect observers, tasks, and
  libghostty callback paths.
- Port count grows without surface growth: rerun with
  `AWESOMUX_PERF_SAMPLE_PORTS=1`, then inspect observers, tasks, and libghostty
  callback paths.

Expected first-pass outcome is not a fix. The useful result is a table showing
workspace count, surface count, Activity Monitor memory, resident bytes,
physical footprint bytes, thread count, Mach port count when enabled, and
whether values recover after surfaces are discarded.

## Empirical baseline (INT-397)

INT-397 captured one-surface cold / warm-A (terminal-only scrollback fill)
/ warm-B (full app-chrome) snapshots on a release build at commit
`6ae8b528`, Ghostty submodule `332b2aef`, macOS 26.5 build 25F71,
Mac17,3 hardware. Two runs: a defaults-only run (user Ghostty config
moved aside) and a user-config run (operator's Ghostty config in place).
Protocol: [`perf-traces/int-397-capture-protocol.md`](perf-traces/int-397-capture-protocol.md).

### Measured baseline (`phys_footprint_bytes`)

| Stage | Defaults run | User-config run |
|---|---:|---:|
| Cold | 230 MB | 230 MB |
| Warm-A (terminal-only) | 258 MB | 257 MB |
| Warm-B (full app-chrome) | 268 MB | 283 MB |
| Idle T+3 (no input) | 268 MB | 283 MB (no creep) |
| Δ warm-B − cold | **+36 MB** | **+50 MB** |

Cold is essentially identical between runs (user font/theme has no cold
cost). Warm-A is also essentially identical (scrollback fill cost is
shared; user config does not override `scrollback-limit`). Warm-B is
+14 MB higher with user config — broad, low-amplitude warming across
AppKit / SwiftUI / CoreText / compressed-memory accounting that no
single vmmap bucket attributes.

### Dominant bucket (vmmap DIRTY + SWAPPED, private)

Bucket decisions use **DIRTY + SWAPPED** (private pages, either resident
or compressed to swap — both count toward `phys_footprint_bytes`). The
original protocol locked RESIDENT, but RESIDENT inflates the diff with
shared library pages that `phys_footprint` excludes. DIRTY alone
undercounts because it misses compressed-private pages, which matters
when surface-close paths trigger compression rather than release (the
user-config run demonstrated this). DIRTY+SWAPPED is the correct
reconciliation target. See the protocol doc for the lock and the
bucket-diff files for the math.

For both runs, the Warm-B − cold diff shows **no single bucket above
the 30 MiB threshold the decision rule names as "actionable"**. User-
config has a directional finding — `IOAccelerator (graphics)` at +19.70
MiB (68% of Σ DIRTY+SWAPPED Δ) — but it's below threshold. The
`Unattributed` residual (phys Δ minus Σ DIRTY+SWAPPED Δ) is still large
in both runs (+78.7% defaults, +42.3% user-config), meaning the bulk of
the warm delta lives in IOKit / framework accounting that vmmap doesn't
directly attribute in the summary table.

### Decision applied

Per the pre-committed decision rule:

> Unattributed > 15% of phys Δ → refuse single-bucket dominance; file follow-up to instrument accounting.

Both runs fire this branch. The warm baseline at one surface is the
realistic floor on this hardware/macOS combo; no in-PR tuning is
warranted from this data. Follow-up GitHub issues track:

1. **Accounting-gap instrumentation** — extend the perf-sample line to
   include compressed bytes, anonymous bytes, and IOKit attribution so
   future captures attribute the gap rather than leaving it residual.
2. **Scrollback-fill GPU-buffer transience** — substantive cross-run
   finding (see below).

### Substantive cross-run finding: GPU buffers respond to surface-close, not to scrollback alone

In **both** runs, the scrollback fill (Warm-A) grew the
`IOAccelerator (graphics)` + `owned unmapped (graphics)` private buckets
(DIRTY+SWAPPED) by ~20-60 MiB. The primary surface's GPU buffers do not
auto-compact after a scrollback fill — they respond only when an unrelated
surface is closed. What "respond" means differs between runs:

- **Defaults run:** Warm-B's add+close-workspace step **released** the
  buffers. `IOAccelerator (graphics)` DIRTY dropped from 40.7 MiB
  (Warm-A) to 22.2 MiB (Warm-B) with SWAPPED at zero throughout. Σ DIRTY+SWAPPED
  for the GPU rows dropped by ~57 MiB across the surface-close.

- **User-config run:** Warm-B's add+close-workspace step **compressed
  to swap** instead of releasing. `IOAccelerator (graphics)` DIRTY went
  40.9 → 27.6 MiB, but SWAPPED went 0 → 13.3 MiB. Total
  DIRTY+SWAPPED stayed at 40.9 MiB. Σ DIRTY+SWAPPED for the GPU rows
  dropped by only ~3.6 MiB across the surface-close.

The release-vs-compress choice depends on macOS's runtime
memory-pressure policy at the moment of the surface-close, not on
awesoMux behavior. Either way, awesoMux does not get the live GPU
memory back from scrollback fill until another surface-close runs.
This is consistent with the INT-396 observation of phys sitting
elevated after work and only dropping on surface lifecycle events.

The traces and bucket diffs:

- `perf-traces/vmmap-summary-surface1-{cold,warmA,warmB}-defaults-20260514-195504.txt`
- `perf-traces/vmmap-summary-surface1-{cold,warmA,warmB}-userconfig-20260514-200937.txt`
- `perf-traces/int-397-bucket-diff-defaults-20260514-195504.md`
- `perf-traces/int-397-bucket-diff-userconfig-20260514-200937.md`
- `perf-traces/int-397-companion-defaults-20260514-195504.md`
- `perf-traces/int-397-companion-userconfig-20260514-200937.md`

### Release-safe config-environment log

This PR also adds a one-time info log at startup
(`subsystem=com.interactivebuffoonery.awesomux`,
`category=GhosttyConfigEnvironment`) recording the awesoMux-default
`scrollback-limit` plus existence flags for the two user-config paths
libghostty auto-loads. The DEBUG-only `logConfigDiagnostics` is not
present in release builds, so this line is what future captures should
key on to tell which side of the user-config override they're measuring.
See `Sources/AwesoMuxConfig/GhosttyConfigEnvironment.swift`.
