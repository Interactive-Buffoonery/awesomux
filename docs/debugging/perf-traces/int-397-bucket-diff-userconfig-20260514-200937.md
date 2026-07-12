# INT-397 bucket diff — user-config run (20260514-200937)

Source captures:
- Cold:   `vmmap-summary-surface1-cold-userconfig-20260514-200937.txt`
- Warm-A: `vmmap-summary-surface1-warmA-userconfig-20260514-200937.txt`
- Warm-B: `vmmap-summary-surface1-warmB-userconfig-20260514-200937.txt`

Accounting note: bucket totals use **DIRTY + SWAPPED** from the vmmap
summary table — see the defaults-run bucket-diff file for the
rationale. The user-config run is the one that demonstrates why
DIRTY alone is insufficient: the `IOAccelerator (graphics)` row
moved 13.3 MiB from DIRTY to SWAPPED between Warm-A and Warm-B
without releasing the underlying memory. A DIRTY-only diff would
falsely show a 13.3 MiB "release".

## Warm-A (terminal-only) vs cold

- `phys_footprint_bytes` Δ: +25.67 MiB (baseline 219.61 → comparison 245.28)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): +25.37 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): +0.30 MiB (+1.2% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `IOAccelerator (graphics)` | 21.20 | 40.90 | +19.70 | +77.6% |
| 2 | `VM_ALLOCATE` | 17.80 | 20.80 | +3.00 | +11.8% |
| 3 | `Memory Tag 240` | 2.28 | 4.55 | +2.27 | +8.9% |
| 4 | `page table in kernel` | 0.78 | 0.97 | +0.19 | +0.7% |
| 5 | `__DATA` | 8.40 | 8.50 | +0.09 | +0.4% |
| 6 | `__DATA_DIRTY` | 2.23 | 2.32 | +0.09 | +0.4% |
| 7 | `unused but dirty shlib __DATA` | 0.36 | 0.38 | +0.02 | +0.1% |
| 8 | `Stack` | 1.17 | 1.19 | +0.02 | +0.1% |
| 9 | `CoreAnimation` | 0.83 | 0.81 | -0.02 | -0.1% |
| 10 | `__AUTH` | 0.53 | 0.55 | +0.02 | +0.1% |
| — | `(rest, n=30)` | 76.42 | 76.42 | +0.00 | +0.0% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | +25.37 | 100% |

## Warm-B (full app-chrome) vs Warm-A

- `phys_footprint_bytes` Δ: +24.48 MiB (baseline 245.28 → comparison 269.77)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): +3.59 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): +20.90 MiB (+85.3% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `VM_ALLOCATE` | 20.80 | 18.89 | -1.91 | -53.3% |
| 2 | `shared memory` | 0.34 | 1.38 | +1.03 | +28.7% |
| 3 | `CoreAnimation` | 0.81 | 1.69 | +0.88 | +24.4% |
| 4 | `AttributeGraph Data (old mapping)` | 0.00 | 0.66 | +0.66 | +18.3% |
| 5 | `IOSurface` | 64.80 | 65.30 | +0.50 | +13.9% |
| 6 | `owned unmapped` | 6.00 | 6.47 | +0.47 | +13.1% |
| 7 | `owned unmapped (graphics)` | 1.86 | 2.31 | +0.45 | +12.6% |
| 8 | `MALLOC` | 0.67 | 1.12 | +0.45 | +12.6% |
| 9 | `__DATA` | 8.50 | 8.82 | +0.32 | +9.0% |
| 10 | `CoreUI image data` | 0.39 | 0.61 | +0.22 | +6.1% |
| — | `(rest, n=33)` | 53.20 | 53.72 | +0.52 | +14.5% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | +3.59 | 100% |

## Warm-B (full app-chrome) vs cold

- `phys_footprint_bytes` Δ: +50.16 MiB (baseline 219.61 → comparison 269.77)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): +28.96 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): +21.20 MiB (+42.3% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `IOAccelerator (graphics)` | 21.20 | 40.90 | +19.70 | +68.0% |
| 2 | `Memory Tag 240` | 2.28 | 4.55 | +2.27 | +7.8% |
| 3 | `VM_ALLOCATE` | 17.80 | 18.89 | +1.09 | +3.8% |
| 4 | `shared memory` | 0.34 | 1.38 | +1.03 | +3.6% |
| 5 | `CoreAnimation` | 0.83 | 1.69 | +0.86 | +3.0% |
| 6 | `AttributeGraph Data (old mapping)` | 0.00 | 0.66 | +0.66 | +2.3% |
| 7 | `IOSurface` | 64.80 | 65.30 | +0.50 | +1.7% |
| 8 | `owned unmapped` | 6.00 | 6.47 | +0.47 | +1.6% |
| 9 | `MALLOC` | 0.67 | 1.12 | +0.45 | +1.6% |
| 10 | `owned unmapped (graphics)` | 1.86 | 2.31 | +0.45 | +1.6% |
| — | `(rest, n=33)` | 16.22 | 17.71 | +1.48 | +5.1% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | +28.96 | 100% |

## User-config-run notes

1. `IOAccelerator (graphics)` row across the three captures (numeric
   columns from `vmmap -summary`):

   | Capture | VIRTUAL | RESIDENT | DIRTY | SWAPPED | DIRTY+SWAPPED |
   |---|---:|---:|---:|---:|---:|
   | Cold   | 21.2 M | 21.2 M | 21.2 M | 0 K    | 21.2 M |
   | Warm-A | 43.2 M | 40.9 M | 40.9 M | 0 K    | 40.9 M |
   | Warm-B | 43.3 M | 40.9 M | 27.6 M | 13.3 M | 40.9 M |

   Between Warm-A and Warm-B, 13.3 MiB moved from DIRTY to SWAPPED.
   The total private+compressed footprint of this bucket is
   unchanged at 40.9 MiB. A DIRTY-only diff would attribute 13.3 MiB
   to release; the truth is compression, and the data is still on
   the process's private side.

2. Warm-B vs cold dominant bucket is `IOAccelerator (graphics)` at
   +19.70 MiB (68.0% of Σ DIRTY+SWAPPED Δ). This is below the 30 MiB
   absolute threshold the decision rule names, so the rule does not
   classify it as actionable — but it's a clear directional finding.

3. Unattributed (Warm-B vs cold) is +21.20 MiB (+42.3% of phys Δ),
   above the 15% materiality threshold. Per the decision rule:
   refuse single-bucket dominance; file follow-up to instrument
   accounting.
