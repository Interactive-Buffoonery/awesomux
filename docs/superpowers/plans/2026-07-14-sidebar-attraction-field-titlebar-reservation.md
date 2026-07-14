# Sidebar Attraction Field and Titlebar Reservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed 80-point cue trigger with a progressively stronger sidebar-side one-third attraction field, while keeping the 40-point reveal threshold and preventing the awesoMux/workgroup titlebar lockups from overlapping during overlay motion.

**Architecture:** `SidebarPresentationModel` owns pure proximity classification and eased cue intensity. `SidebarSplitController` sizes the existing pass-through tracker to one third of root content width. `SidebarHostPresentationState` derives one live visible overlay width from the same Core Animation presentation translation already used by the sidebar and awesoMux lockup; `AppTitlebarView` samples that value once per timeline tick and uses it for both the moving lockup and ordinary workgroup-column reservation.

**Tech Stack:** Swift 6, SwiftUI Observation, AppKit tracking areas, Core Animation presentation layers, swift-testing, SwiftPM macOS 15+

## Global Constraints

- Cue field is the sidebar-side third of the full root content bounds; reveal begins at or inside 40 points.
- Cue remains a fixed 4-point strip. Only opacity and glow strength change; widening remains future tuning.
- Cue intensity is continuous, monotonic, eased, faint at the field boundary, and strongest immediately before reveal. It never pulses or loops.
- Attention glow continues to use `needsAcknowledgement || unreadNotificationCount > 0` and remains visible while persistently hidden.
- The tracker and cue remain pass-through, non-focusable, and absent from accessibility traversal.
- Sidebar body, awesoMux lockup, and workgroup title derive from one authoritative compositor translation. No duration-matched second animation is allowed.
- Hover presentation must not mutate the real split, divider intent, Ghostty bounds, or terminal backing size.
- `Command-Shift-Backslash` remains instant; Reduce Motion removes movement/interpolation without removing positional cue strength.
- Preserve left/right symmetry, rail/full selection, reversal, resize, focus, and overlay lifecycle behavior.

---

### Task 1: Attraction-field geometry and eased cue intensity

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarPresentationModel.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`

**Interfaces:**
- Consumes: `pointerMoved(x:width:position:)`, where `width` is the current tracker width (one third of root content width).
- Produces: `private(set) var cueIntensity: CGFloat`, clamped to `0...1`; `static let revealDistance: CGFloat = 40`; tracker geometry `rootWidth / 3`.
- Produces: a pure eased mapping equivalent to smoothstep, `t * t * (3 - 2 * t)`, where raw `t = (trackingWidth - distance) / (trackingWidth - revealDistance)`.

- [ ] **Step 1: Replace fixed-distance tests with attraction-field boundary tests**

Add tests that express tracker-local geometry directly:

```swift
@Test("one-third tracker classifies dormant cue and reveal boundaries")
func attractionFieldBoundaries() {
    let model = makeModel(hidden: true)

    model.pointerMoved(x: 400, width: 400, position: .left)
    #expect(model.proximityState == .cue)
    #expect(model.cueIntensity == 0)

    model.pointerMoved(x: 399, width: 400, position: .left)
    #expect(model.proximityState == .cue)
    #expect(model.cueIntensity > 0)

    model.pointerMoved(x: 40, width: 400, position: .left)
    #expect(model.proximityState == .revealed)
}
```

The exact outer boundary is cue state with zero strength; `trackingRegionExited()` produces dormant state. Mirror the same distances for `.right` with `x = 0`, `1`, and `360`. Add a resize case proving a 300-point tracker recomputes intensity rather than retaining the prior 400-point scale.

- [ ] **Step 2: Add intensity curve and reset/grace tests**

Add assertions for:

```swift
let samples: [(distance: CGFloat, expectedOrder: Int)] = [
    (399, 0), (300, 1), (200, 2), (100, 3), (41, 4),
]
let intensities = samples.map { sample -> CGFloat in
    model.pointerMoved(x: sample.distance, width: 400, position: .left)
    return model.cueIntensity
}
#expect(zip(intensities, intensities.dropFirst()).allSatisfy(<))
```

Also prove intensity resets to zero after `showPersistently()`, `positionDidChange()`, `invalidateTransientState()`, and tracker exit; and that leaving the revealed sidebar back into a cue restores the last tracker intensity after grace instead of jumping to zero or one.

- [ ] **Step 3: Run the model tests and confirm RED**

Run:

```bash
./script/swift-test.sh --filter SidebarPresentationModelTests
```

Expected: failures because `cueIntensity` and attraction-field classification do not exist.

- [ ] **Step 4: Implement model intensity with one source of truth**

In `SidebarPresentationModel`:

```swift
static let revealDistance: CGFloat = 40
private(set) var cueIntensity: CGFloat = 0
@ObservationIgnored private var trackerCueIntensity: CGFloat = 0

