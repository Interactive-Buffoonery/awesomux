# Main-thread churn baseline — 2026-07-14

Baseline captured **before** the churn-reduction work landed (`PaneUpdateOutcome`
publish gating, the visible-text detector run-gate, and `SidebarSessionTile:
Equatable`). Recorded here because the fix shipped but the number it was measured
against did not, leaving no way to verify the improvement later.

## Conditions

- 90s live `sample` during agent streaming
- roughly 6 workspaces open

## Observed

| Metric | Value |
|---|---|
| Main thread idle | **39%** (i.e. 61% busy) |
| SwiftUI relayout + accessibility recompute of sidebar rows | **~24%** of all samples |
| — approx. sample count | ~1000 `AccessibilityViewGraph.needsUpdate` / `AccessibilityProperties.merge` |
| Visible-text agent detector ICU string scans | **~5%** |

## Re-measure with

```sh
sample awesoMux 30 2 -file /tmp/after.txt && \
  grep -cE "AccessibilityViewGraph.needsUpdate|AccessibilityProperties.merge" /tmp/after.txt
```

## Caveat

`sample` counts blocked threads as samples, so read the call tree rather than
trusting a raw total. Compare like-for-like: same workspace count, same streaming
workload, same display-awake state.
