# Overlay Task 4 Report

## Result

Routed transient proximity presentation exclusively through the overlay host and explicit visibility through atomic controller-owned persistent handoffs. The controller now owns edge-tracking order, divider geometry, responder/accessibility handling, overlay cleanup, and publication of the authoritative titlebar width. `updateNSViewController` only refreshes callbacks, verifies presentation-state identity, and updates hosting roots.

## RED evidence

- The initial routing test failed to compile because `SidebarPresentationRouting`, the three proxy closures, `SidebarHostPresentationState`, and `setPersistentSidebarVisible` did not exist.
- The overlay-width regression test then failed with `liveWidths == []` instead of `[60]`, proving hidden overlay rail/full selection was not updating the selected live width.
- Review rejected the first implementation because update-time edge tracking still mutated controller state, callback suppression ended before layout settlement, persistent hide was not a symmetric recorded transaction, and titlebar phase/rollback coverage was incomplete.

## Corrected implementation evidence

- Overlay to persistent performs the required no-actions trace, one real divider intent, layout settlement, transform/container cleanup, responder restoration, transaction end, then exactly one live-width and one host-presentation publication.
- Persistent to hidden performs the symmetric no-actions trace on both physical sides: generation cancellation, responder and accessibility capture, focus handoff, stable split ownership, one collapse intent, layout settlement, identity/overlay/AX cleanup, transaction end, host publication, then edge-tracking enablement.
- `isPerformingHostHandoff` remains active across explicit layout settlement, suppressing both `splitViewDidResizeSubviews` and `applyPosition` publication paths. Tests record callback action counts and prove neither callback fires inside either transaction.
- Invalid handoff prerequisites fail closed to hidden split-container ownership with identity transform, hidden overlay, authoritative zero width, and edge tracking enabled.
- Controller-authoritative presentation tests cover overlay reveal, presented state, hiding state, a reversed winning reveal, stale hide completion, winning hide completion, side invalidation, persistent show, and left/right parity.
- Hidden overlay rail/full selection updates only overlay geometry and live selection; it does not issue a divider intent or resize detail content.

## GREEN evidence

- `./script/swift-test.sh --filter SidebarHoverIntegrationTests`: 4 tests passed.
- `./script/swift-test.sh --filter SidebarOverlayHostControllerTests`: 19 tests passed.
- `./script/swift-test.sh --filter SidebarSplitVisibilityOwnershipTests`: 1 test passed.
- `./script/swift-test.sh --filter SidebarPresentationLayoutTests`: 4 tests passed.
- `./script/swift-test.sh --filter SidebarHoverArchitectureTests`: 2 tests passed.
- Targeted `script/format.sh`: clean.
- `git diff --check`: clean.

## Self-review

- Removed `terminalMinimumWidth`, sidebar position, edge tracking, and all visibility enactment from `updateNSViewController`; only callbacks, identity verification, and root-view refresh remain.
- Added real divider-intent counting rather than relying only on a semantic action trace.
- Verified settled persistent and hidden commands are zero-action idempotent.
- Verified stale overlay completions cannot overwrite the controller-authoritative titlebar state.
- Verified fail-closed behavior for missing handoff layers in both directions.
