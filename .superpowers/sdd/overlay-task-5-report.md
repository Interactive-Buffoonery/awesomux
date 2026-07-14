# Overlay Task 5 Report

## Result

Preserved the one live sidebar host across transient overlay and persistent split presentation while making pointer, keyboard, accessibility, and attributed-menu interaction authoritative for overlay retention. Focus Sidebar now settles the persistent host before delivering its focus request. Lifecycle teardown is idempotent across tracker loss, window detachment, both disappearance callbacks, and controller destruction.

## RED evidence

- Model tests initially failed to compile because `sidebarInteractionChanged(_:)` did not exist.
- Monitor tests initially failed to compile because `SidebarInteractionMonitor` did not exist.
- The first live accessibility query crashed because the imported AppKit API was mistakenly called as a class method; the regression run caught the runtime selector failure and the implementation now uses the instance property.
- The two-window regression failed with `[true, false]` instead of `[true]`, proving an unrelated panel resignation incorrectly cleared main-window sidebar retention. Window notifications are now filtered to the sidebar root's current window.
- The edge exit test initially crashed because AppKit rejects synthetic `.mouseExited` events from `mouseEvent`; the test now invokes the exit handler with a valid mouse event while still proving callback singularity.
- Specialist review rejected the first partial implementation for missing final teardown, window attach/detach observation, AX identity preservation, observer/deallocation proof, and the integrated focus/menu/accessibility matrix. Those findings were treated as blockers.

## Corrected implementation evidence

- `SidebarPresentationModel` owns one aggregated interaction bit. Active keyboard/AX/menu interaction cancels pending grace, keeps reveal authoritative through tracker/sidebar overlap, and schedules one fresh grace only after interaction clears.
- `SidebarInteractionMonitor` observes only the tracked window's updates/resignation plus menu begin/end, bounds AX ancestry traversal to 32 parents, attributes menus using sidebar pointer/focus state, removes all four observers on detach, and publishes `false` once only when previously active.
- The controller root reports window attachment and detachment. Tracker loss, window detach, `viewWillDisappear`, `viewDidDisappear`, and `deinit` all converge on idempotent settlement or its destruction backstop.
- Temporary settlement cancels animator generations, removes the compositor animation, detaches interaction observation, restores stable hidden or persistent ownership, clears transforms, hides overlay chrome, removes detached content from AX exposure, and keeps authoritative semantic host state. Reattachment restores persistent AX exposure and one monitor. Final destruction additionally clears outward callbacks that could retain external models.
- Reattachment installs one fresh four-observer monitor; repeated appearance does not duplicate it.
- Passive overlay reveal never changes first responder. Direct sidebar focus and attributed menu tracking retain the overlay until both clear.
- Overlay AX descendants remain hidden while offscreen/partial, become visible only after full presentation, stay visible when a hide is rejected for active AX focus, and become hidden synchronously before accepted hide movement.
- Persistent handoff captures the live focused AX descendant and sidebar first responder before reparent, verifies the same descendant still belongs to the same live sidebar host after reparent, restores the responder, and only then publishes persistent state.
- Focus Sidebar serializes `showPersistently()`, synchronous `setPersistentVisible?(true)`, then `deliveredSidebarFocusRequestID`; `SidebarView` never receives the incoming request ID directly.
- Collapsed-rail tile coordinates preserve vertical offset and inward-edge anchoring across split-to-overlay reparent on both left and right sides.

## GREEN evidence

- `./script/swift-test.sh --filter SidebarPresentationModelTests`: 21 tests passed.
- `./script/swift-test.sh --filter SidebarOverlayHostControllerTests`: expanded host suite passed.
- `./script/swift-test.sh --filter SidebarEdgeTrackingViewTests`: 6 tests passed.
- `./script/swift-test.sh --filter SidebarInteractionMonitorTests`: 4 tests passed.
- `./script/swift-test.sh --filter SidebarHoverIntegrationTests`: 5 tests passed.
- `./script/swift-test.sh --filter SidebarPeekModelTests`: 10 tests passed.
- `script/format.sh --lint`: changed Swift lines conform.
- `git diff --check`: clean.

## Self-review

- Filtered both update and resign notifications to the sidebar's own window; unrelated panels cannot clear retention.
- Verified active interaction publishes exactly one false transition across repeated teardown and that inactive repeated teardown stays silent.
- Verified held animation completion is a no-op after detach.
- Verified one monitor after repeated reattach and zero observers after detach.
- Verified final destruction releases callbacks and both settled and actively interacting controllers deallocate weakly.
- Preserved the persistent-disappearance contract: a persistent sidebar remains in its semantic split container, is AX-hidden while detached, and restores AX exposure on attach; a transient overlay settles hidden.

## Final blocker closure

- Persistent handoff now validates the captured AX element immediately after moving the live host but before setting persistent state or publishing host width. A forced ancestry break restores the same host to the presented overlay, leaves persistent publication at zero, and keeps the overlay interactive.
- The end-to-end retention test wires `SidebarInteractionMonitor` directly to `SidebarPresentationModel.sidebarInteractionChanged(_:)`, drives keyboard focus, attributed menu tracking, tracker/sidebar leave, and an injected live AX-focused descendant, then proves the overlay remains presented until every interaction source clears. Only then does a fresh deterministic 220 ms grace complete and the controller returns the host to stable hidden ownership.
- The window lifecycle test removes and re-adds the controller root through `NSWindow.contentView`, exercising `SidebarSplitRootView.viewDidMoveToWindow` rather than calling controller lifecycle methods. Persistent semantic ownership survives removal, detached AX exposure and observers are removed, and re-add restores AX exposure with exactly four observers.
- Final `SidebarOverlayHostControllerTests` count after these additions: 33 tests passed.

## Late audit closure

- Irreversible final teardown is now distinct from reusable temporary detach. `SidebarSplitView.dismantleNSViewController` invokes the controller's idempotent production `finalizeOwnedLifecycle()` before SwiftUI releases ownership; it detaches interaction first, clears every outward/testing callback before checking `isViewLoaded`, and only then performs view-backed settlement when available. A never-loaded controller with callbacks that strongly capture it releases through the real representable dismantle path, while `deinit` remains a backstop.
- Temporary window/view detach continues to preserve outward callbacks. The real remove/re-add lifecycle test now proves restored interaction, edge move/exit, width, divider-commit, focus-handoff, and availability callbacks actually execute after reattachment; observer count alone is not used as proof.