private static func easedCueIntensity(distance: CGFloat, trackingWidth: CGFloat) -> CGFloat {
    guard trackingWidth.isFinite,
          distance.isFinite,
          trackingWidth > revealDistance,
          distance > revealDistance,
          distance < trackingWidth
    else { return 0 }
    let raw = min(max(0, (trackingWidth - distance) / (trackingWidth - revealDistance)), 1)
    return raw * raw * (3 - 2 * raw)
}
```

Set `trackerCueIntensity` whenever tracker state becomes `.cue`; publish it only when the effective state is `.cue`. Set `cueIntensity = 0` for `.dormant`, `.revealed`, persistent show/hide, invalidation, side change, and unavailable tracking. Delayed transition back to `.cue` restores `trackerCueIntensity` in the same generation-checked completion that restores state.

- [ ] **Step 5: Size the tracker from live root bounds**

In `SidebarSplitController.viewDidLayout()` replace the fixed cue distance with:

```swift
let trackingWidth = max(0, view.bounds.width / 3)
edgeTrackingView.frame = CGRect(
    x: sidebarPosition == .left ? 0 : view.bounds.width - trackingWidth,
    y: 0,
    width: trackingWidth,
    height: view.bounds.height
)
```

Update split-controller geometry tests to prove `1200 -> 400`, then resized right-side `900 -> frame(x: 600, width: 300)`.

- [ ] **Step 6: Run focused geometry tests and confirm GREEN**

Run:

```bash
./script/swift-test.sh --filter SidebarPresentationModelTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarEdgeTrackingViewTests
```

Expected: all selected suites pass; tracker remains hit-test pass-through and accessibility-hidden.

- [ ] **Step 7: Commit the attraction model**

```bash
git add Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarSplitController.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
git commit -m "feat(sidebar): add progressive attraction field"
```

---

### Task 2: Fixed-width cue rendering with eased strength

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift`

**Interfaces:**
- Consumes: `SidebarPresentationModel.cueIntensity` from Task 1.
- Produces: `SidebarProximityCue` parameters `visible`, `intensity`, `attentionGlow`, `position`, and `reduceMotion`.
- Preserves: attention state is full-strength and independent of ordinary proximity intensity.

- [ ] **Step 1: Write cue rendering-policy tests**

Extend the cue policy with pure style values so SwiftUI appearance is testable without screenshots:

```swift
@Test("ordinary cue strength clamps and attention stays full strength")
func cueStrength() {
    #expect(SidebarAttentionCuePolicy.visualStrength(intensity: -1, attention: false) == 0)
    #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 0.42, attention: false) == 0.42)
    #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 2, attention: false) == 1)
    #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 0, attention: true) == 1)
}
```

Add an architecture assertion that `ContentView` passes `sidebarPresentation.cueIntensity` into the cue and retains `.allowsHitTesting(false)` plus `.accessibilityHidden(true)`.

- [ ] **Step 2: Run cue tests and confirm RED**

```bash
./script/swift-test.sh --filter SidebarAttentionCuePolicyTests
./script/swift-test.sh --filter SidebarHoverArchitectureTests
```

Expected: failure because `visualStrength` and the intensity parameter are absent.

- [ ] **Step 3: Implement static per-position cue strength**

Add:

```swift
static func visualStrength(intensity: CGFloat, attention: Bool) -> CGFloat {
    attention ? 1 : min(max(0, intensity), 1)
}
```

