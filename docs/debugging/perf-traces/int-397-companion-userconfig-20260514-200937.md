---
captured_at: 2026-05-14T20:09Z (-0400) … 21:55Z idle T+3
operator: ed
hardware: Mac17,3
macos_build: 25F71  # macOS 26.5
free_ram_at_start: not_recorded
build_commit: 6ae8b52813bf192d6ba1bd51ba593df7a6d7f7fa
ghostty_submodule_sha: 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
launch_mode: dist
bundle_path: dist/awesoMux.app (worktree)
ghostty_user_config_present_at_start: true (symlink ~/.config/ghostty/config → dotfiles)
ghostty_user_config_path_moved: not_moved  # left in place for this run
ghostty_user_config_present_after_move: true
effective_scrollback_limit_bytes: 5000000  # observed via ghostty-config-env log: user_xdg_config_exists=true, but no scrollback override in user config
pii_scrub_performed: true
---

## Captures (user-config run)

| Stage | File | phys_footprint_bytes (perf-sample) | vmmap Physical footprint | Notes |
|---|---|---:|---:|---|
| Cold | `vmmap-summary-surface1-cold-userconfig-20260514-200937.txt` | 230,278,296 | 219.6 M | 3 samples within ±0.014% of median |
| Warm-A (terminal-only) | `vmmap-summary-surface1-warmA-userconfig-20260514-200937.txt` | 257,213,880 | 245.3 M | ~10 min idle plateau at 257.18-257.25 MB across 15+ samples |
| Warm-B (full app-chrome) | `vmmap-summary-surface1-warmB-userconfig-20260514-200937.txt` | 282,871,296 | 269.8 M | 3 samples bit-identical at 282,871,296 |
| Idle T+3 | (no vmmap) | 282,887,680 | — | +16 KB vs Warm-B; no creep |

Vmmap "Physical footprint (peak)" — Warm-A: 272.6 M, Warm-B: 391.5 M.

## Warm workload steps actually taken

Same as defaults run. See `int-397-companion-defaults-20260514-195504.md`.

Two differences worth noting:
- This run used the operator's actual Ghostty config (`theme = Catppuccin Mocha`, `font-family = Hack Nerd Font Mono`, `font-size = 16`, `window-padding-x = 10`, plus keybind/copy-on-select). The config does NOT override `scrollback-limit`, so the effective limit is awesoMux's default (5 MB).
- During the long idle between Warm-A and Warm-B (~75 min, the operator stepped away during an API outage), `phys_footprint_bytes` drifted *below* cold to 206 MB before snapping back to ~257 MB on the next sample. This is consistent with macOS compressing or releasing private dirty pages when an app is truly idle. The Warm-A vmmap was captured after the snap-back at 245.3 MB / phys 257 MB, so the capture reflects the active terminal-only warm state, not the dormant state.

## Steady-state observations

Cold:
- 20:09:49 phys=230,294,680
- 20:10:19 phys=230,294,680
- 20:10:50 phys=230,261,912
- 20:11:20 phys=230,278,296  ← captured

Warm-A (post-fill plateau, sampled at multiple points):
- 20:24:33 phys=257,181,112
- 20:25:04 phys=257,181,112
- 20:25:34 phys=257,197,496  ← steady-state confirmed
- … plateau held 21:32 — 21:47 around 257.2 MB with brief dormancy excursion to ~206 MB

Warm-B:
- 21:51:26 phys=282,871,296
- 21:51:57 phys=282,871,296
- 21:52:27 phys=282,871,296  ← captured (3 bit-identical samples)

Idle T+3:
- 21:55:29 phys=282,887,680  ← +16 KB vs Warm-B, well within tolerance. No creep.

## Decision rule fired

Δ_total (phys, warm-B − cold) = +50.16 MiB. Σ vmmap-DIRTY+SWAPPED Δ = +28.96 MiB. Unattributed =
+21.20 MiB (+42.3% of phys Δ) — above 15% threshold.

**Rule fired:** same branch as defaults — "Unattributed > 15% of phys Δ → refuse single-bucket
dominance; file follow-up to instrument accounting." The dominant bucket in cold→warm-B is
`IOAccelerator (graphics)` at +19.70 MiB (68.0% of Σ DIRTY+SWAPPED Δ), but it's below the 30 MiB
absolute threshold the rule names as "actionable." No MALLOC-family bucket > 30 MiB.

**Cross-run comparison:** user-config warm-B is 14 MiB higher than defaults warm-B (282.87 vs
268.21 MB). The extra cost is mostly in the IOAccelerator graphics bucket — user-config's surface-
close path compressed the scrollback-fill GPU buffers to swap rather than releasing them. See the
`IOAccelerator (graphics)` row table in `int-397-bucket-diff-userconfig-20260514-200937.md` for the
DIRTY-vs-SWAPPED movement.

Cross-run finding: scrollback fill grows `IOAccelerator (graphics)` (and adjacent graphics buckets)
by ~20 MiB in DIRTY+SWAPPED during Warm-A in both runs. Warm-B's add+close-workspace surface-close
path **releases** that memory in the defaults run (DIRTY drops, SWAPPED stays at zero) but
**compresses it to swap** in the user-config run (DIRTY drops, SWAPPED rises by the same amount).
Either way, the primary surface's GPU buffers do not auto-compact after a scrollback fill — they
respond only to an unrelated surface-close. The release-vs-compress branch depends on macOS's
runtime memory-pressure decisions, not on awesoMux behavior.
