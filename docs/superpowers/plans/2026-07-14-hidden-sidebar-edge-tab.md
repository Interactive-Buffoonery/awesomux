# Hidden Sidebar Edge Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hidden-sidebar proximity glow with a solid directional edge tab while deleting the obsolete distance-intensity machinery.

**Architecture:** Keep the existing AppKit tracking region and `.dormant` / `.cue` / `.revealed` model as the only interaction state. A small pure policy selects no tab, an attention strip, or the ordinary cue tab; one SwiftUI edge overlay renders that policy and uses the existing overlay presentation fraction only to hand off visually to the full sidebar.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, swift-testing

## Global Constraints

- The attraction field remains the sidebar-side one third of content width.
- Full sidebar reveal remains at or inside 40pt and overlays Ghostty without moving it.
- The cue is a solid highlight-color full-height strip plus a vertically centered directional chevron; it does not brighten, widen, or pulse with distance.
- The cue slides inward about 10pt; Reduce Motion removes translation without changing state transitions.
- Hidden attention outside the attraction field is a static needs-attention strip with no chevron.
- The edge tab is non-clickable, non-focusable, accessibility-hidden, and excluded from hit testing.
- Left/right sidebar positions mirror the strip, animation direction, and chevron.
- Preserve the corrected tracking-area lifecycle and narrow-window overlay sizing behavior.
- Add no setting, dependency, or second sidebar presentation state.

---

### Task 1: Replace proximity intensity with the edge tab

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarPresentationModel.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift`

**Interfaces:**
- Consumes: `SidebarPresentationModel.ProximityState`, `AppearanceConfig.SidebarPosition`, `SidebarHostPresentationState.currentOverlayVisibleFraction(translation:)`, `Color.aw.focusAccent`, and `Color.aw.status.needs`.
- Produces: `SidebarEdgeTabPolicy.Style` with `.cue` and `.attention`, plus `SidebarEdgeTabPolicy.resolve(isPersistentlyHidden:proximity:hasAttention:) -> Style?`.

- [ ] **Step 1: Write failing policy and architecture tests**

Replace the strength tests in `SidebarAttentionCuePolicyTests.swift` with a table that requires cue to win during cue/reveal, attention to appear only while dormant and persistently hidden, and no tab otherwise:

```swift
@Test("edge tab style follows hidden proximity and attention")
func edgeTabStyle() {
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .cue, hasAttention: false) == .cue)
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .revealed, hasAttention: true) == .cue)
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .dormant, hasAttention: true) == .attention)
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .dormant, hasAttention: false) == nil)
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: false, proximity: .cue, hasAttention: true) == nil)
}
```

Update `SidebarHoverArchitectureTests.swift` to require `SidebarEdgeTab`, `Image(systemName: "chevron.right")`, a 10pt directional offset, `.allowsHitTesting(false)`, and `.accessibilityHidden(true)`, and to reject `SidebarProximityCue`, `cueIntensity`, `visualStrength`, and `shadow`. Retain `TimelineView` only while sampling the live overlay presentation fraction; it must not drive a glow or distance ramp. Keep the test source-based because the suite already uses that pattern to guard the native/SwiftUI presentation boundary.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
./script/swift-test.sh --filter 'SidebarAttentionCuePolicyTests|SidebarHoverArchitectureTests'
```

Expected: FAIL because `SidebarEdgeTabPolicy` and `SidebarEdgeTab` do not exist and the old intensity/glow symbols remain.

- [ ] **Step 3: Delete intensity state and update model tests**

In `SidebarPresentationModel.swift`, remove `cueIntensity`, `trackerCueIntensity`, `easedCueIntensity`, and every assignment to those properties. `pointerMoved` should only validate input, compute distance, assign `.revealed` at or inside `revealDistance`, otherwise assign `.cue`, and route through the existing leave-grace logic.

Delete intensity-only test cases and assertions from `SidebarPresentationModelTests.swift` and `SidebarHoverGeometryIsolationTests.swift`. Preserve boundary, invalid-input, event-order, leave-grace, and lifecycle assertions by checking `proximityState` only. For leave-grace tests, assert the latest tracker state returns to `.cue` rather than comparing an intensity value.

- [ ] **Step 4: Add the pure edge-tab policy**

Replace `SidebarAttentionCuePolicy` with this policy while preserving durable attention detection:

```swift
enum SidebarEdgeTabPolicy {
    enum Style: Equatable {
        case cue
        case attention
    }

    static func resolve(
        isPersistentlyHidden: Bool,
        proximity: SidebarPresentationModel.ProximityState,
        hasAttention: Bool
    ) -> Style? {
        guard isPersistentlyHidden else { return nil }
        switch proximity {
        case .cue, .revealed:
            return .cue
        case .dormant:
            return hasAttention ? .attention : nil
        }
    }

    static func hasAttention(needsAcknowledgement: Bool, unreadNotificationCount: Int) -> Bool {
        needsAcknowledgement || unreadNotificationCount > 0
    }
}
```

Update the attention scan in `ContentView` and its tests to use `SidebarEdgeTabPolicy.hasAttention`.

- [ ] **Step 5: Replace the glow view with the fixed edge tab**

In `ContentView.content(sidebarWidth:)`, resolve one style and pass it with `sidebarPosition` and `hostPresentation` to `SidebarEdgeTab`. Remove `visible`, `intensity`, and `attentionGlow` plumbing.

Implement `SidebarEdgeTab` in place of `SidebarProximityCue` using existing tokens. Its rendered geometry is a 7pt full-height edge strip plus a centered 28×52pt rounded tab for `.cue`; `.attention` renders only the 7pt strip. Use `chevron.right` for the left sidebar and `chevron.left` for the right sidebar. Align the tab to the configured edge, keep the whole overlay pass-through and accessibility-hidden, and do not add gestures.

The ordinary cue uses `Color.aw.focusAccent(accentResolver.accent, terminalBackground: Color.aw.surface.window)`; attention uses `Color.aw.status.needs`. While the full overlay animates, use `currentOverlayVisibleFraction` to reduce the tab opacity from 1 to 0 so the sidebar replaces it. Outside an overlay transition, render directly without a `TimelineView`. Animate the tab's presence with `.easeOut(duration: 0.12)` and a hidden directional offset of -10pt on the left or +10pt on the right; when `accessibilityReduceMotion` is true, use zero offset and no transition animation.

- [ ] **Step 6: Run focused verification and make it GREEN**

Run:

```bash
./script/swift-test.sh --filter 'SidebarPresentationModelTests|SidebarHoverGeometryIsolationTests|SidebarAttentionCuePolicyTests|SidebarHoverArchitectureTests|SidebarEdgeTrackingViewTests|SidebarOverlayHostControllerTests'
```

Expected: PASS with no intensity/glow symbols or behavior remaining, while tracking and narrow-overlay regressions stay green.

- [ ] **Step 7: Format only changed Swift files and run repository verification**

Run:

```bash
./script/format.sh Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift
./script/format.sh --lint
git diff --check
./script/swift-test.sh
```

Expected: formatter and diff checks exit 0; the full suite passes.

- [ ] **Step 8: Commit the implementation**

```bash
git add Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift
git commit -m "feat(sidebar): replace proximity glow with edge tab"
```

Before this code commit, run the required multi-reviewer checkpoint. Do not push or open a PR. After implementation settles, regenerate the full required pre-PR review and the separate context-free adversarial review on the same final SHA.