Pass `sidebarPresentation.cueIntensity` to `SidebarProximityCue`. Keep `.frame(width: 4)`. Use the resolved strength for ordinary opacity and glow, for example:

```swift
let strength = SidebarAttentionCuePolicy.visualStrength(
    intensity: intensity,
    attention: attentionGlow
)
Rectangle()
    .fill(attentionGlow ? Color.aw.status.needs : accent)
    .frame(width: 4)
    .shadow(
        color: (attentionGlow ? Color.aw.status.needs : accent).opacity(0.18 + 0.52 * strength),
        radius: 1 + 6 * strength
    )
    .opacity(visible || attentionGlow ? 0.12 + 0.88 * strength : 0)
```

Do not add a repeating animation. With Reduce Motion, render each sampled strength directly. Without Reduce Motion, only a short non-spring interpolation keyed to `strength` is permitted and must not delay state transitions.

- [ ] **Step 4: Run cue tests and confirm GREEN**

```bash
./script/swift-test.sh --filter SidebarAttentionCuePolicyTests
./script/swift-test.sh --filter SidebarHoverArchitectureTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit cue rendering**

```bash
git add Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift
git commit -m "style(sidebar): strengthen proximity cue near edge"
```

---

### Task 3: Reserve workgroup title space from the authoritative overlay transform

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift`

**Interfaces:**
- Consumes: `titlebarPresentationWidth` and `currentTitlebarTranslationX` from `SidebarHostPresentationState`.
- Produces: `func currentTitlebarVisibleWidth(position:) -> CGFloat`.
- Contract: compute visible width once per overlay timeline sample and reuse it for both content-column reservation and sidebar-lockup translation.

- [ ] **Step 1: Write live-visible-width tests for both sides and reversals**

Add cases around the presentation provider:

```swift
state.titlebarPresentationWidth = 300
state.overlayPresentationTranslation = { -300 }
#expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
state.overlayPresentationTranslation = { -180 }
#expect(state.currentTitlebarVisibleWidth(position: .left) == 120)
state.overlayPresentationTranslation = { 0 }
#expect(state.currentTitlebarVisibleWidth(position: .left) == 300)

state.overlayPresentationTranslation = { 180 }
#expect(state.currentTitlebarVisibleWidth(position: .right) == 120)
```

Also test non-finite translation and over-range values clamp safely to `0...titlebarPresentationWidth`.

- [ ] **Step 2: Run titlebar tests and confirm RED**

```bash
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarPresentationLayoutTests
```

Expected: failure because visible-width derivation is missing and overlay layout still reserves zero.

- [ ] **Step 3: Add one pure visible-width derivation**

In `SidebarHostPresentationState`:

```swift
func currentTitlebarVisibleWidth(position: AppearanceConfig.SidebarPosition) -> CGFloat {
    let width = max(0, titlebarPresentationWidth)
    guard width.isFinite else { return 0 }
    let translation = currentTitlebarTranslationX
    guard translation.isFinite else { return 0 }
    return min(max(0, width - abs(translation)), width)
}
```

The `position` parameter documents left/right intent and permits side-specific validation, but the magnitude-based result is symmetric. Do not read settled effective width in overlay mode.

- [ ] **Step 4: Make one TimelineView own both titlebar consumers**

Refactor `AppTitlebarView.body` so `.overlay` mode evaluates a single `TimelineView(.animation)` sample:

```swift
TimelineView(.animation) { _ in
    let visibleWidth = hostPresentation.currentTitlebarVisibleWidth(position: sidebarPosition)
    titlebarColumns(sidebarWidth: visibleWidth)
        .overlay(alignment: sidebarPosition == .left ? .leading : .trailing) {
            sidebarColumn(
                width: hostPresentation.titlebarPresentationWidth,
                isPhysicalLeading: sidebarPosition == .left
            )
            .offset(x: hostPresentation.currentTitlebarTranslationX)
        }
}
```

Extract the existing base `HStack` into `titlebarColumns(sidebarWidth:)`. Persistent mode calls it with `effectiveVisibleWidth`; hidden mode calls it with zero and keeps the lockup statically offscreen. This makes the workgroup column reserve the exact visible overlay width in the same sample as the moving awesoMux lockup. Do not animate the returned width separately and do not write it into `sidebarLiveWidth`.

