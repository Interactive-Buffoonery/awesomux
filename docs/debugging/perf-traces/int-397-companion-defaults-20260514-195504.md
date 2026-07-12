---
captured_at: 2026-05-14T19:55Z (-0400)
operator: ed
hardware: Mac17,3
macos_build: 25F71  # macOS 26.5
free_ram_at_start: not_recorded
build_commit: 6ae8b52813bf192d6ba1bd51ba593df7a6d7f7fa
ghostty_submodule_sha: 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
launch_mode: dist
bundle_path: dist/awesoMux.app (worktree)
ghostty_user_config_present_at_start: true (symlink ~/.config/ghostty/config → dotfiles)
ghostty_user_config_path_moved: ~/.config/ghostty/config → ~/.config/ghostty/config.int397-bak
ghostty_user_config_present_after_move: false
effective_scrollback_limit_bytes: 5000000  # observed: ghostty-config-env log line confirmed defaults-only (user_xdg_config_exists=false during this run)
pii_scrub_performed: true  # sed replaced /Users/$USER/ and hostname; no leaks remain. vmmap also auto-redacts Process Path → /Users/USER/*
---

## Captures (defaults run)

| Stage | File | phys_footprint_bytes (perf-sample) | vmmap Physical footprint | Spread |
|---|---|---:|---:|---:|
| Cold | `vmmap-summary-surface1-cold-defaults-20260514-195504.txt` | 230,163,560 | 219.5 M | 3 samples within ±0.025% of median |
| Warm-A (terminal-only) | `vmmap-summary-surface1-warmA-defaults-20260514-195504.txt` | 257,557,992 | 245.7 M | 3 samples within ±0.64% of median |
| Warm-B (full app-chrome) | `vmmap-summary-surface1-warmB-defaults-20260514-195504.txt` | 268,207,640 | 255.8 M | 3 samples within ±0.024% of median |
| Idle T+3 (no input) | (no vmmap, perf-sample only) | 268,256,792 | — | bit-identical to Warm-B across 4 samples |

Vmmap "Physical footprint (peak)" at Warm-B: 418.2 M (during the brief surfaces=2 transition while adding+closing the second workspace).

## Warm workload steps actually taken

Warm-A:
1. In awesoMux pane, ran the deterministic scrollback-fill: a 75 000-iteration printf loop emitting 80-byte lines (~6 MB total, slightly above the 5 MB `scrollback-limit`).
2. Operator observed a brief beachball during the fill — separate concern, filed as follow-up. Phys_footprint dropped *below* cold after the fill (211 MB at one point) before rising back as the surface stabilized at ~258 MB.
3. Idle until 3 consecutive perf-sample lines within ±1% of median.

Warm-B (after Warm-A):
1. Opened Settings, scrolled each section once, closed.
2. Opened the font picker from Settings, scrolled once, closed. Closed Settings.
3. Invoked the floating panel, idled ~15 s, closed.
4. Added a second workspace from the sidebar, ran `ls -laR /usr/bin > /dev/null`, closed the workspace back to one.
5. Idle until steady-state.

Note: cold-launch already had 3 sidebar entries (sessions) but only 1 active surface. We cleared
`~/Library/Caches/com.interactivebuffoonery.awesomux` and the saved-state bundle, but session
restore (sidebar entries) lives in `Application Support`, not Caches. Surfaces=1 was confirmed in
every perf-sample line that backed a vmmap capture — sidebar count does not affect the warm-baseline
comparison since both the cold and warm captures use the same sidebar state.

## Steady-state observation log

Cold (target ±1%):
- 19:55:46 phys=230,179,944
- 19:56:16 phys=230,130,792
- 19:56:47 phys=230,163,560  ← captured

Warm-A (target ±1%):
- 19:59:57 phys=259,212,776
- 20:00:27 phys=257,541,608
- 20:00:58 phys=257,607,144  ← median used for steady-state
- 20:01:29 phys=257,639,912  ← captured shortly after

Warm-B (target ±1%):
- 20:04:00 phys=268,174,872
- 20:04:31 phys=268,207,640
- 20:05:02 phys=268,240,408  ← captured (then 268,256,792 held for 4 more samples without change)

Idle T+3 (after Warm-B capture):
- 20:08:05 phys=268,256,792  ← T+3 reading, bit-identical to Warm-B. No creep.

## Decision rule fired

Δ_total (phys, warm-B − cold) = +36.28 MiB. Σ vmmap-DIRTY+SWAPPED Δ = +7.72 MiB. Unattributed =
+28.56 MiB (+78.7% of phys Δ) — above the 15% materiality threshold.

**Rule fired:** "Unattributed > 15% of phys Δ → refuse single-bucket dominance; file follow-up to
instrument accounting." No MALLOC-family bucket > 30 MB. No IOSurface/IOAccelerator bucket > 30 MB
in the cold→warm-B comparison.

In this run, SWAPPED is zero across all three captures, so DIRTY+SWAPPED equals DIRTY. The
Warm-B vs Warm-A diff shows the GPU buckets (`owned unmapped (graphics)`,
`IOAccelerator (graphics)`) genuinely **released** — DIRTY dropped by ~57 MiB while SWAPPED stayed
at zero throughout. Contrast with the user-config run, where the same surface-close path compressed
to swap rather than releasing. See `int-397-bucket-diff-defaults-20260514-195504.md`.
