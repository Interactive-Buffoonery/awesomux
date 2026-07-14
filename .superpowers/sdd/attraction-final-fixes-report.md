# Attraction final fixes

## Result

- `SidebarEdgeTrackingView` retains the last valid pointer in window coordinates. `SidebarSplitController.viewDidLayout()` republishes it through the existing production callback only when the one-third tracking frame changes, and exits when the stationary pointer falls outside the resized region.
- Invalid pointer samples now reset tracker state and publish `.dormant` with zero cue intensity.
- `AppTitlebarView` uses `TimelineView(.animation)` only while `SidebarOverlayAnimator` reports an active compositor animation. Stable overlay geometry renders directly, while overlay relayouts preserve active sampling until completion.

## Verification

- `script/format.sh` on all changed Swift files
- `git diff --check`
- `./script/swift-test.sh --filter 'Sidebar(PresentationModel|SplitController|PresentationLayout|OverlayHostController)Tests'`
- Result: 104 tests in 5 suites passed

## Notes

- No new timer, display link, dependency, or geometry translation path was added.
- Existing pass-through hit testing, the single presentation-translation sample, and split/detail geometry isolation remain intact.
