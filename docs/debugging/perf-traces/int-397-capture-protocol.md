# INT-397 — capture protocol

Procedure for the empirical one-surface warm-memory baseline tied to
the performance-trace investigation. Follow
top-to-bottom. Two runs are required: a defaults-config run and a
user-config run.

This protocol assumes you are on the `issue/int-397-…` branch (or any
branch that ships the `GhosttyConfigEnvironment` startup log line — see
`Sources/AwesoMuxConfig/GhosttyConfigEnvironment.swift`).

## Definitions (locked before capture)

- **Cold** — process state immediately after `killall awesoMux`, cache
  + saved-state clear, fresh `--perf` launch, one workspace / one pane,
  no input, **steady-state criterion** met.
- **Steady-state criterion** — three consecutive `perf-sample` lines
  whose `phys_footprint_bytes` are within ±1% of their median.
- **Warm-A** — after a terminal-only workload (scrollback fill). No
  AppKit / floating-panel / workspace cycle touched.
- **Warm-B** — after a full app-chrome workload run on top of Warm-A
  (Settings, font picker, floating panel, workspace add+close).
- **Idle re-read (T+3 min)** — a single `phys_footprint` reading 3 min
  after Warm-B with no further input. Not a new vmmap, just a number to
  decide whether the warm baseline is stable.

## Pre-flight (per run)

1. Confirm worktree on the INT-397 branch.
2. Note macOS build (`sw_vers -buildVersion`), hardware (`sysctl -n hw.model`), and free RAM. Save for the companion `.md`.
3. Record commits:
   - `git rev-parse HEAD`
   - `git -C vendor/ghostty rev-parse HEAD`
4. Confirm `pgrep -x awesoMux` is empty. If not, `killall awesoMux && sleep 2`.
5. Clear app caches and saved state:
   ```sh
   trash ~/Library/Caches/com.interactivebuffoonery.awesomux 2>/dev/null
   trash "$HOME/Library/Saved Application State/com.interactivebuffoonery.awesomux.savedState" 2>/dev/null
   ```
6. **Defaults run only:** move user Ghostty config aside.
   ```sh
   for name in config config.ghostty; do
     [ -f ~/.config/ghostty/$name ] && mv ~/.config/ghostty/$name ~/.config/ghostty/$name.int397-bak
     [ -f "$HOME/Library/Application Support/com.mitchellh.ghostty/$name" ] && mv "$HOME/Library/Application Support/com.mitchellh.ghostty/$name" "$HOME/Library/Application Support/com.mitchellh.ghostty/$name.int397-bak"
   done
   ```
   Restore at the end of the run.

## Launch

```sh
./script/build_and_run.sh --perf
```

The perf-sample log stream runs in the launching terminal. After launch
you should see, near the top of that stream:

```text
GhosttyConfigEnvironment ghostty-config-env default_scrollback_limit_bytes=5000000 user_xdg_config_exists=<bool> user_app_support_config_exists=<bool>
```

Record those bool values in the companion `.md`. They tell future
readers which side of the user-config override this capture is on.

## Cold capture

1. One workspace, one pane. No input. Cursor in the pane.
2. Watch the perf-sample stream until three consecutive lines show
   `phys_footprint_bytes` within ±1% of their median.
3. Confirm `pgrep -x awesoMux | wc -l` is exactly `1`. Abort if not.
4. Capture:
   ```sh
   TS=$(date +%Y%m%d-%H%M%S)
   RUN=defaults   # or: user-config
   vmmap -summary "$(pgrep -x awesoMux)" \
     > "docs/debugging/perf-traces/vmmap-summary-surface1-cold-${RUN}-${TS}.txt"
   ```
5. Confirm the file is > 5 KB and contains a "Summary" line. If not,
   re-capture.
6. Record the perf-sample line nearest in time (write to companion `.md`).

## Warm-A — terminal-only workload

1. Determine the active pane's scrollback budget. Default = 5 000 000
   bytes (5 MB). Generate ~6 MB of deterministic output (slightly above
   the limit so the buffer fills fully):
   ```sh
   for i in $(seq 1 75000); do printf '%07d %-71s\n' $i "INT-397 scrollback fill line padded with deterministic content"; done
   ```
   That's ~6 MB of 80-byte lines. Paste into the pane and let it run to
   completion.
2. Wait for the prompt to return.
3. Wait for steady-state criterion in the perf-sample stream.
4. Capture:
   ```sh
   vmmap -summary "$(pgrep -x awesoMux)" \
     > "docs/debugging/perf-traces/vmmap-summary-surface1-warmA-${RUN}-${TS}.txt"
   ```
5. Record perf-sample line.

## Warm-B — full app-chrome workload (on top of Warm-A)

Do these in order:

