# INT-397 bucket diff — defaults run (20260514-195504)

Source captures:
- Cold:   `vmmap-summary-surface1-cold-defaults-20260514-195504.txt`
- Warm-A: `vmmap-summary-surface1-warmA-defaults-20260514-195504.txt`
- Warm-B: `vmmap-summary-surface1-warmB-defaults-20260514-195504.txt`

Accounting note: bucket totals use **DIRTY + SWAPPED** from the vmmap
summary table. DIRTY counts private pages currently resident; SWAPPED
counts private pages that macOS has compressed to swap. Both still
count toward `phys_footprint_bytes` (via TASK_VM_INFO's
`compressed` field). Using DIRTY alone would miss compressed-private
pages and falsely report "released" memory when macOS has actually
compressed it (the user-config run exhibits exactly this — see the
Warm-B vs Warm-A diff in the user-config bucket-diff file). RESIDENT
(the originally locked column) overcounts because it includes shared
library pages that `phys_footprint` excludes. Decision rule applied
to Warm-B vs cold.

## Warm-A (terminal-only) vs cold

- `phys_footprint_bytes` Δ: +26.13 MiB (baseline 219.50 → comparison 245.63)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): +65.18 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): -39.06 MiB (-149.5% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `owned unmapped (graphics)` | 1.86 | 41.90 | +40.04 | +61.4% |
| 2 | `IOAccelerator (graphics)` | 21.20 | 40.70 | +19.50 | +29.9% |
| 3 | `VM_ALLOCATE` | 17.70 | 20.70 | +3.00 | +4.6% |
| 4 | `Memory Tag 240` | 2.28 | 4.55 | +2.27 | +3.5% |
| 5 | `page table in kernel` | 0.75 | 1.00 | +0.25 | +0.4% |
| 6 | `__DATA` | 8.42 | 8.50 | +0.08 | +0.1% |
| 7 | `__DATA_DIRTY` | 2.26 | 2.32 | +0.06 | +0.1% |
| 8 | `Stack` | 1.19 | 1.14 | -0.05 | -0.1% |
| 9 | `unused but dirty shlib __DATA` | 0.36 | 0.38 | +0.02 | +0.0% |
| 10 | `MALLOC metadata` | 1.02 | 1.03 | +0.02 | +0.0% |
| — | `(rest, n=30)` | 75.00 | 75.00 | +0.00 | +0.0% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | +65.18 | 100% |

## Warm-B (full app-chrome) vs Warm-A

- `phys_footprint_bytes` Δ: +10.16 MiB (baseline 245.63 → comparison 255.78)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): -57.46 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): +67.62 MiB (+665.8% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `owned unmapped (graphics)` | 41.90 | 2.31 | -39.59 | +68.9% |
| 2 | `IOAccelerator (graphics)` | 40.70 | 22.20 | -18.50 | +32.2% |
| 3 | `VM_ALLOCATE` | 20.70 | 18.20 | -2.50 | +4.4% |
| 4 | `Memory Tag 240` | 4.55 | 2.28 | -2.27 | +3.9% |
| 5 | `shared memory` | 0.34 | 1.38 | +1.03 | -1.8% |
| 6 | `CoreAnimation` | 0.84 | 1.75 | +0.91 | -1.6% |
| 7 | `owned unmapped` | 6.00 | 6.73 | +0.73 | -1.3% |
| 8 | `AttributeGraph Data (old mapping)` | 0.00 | 0.61 | +0.61 | -1.1% |
| 9 | `IOSurface` | 64.80 | 65.30 | +0.50 | -0.9% |
| 10 | `MALLOC` | 0.72 | 1.22 | +0.50 | -0.9% |
| — | `(rest, n=33)` | 16.66 | 17.77 | +1.11 | -1.9% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | -57.46 | 100% |

## Warm-B (full app-chrome) vs cold

- `phys_footprint_bytes` Δ: +36.28 MiB (baseline 219.50 → comparison 255.78)
- Σ vmmap-DIRTY+SWAPPED Δ (private+compressed): +7.72 MiB
- Unattributed (phys Δ − Σ DIRTY+SWAPPED Δ): +28.56 MiB (+78.7% of phys Δ)

| # | Region | Baseline (MiB) | Comparison (MiB) | Δ (MiB) | Δ % of Σ DIRTY+SWAPPED Δ |
|---|--------|---------------:|-----------------:|--------:|--------------------:|
| 1 | `shared memory` | 0.34 | 1.38 | +1.03 | +13.4% |
| 2 | `IOAccelerator (graphics)` | 21.20 | 22.20 | +1.00 | +13.0% |
| 3 | `CoreAnimation` | 0.86 | 1.75 | +0.89 | +11.5% |
| 4 | `owned unmapped` | 6.00 | 6.73 | +0.73 | +9.5% |
| 5 | `AttributeGraph Data (old mapping)` | 0.00 | 0.61 | +0.61 | +7.9% |
| 6 | `MALLOC` | 0.72 | 1.22 | +0.50 | +6.5% |
| 7 | `VM_ALLOCATE` | 17.70 | 18.20 | +0.50 | +6.5% |
| 8 | `IOSurface` | 64.80 | 65.30 | +0.50 | +6.5% |
| 9 | `owned unmapped (graphics)` | 1.86 | 2.31 | +0.45 | +5.9% |
| 10 | `__DATA` | 8.42 | 8.82 | +0.40 | +5.2% |
| — | `(rest, n=33)` | 10.13 | 11.23 | +1.10 | +14.2% |
| Σ | **TOTAL DIRTY+SWAPPED** | — | — | +7.72 | 100% |

## Defaults-run note

SWAPPED is zero across all three captures in this run — there was no
memory pressure event during the defaults capture, so DIRTY+SWAPPED
totals are identical to DIRTY alone. The Warm-B vs Warm-A diff shows
the GPU buckets genuinely released (DIRTY dropped \~57 MiB,
SWAPPED stayed at zero throughout). Compare to the user-config run
where Warm-B's surface-close path compressed the same buckets to
swap instead of releasing them.