- [ ] **Step 5: Add layout regressions for collision-free titlebar states**

Test zero, partial, and full visible width on left and right, narrow and wide titlebars, rail/full widths, and reversal. Assert workgroup origin begins after the visible left sidebar region (or ends before the visible right region) with existing gutter, and that hidden state returns to the original title position.

- [ ] **Step 6: Run titlebar tests and confirm GREEN**

```bash
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarPresentationLayoutTests
./script/swift-test.sh --filter AppTitlebarMetricsTests
```

Expected: all selected suites pass.

- [ ] **Step 7: Commit titlebar reservation**

```bash
git add Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift
git commit -m "fix(titlebar): reserve live sidebar overlay width"
```

---

### Task 4: Geometry isolation, integration verification, and dev dogfood build

**Files:**
- Modify only if a regression is exposed: `Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift`
- Modify: `docs/superpowers/plans/2026-07-14-sidebar-attraction-field-titlebar-reservation.md` (mark completed checkboxes and record evidence)

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: evidence that the final attraction/titlebar behavior does not resize Ghostty and a rebuilt exact dev bundle.

- [ ] **Step 1: Run the focused integration matrix**

```bash
./script/swift-test.sh --filter SidebarPresentationModelTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarEdgeTrackingViewTests
./script/swift-test.sh --filter SidebarAttentionCuePolicyTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarPresentationLayoutTests
./script/swift-test.sh --filter SidebarHoverIntegrationTests
./script/swift-test.sh --filter SidebarHoverGeometryIsolationTests
```

Expected: every suite passes; hover cue/reveal/titlebar samples record zero divider intents and zero detail/backing-size changes.

- [ ] **Step 2: Run targeted formatting and hygiene checks**

```bash
./script/format.sh Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift
./script/format.sh --lint
git diff --check
```

Expected: formatter changes only intentional files; lint and diff checks exit zero.

- [ ] **Step 3: Run repository verification**

```bash
./script/swift-test.sh
./script/preflight.sh
```

Expected: full suite green. If preflight again reaches the documented macOS Bash 3 `mapfile: command not found`, record it accurately as a non-zero baseline tooling failure after preceding guards; do not call preflight green.

- [ ] **Step 4: Build and reopen the exact dev bundle**

```bash
./script/build_and_run.sh --verify
plutil -p dist/awesoMux.app/Contents/Info.plist | rg 'CFBundleIdentifier|CFBundleName'
```

Expected: build/sign/launch succeeds and identifier is `com.interactivebuffoonery.awesomux.dev.58447d72fc25` with name `awesoMux (dev 58447d7)` for this worktree.

- [ ] **Step 5: Perform honest live QA**

Using a real button-up pointer gesture, verify left and right sides, faint cue on entering the sidebar-side third, smoothly increasing intensity, reveal at 40 points, rail/full overlay, titlebar non-overlap through reveal/hide/reversal, resize, Reduce Motion, terminal selection/scroll/context-click pass-through, and no terminal reflow. Computer Use cannot synthesize a pure mouse move, so leave any unobserved path explicitly manual rather than fabricating evidence.

- [ ] **Step 6: Commit verification-only changes if needed**

If Task 4 changes tests or the plan ledger:

```bash
git add Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift docs/superpowers/plans/2026-07-14-sidebar-attraction-field-titlebar-reservation.md
git commit -m "test(sidebar): verify attraction field geometry isolation"
```

Do not create an empty commit.

---

## Pre-PR gates after implementation

- Regenerate the merge-base review package at the final implementation SHA.
- Run the full user-requested multi-reviewer audit. Any code/test/config fix invalidates the gate and requires a complete rerun.
- After that audit is clean, run a separate context-free adversarial review whose worker receives only repo rules and the final merge-base diff package—no specs, rationale, prior findings, or commit history.
- Record `FINAL-CLEAN-SHA.txt` only when both gates are clean on the same SHA.
- Do not push or open a PR before both gates are clean.