1. Cmd+, to open Settings. Scroll once through each section. Close.
2. From Settings, open the font picker. Scroll once. Close. Close Settings.
3. Invoke the floating panel. Leave it idle for 15 s. Close.
4. Add a second workspace from the sidebar. In its pane:
   ```sh
   ls -laR /usr/bin > /dev/null
   ```
   Then close that workspace, returning to one.
5. Wait for `surfaces=1` to reappear in perf-sample.
6. Wait for steady-state criterion.
7. Capture:
   ```sh
   vmmap -summary "$(pgrep -x awesoMux)" \
     > "docs/debugging/perf-traces/vmmap-summary-surface1-warmB-${RUN}-${TS}.txt"
   ```
8. Record perf-sample line.

## Idle re-read (T+3 min)

Don't capture vmmap. Just record the `phys_footprint_bytes` from the
perf-sample line three minutes after the Warm-B capture, with no
further input. Write to the companion `.md`.

If the T+3 reading is greater than the Warm-B reading by more than the
steady-state tolerance (±1% of median), call it "creep" in the doc;
this triggers a follow-up GitHub issue per the decision rule.

## PII scrub

```sh
for f in docs/debugging/perf-traces/vmmap-summary-surface1-*-${TS}.txt; do
  if grep -F -q "/Users/$USER/" "$f" || grep -F -q "$(hostname -s)" "$f"; then
    sed -i '' "s#/Users/$USER/#/Users/<redacted>/#g; s#$(hostname -s)#<host>#g" "$f"
    echo "scrubbed $f"
  fi
done
grep -lF "/Users/$USER/" docs/debugging/perf-traces/vmmap-summary-surface1-*-${TS}.txt || echo "no leaks"
```

## Restore (defaults run only)

```sh
for name in config config.ghostty; do
  [ -f ~/.config/ghostty/$name.int397-bak ] && mv ~/.config/ghostty/$name.int397-bak ~/.config/ghostty/$name
  [ -f "$HOME/Library/Application Support/com.mitchellh.ghostty/$name.int397-bak" ] && mv "$HOME/Library/Application Support/com.mitchellh.ghostty/$name.int397-bak" "$HOME/Library/Application Support/com.mitchellh.ghostty/$name"
done
```

## After both runs

Hand the six trace files plus your noted readings back to the
implementer. They'll produce:

- a companion `.md` per run (schema in `STATE.md`),
- a bucket-diff `.md` per run (Warm-A vs cold, Warm-B vs Warm-A, Warm-B
  vs cold) in vmmap-DIRTY+SWAPPED space with an explicit "Unattributed" row,
- the appended "Empirical baseline (INT-397)" section in
  `docs/debugging/memory-surface-investigation.md`,
- the tuning decision per the rule in `STATE.md`.

## Decision rule (locked, applied to Warm-B vs cold)

**Accounting basis: vmmap `DIRTY + SWAPPED` columns** (private pages, either
currently resident or compressed to swap — both still count toward
`phys_footprint_bytes`). Earlier drafts of this protocol named `RESIDENT`;
that column inflates the diff by including shared library pages that
`phys_footprint` excludes (`mapped file`, `__TEXT`, `__LINKEDIT`, etc.).
DIRTY alone excludes compressed-private pages, which is wrong when the
app is under any memory pressure — the user-config run in INT-397
demonstrated this by moving 13.3 MiB of `IOAccelerator (graphics)` from
DIRTY to SWAPPED between captures (see the user-config bucket-diff file).
DIRTY+SWAPPED is the right reconciliation target.

| Condition | Outcome |
|---|---|
| `phys_footprint` Δ < 30 MB | accept-as-floor |
| Unattributed (phys_footprint Δ minus sum of vmmap-DIRTY+SWAPPED bucket Δs) > 15% of phys Δ | refuse single-bucket dominance; file follow-up to instrument accounting |
| Any MALLOC-family bucket: \|Δ\| ≥ 30 MB AND ≥ 20% of total DIRTY+SWAPPED Δ | file heap-retention follow-up |
| Any IOSurface / IOAccelerator bucket: \|Δ\| ≥ 30 MB AND ≥ 20% of total DIRTY+SWAPPED Δ | file renderer follow-up |
| Multiple actionable buckets meet thresholds | file one follow-up per family |
| No bucket meets thresholds AND unattributed ≤ 15% AND phys Δ ≥ 30 MB | accept-as-floor, broad-spectrum warming |
| Warm-B vs Warm-A delta is the same shape as Warm-A vs cold (no incremental app-chrome cost) | doc note: app chrome did not add over terminal-only |
| Warm-A is roughly equal to Warm-B | doc note: terminal/scrollback dominates; app chrome cost is in the noise |
| Idle T+3 > Warm-B by more than tolerance | warm baseline not stable; file creep follow-up |
