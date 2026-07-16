# Sidebar Hover Overlay Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the already-landed jittery real-divider hover animation with a live interactive sidebar overlay that slides over the full-size terminal without changing split or Ghostty geometry.

**Architecture:** Keep the completed proximity model, 80-point pass-through tracker, 4-point cue, hidden width selection, and title alignment. `SidebarSplitController` owns one `SidebarView` hosting controller and reparents that same live view between a stable real-split pane container and an overlay clip container; hover uses a compositor transform only, while explicit persistent commands perform one instantaneous real-split geometry handoff.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSViewController`, `NSSplitView`, `NSHostingController`), Core Animation (`CALayer`, `CABasicAnimation`, `CAMediaTimingFunction`), Observation, swift-testing.

## Global Constraints

- macOS 15+ and SwiftPM only.
- Preserve the exact proximity boundaries: dormant above 80 points, cue at distances `<= 80` and `> 40`, reveal at distances `<= 40`.
- Preserve the completed 4-point non-hittable/non-accessible cue and pass-through edge tracker.
- Hover reveal is a live interactive overlay above detail content; it never changes the real split divider or terminal/detail frame.
- There is exactly one `SidebarView` instance and one sidebar `NSHostingController`; never render persistent and overlay copies concurrently.
- Hover reveal/hide uses a 140-millisecond compositor-driven ease-in-out slide with no spring or overshoot.
- Reduce Motion makes overlay reveal/hide immediate; the existing short cue opacity fade may remain.
- `Command-Shift-Backslash`, Focus Sidebar, side changes, restoration, and lifecycle settlement remain immediate.
- Explicit persistent show performs exactly one intentional real-split/terminal geometry resize; persistent hide performs exactly one collapse.
- `Command-Backslash` while hidden changes the remembered rail/full width without moving the real divider or resizing Ghostty; an active overlay updates its own width only.
- Overlay interaction preserves the existing sidebar controls, scrolling, contextual menus, focus, accessibility, and peek behavior.
- Passive overlay reveal never steals terminal first responder or VoiceOver focus.
- The configured left/right edge is symmetric; overlay width uses existing `SidebarWidthPolicy` clamping.
- Preserve the completed right-sidebar title lockup alignment and Markdown Files/Document centering.
- Do not add a second SwiftUI sidebar tree, snapshot sidebar, global event monitor, configurable threshold, or generalized animation framework.
- Hidden/overlay/intermediate widths never reach width persistence callbacks.
- Use targeted `script/format.sh` only on intentionally changed Swift files.
- Follow TDD: run each task's focused RED test before production edits.

## Existing Work to Keep

- `Sources/awesoMux/Views/SidebarPresentationModel.swift` and `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`: dormant/cue/revealed state, overlap arbitration, 220ms grace, generation invalidation.
- `Sources/awesoMux/Views/SidebarEdgeTrackingView.swift` and tests: local left/right tracking, `mouseEntered`, pass-through input, availability loss.
- `SidebarProximityCue`, `SidebarHiddenWidthTogglePolicy`, keyboard routing, persistence, and Appearance position settings.
- `AppTitlebarMetrics.lockupPadding`, `SidebarPresentationLayoutPolicy.titlebarLockupAlignment`, and related titlebar tests.
- Existing semantic left/right real-split math, divider drag behavior, focus handoff, and cold-launch hidden restoration.

## File Responsibility Map

- `Sources/awesoMux/Views/SidebarSplitController.swift`: stable split pane containers, single sidebar-host reparenting, persistent/overlay handoff, geometry instrumentation.
- `Sources/awesoMux/Views/SidebarOverlayAnimator.swift`: one-purpose cancellable compositor transform animator.
- `Sources/awesoMux/Views/SidebarOverlayClipView.swift`: presentation-layer-aware visible bounds and coordinate-correct hit testing.
- `Sources/awesoMux/Views/SidebarInteractionMonitor.swift`: reduces sidebar pointer, keyboard focus, accessibility focus, and contextual-menu tracking to one retention signal.
- `Sources/awesoMux/Views/SidebarSplitView.swift`: constructs the single sidebar host and wires proxy/callback updates without enacting runtime presentation during representable updates.
- `Sources/awesoMux/Views/SidebarSplitSupport.swift`: typed host/presentation commands and proxy closures.
- `Sources/awesoMux/Views/ContentView.swift`: maps persistent intent and proximity state to overlay versus real-split commands; owns no AppKit geometry.
- `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`: retained persistent split, semantic positioning, drag, resize, and cold-launch tests after removing divider-hover cases.
- `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`: one-host ownership, reparenting, overlay frames, explicit handoff, width mode, focus and interaction.
- `Tests/awesoMuxTests/SidebarOverlayAnimatorTests.swift`: transforms, cancellation, reversal, stale completion, Reduce Motion.
- `Tests/awesoMuxTests/SidebarOverlayClipViewTests.swift`: fully hidden/partial/presented hit testing and transformed coordinate routing.
- `Tests/awesoMuxTests/SidebarInteractionMonitorTests.swift`: first-responder/AX ancestry, menu lifetime, and pointer retention.
- `Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift`: zero divider mutation and zero detail/terminal backing resize during hover.
- `Tests/awesoMuxTests/SidebarSemanticPaneIdentityTests.swift`: structural and runtime proof that split semantics use `sidebarPaneContainer`, never the reparented host view.
- `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`: model-to-command routing and hidden rail/full behavior.
- `Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift`: runtime ownership structural guard updated from divider visibility to host presentation.

## Shared Interfaces

```swift
enum SidebarHostMode: Equatable {
    case hidden
    case overlay(width: CGFloat)
    case persistent(width: CGFloat)
}

enum SidebarOverlayTransition: Equatable {
    case immediate
    case hover(duration: TimeInterval)
}

@Observable
@MainActor
final class SidebarHostPresentationState {
    private(set) var mode: SidebarHostMode = .hidden
    private(set) var effectiveVisibleWidth: CGFloat = 0

    func settle(mode: SidebarHostMode, effectiveVisibleWidth: CGFloat)
}

@MainActor
final class SidebarSplitProxy {
    var setSelectedWidth: ((CGFloat) -> Void)?
    var setOverlayVisible: ((Bool, SidebarOverlayTransition, Bool) -> Void)?
    var setPersistentVisible: ((Bool) -> Void)?
    var setPosition: ((AppearanceConfig.SidebarPosition) -> Void)?
    var sidebarPointerChanged: ((Bool) -> Void)?
}

@MainActor
final class SidebarOverlayAnimator {
    typealias AnimationRunner = (
        _ layer: CALayer,
        _ animation: CABasicAnimation,
        _ key: String,
        _ completion: @escaping () -> Void
    ) -> Void

    struct Request: Equatable {
        let fromTranslationX: CGFloat
        let toTranslationX: CGFloat
        let duration: TimeInterval
    }

    init(layer: CALayer, runner: AnimationRunner? = nil)

    func setPresented(
        _ presented: Bool,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool,
        completion: @escaping (_ generation: Int) -> Void
    )
    func cancelAndSettle(presented: Bool)
}
```

Runtime ownership is strict:

```text
SidebarSplitView.makeNSViewController -> initial hidden/persistent restoration only
SidebarSplitView.updateNSViewController -> callbacks, root updates, position/tracker only
ContentView runtime intent -> SidebarSplitProxy -> SidebarSplitController only
SidebarSplitController -> sole owner of reparenting, overlay, and real split geometry
```

---

### Task 1: Remove Real-Divider Hover Animation

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift`
- Create: `Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift`

**Interfaces:**
- Removes: `SidebarWidthAnimation`, `SidebarSplitController.AnimationRunner`, `AnimationRecord`, `setSidebarVisible(_:transition:reduceMotion:)`, hover animation state/test accessors, and obsolete `SidebarSplitProxy.setVisibility`/`setHidden` closures.
- Preserves temporarily: immediate `setSidebarHidden(_:)`, `setSidebarWidth(_:)`, `setSidebarPosition(_:)`, edge tracker callbacks, split geometry helpers.
- Produces: compile-time space for `SidebarHostMode` and overlay proxy APIs in later tasks.

- [ ] **Step 1: Add a failing source-architecture regression**

```swift
@Test("hover presentation contains no divider animation API")
func noDividerHoverAnimation() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let controller = try String(
        contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitController.swift"),
        encoding: .utf8
    )
    for forbidden in [
        "SidebarWidthAnimation", "AnimationRunner", "animateSidebarVisibility",
        "isHoverAnimating", "setSidebarVisible("
    ] {
        #expect(!controller.contains(forbidden), "remove real-divider hover path: \(forbidden)")
    }
    let support = try String(
        contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitSupport.swift"),
        encoding: .utf8
    )
    #expect(!support.contains("setVisibility:"))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `./script/swift-test.sh --filter SidebarHoverArchitectureTests`

Expected: FAIL because the landed controller still contains `SidebarWidthAnimation`, `AnimationRunner`, `isHoverAnimating`, and `setSidebarVisible`.

- [ ] **Step 3: Delete the divider-hover implementation and obsolete tests**

Remove the private `SidebarWidthAnimation` type and every hover-animation field/method. Restore `setSidebarHidden(_:)` to immediate-only behavior:

```swift
func setSidebarHidden(_ hidden: Bool) {
    guard hidden != isSidebarHidden else { return }
    if hidden {
        handOffSidebarFocusIfNeeded()
        pendingWidth = sidebarPaneWidth
        recordIfExpanded(sidebarPaneWidth)
        isSidebarHidden = true
        applyHiddenPosition()
    } else {
        isSidebarHidden = false
        let width = pendingWidth ?? lastExpandedPaneWidth
        pendingWidth = nil
        applyPosition(width)
    }
}
```

Delete only tests whose subject is per-frame divider hover animation: animation records, midpoint divider widths, dead-zone bypass during hover, hover generation, and animated visibility proxy delivery. Retain all persistent hide/show, focus handoff, drag, left/right, resize clamp, width persistence, and cold-launch tests.

- [ ] **Step 4: Remove the old runtime proxy calls without replacing behavior yet**

Remove `SidebarSplitTransition`, `SidebarSplitProxy.setVisibility`, unused `SidebarSplitProxy.setHidden`, `SidebarHoverTransitionPolicy`, `SidebarRuntimeVisibilityPolicy`, and `ContentView` calls to `splitProxy.setVisibility`. Keep proximity/cue state compiling; temporary reveal will be visually absent until Tasks 2–3 deliberately restore it as overlay.

Update `SidebarSplitVisibilityOwnershipTests` to forbid `setSidebarHidden`, `setSidebarVisible`, `setVisibility`, and the future `setOverlayVisible`/`setPersistentVisible` inside `updateNSViewController`; runtime proxy calls belong outside representable updates.

- [ ] **Step 5: Format, run retained split tests, and commit**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift
./script/swift-test.sh --filter SidebarHoverArchitectureTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarSplitVisibilityOwnershipTests
git diff --check
```

Expected: all three suites pass; retained split behavior stays green; no width-animation symbol remains.

Commit: `refactor(sidebar): remove divider hover animation`

---

### Task 2: Build the Single-Host Interactive Overlay Architecture

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Create: `Sources/awesoMux/Views/SidebarOverlayClipView.swift`
- Create: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`
- Create: `Tests/awesoMuxTests/SidebarOverlayClipViewTests.swift`
- Create: `Tests/awesoMuxTests/SidebarSemanticPaneIdentityTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`

**Interfaces:**
- Produces: `SidebarHostMode`, stable `sidebarPaneContainer`, `SidebarOverlayClipView`, `overlayContentView`, `setSelectedSidebarWidth(_:)`, `setOverlayPresentedImmediately(_:)`, and internal `sidebarPaneContainerForTesting`.
- Preserves: one sidebar child controller and its SwiftUI root across all modes.
- Invariant: direct `NSSplitView` panes remain `sidebarPaneContainer` and `detailChild.view`; reparent only `sidebarChild.view`.

- [ ] **Step 1: Write failing one-host and reparenting tests**

```swift
@Test("overlay reparents the one live sidebar host while split stays hidden")
func oneHostOverlay() {
    let (controller, sidebar, detail) = makeController()
    controller.setSidebarHidden(true)
    controller.setSelectedSidebarWidth(300)

    controller.setOverlayPresentedImmediately(true)

    #expect(controller.hostModeForTesting == .overlay(width: 300))
    #expect(sidebar.view.superview === controller.overlayContentViewForTesting)
    #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
    #expect(controller.sidebarSplitPaneWidthForTesting == 0)
    #expect(detail.view.frame == controller.detailFrameBeforeOverlayForTesting)
}
```

Add mirrored right-side frame assertions: left overlay frame `x == 0`; right overlay frame `maxX == controller.view.bounds.maxX`. Assert it is above detail in root z-order and accepts hit testing only inside its visible frame.

Add a stable semantic-pane test for both positions and all host modes:

```swift
#expect(controller.splitPaneViewsForTesting.count == 2)
#expect(controller.splitPaneViewsForTesting == [controller.sidebarPaneContainerForTesting, detail.view]) // left
controller.setSidebarPosition(.right)
#expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
controller.setOverlayPresentedImmediately(true)
#expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
```

The sidebar host's parent changes; split pane identity/order/count never do.

- [ ] **Step 2: Run and verify RED**

Run: `./script/swift-test.sh --filter SidebarOverlayHostControllerTests`

Expected: compilation fails because overlay host APIs and `SidebarHostMode` do not exist.

- [ ] **Step 3: Introduce stable split and overlay containers**

Keep the root view introduced for edge tracking. Add:

```swift
private let sidebarPaneContainer = NSView()
private let overlayClipView = NSView()
private let overlayContentView = NSView()
private var hostMode: SidebarHostMode = .persistent(width: SidebarWidthPolicy.expandedWidth)
private var selectedSidebarWidth: CGFloat = SidebarWidthPolicy.expandedWidth
```

`loadView` adds `sidebarPaneContainer` and `detailChild.view` as the only split panes. Add `sidebarChild.view` inside `sidebarPaneContainer`; add `overlayClipView` above `splitView` but below `edgeTrackingView`, and add `overlayContentView` inside it. Explicitly set `overlayClipView.wantsLayer = true`, `overlayClipView.layer?.masksToBounds = true`, and `overlayContentView.wantsLayer = true`; guard the non-nil content layer before animator construction and fall back to stable hidden ownership if it is unavailable. Never construct another `NSHostingController` or call `sidebar()` twice to create distinct stateful trees.

Use frame/autoresizing exclusively. Before every reparent, deactivate/remove any constraints in the source or destination whose first/second item is `sidebarChild.view`. Set `sidebarChild.view.translatesAutoresizingMaskIntoConstraints = true`, assign destination bounds, and set `[.width, .height]`. `overlayClipView` and `overlayContentView` also use explicit frames in every `viewDidLayout`; do not mix destination constraints with autoresizing.

Centralize reparenting:

```swift
private func moveSidebarHost(to destination: NSView) {
    guard sidebarChild.view.superview !== destination else { return }
    removeDestinationConstraints(for: sidebarChild.view)
    sidebarChild.view.removeFromSuperview()
    sidebarChild.view.translatesAutoresizingMaskIntoConstraints = true
    destination.addSubview(sidebarChild.view)
    sidebarChild.view.frame = destination.bounds
    sidebarChild.view.autoresizingMask = [.width, .height]
}
```

- [ ] **Step 4: Migrate every semantic split path to the stable container**

Change all split identity/geometry references, not only construction:

- `SidebarSubviewOrder.sidebar` receives `sidebarPaneContainer`.
- `splitView.sidebarWidthProvider` returns `sidebarPaneContainer.frame.width`.
- `sidebarPaneWidth` reads `sidebarPaneContainer.frame.width`.
- `splitView(_:shouldAdjustSizeOfSubview:)` compares with `sidebarPaneContainer`.
- `setSidebarPosition` sorting uses container/detail and its direct-pane assertions use those identities.
- divider drag commit, `applyPosition`, `applyHiddenPosition`, reclamp, constraint delegates, live-width callbacks, and width persistence all measure the container.
- `setSidebarPosition` treats `sidebarPaneContainer`/detail as semantic panes; a responder beneath `sidebarChild.view` is thereby inside the persistent container. Explicit hide/overlay interaction ancestry still checks `sidebarChild.view` so reparenting does not change focus ownership.
- overlay interaction/focus/AX ancestry remains rooted at `sidebarChild.view`, not the container.

Add a source-structural test that extracts `sidebarPaneWidth`, `shouldAdjustSizeOfSubview`, `loadView`, and `setSidebarPosition` and requires `sidebarPaneContainer`; forbid `splitView.addSubview(sidebarChild.view)`, `sidebarChild.view.frame.width`, and `view !== sidebarChild.view` across the controller source.

- [ ] **Step 5: Add presentation-aware overlay hit testing**

`SidebarOverlayClipView` owns a weak `contentView` and a `presentationTranslationX` closure. Its `hitTest` converts the point into the visually transformed content coordinate:

```swift
override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point), let contentView else { return nil }
    let translation = presentationTranslationX()
    let visualFrame = contentView.frame.offsetBy(dx: translation, dy: 0)
    guard visualFrame.intersection(bounds).contains(point) else { return nil }
    let contentPoint = NSPoint(
        x: point.x - contentView.frame.minX - translation,
        y: point.y - contentView.frame.minY
    )
    return contentView.hitTest(contentPoint)
}
```

Held-animation tests set translations to fully hidden, 25%, 50%, and fully presented on left/right. Put distinct sentinel controls at the content's inner/outer edges and assert uncovered points return `nil`, covered points return the correct transformed sentinel, and mouse/scroll/contextual-event hit targets never land in invisible content.

- [ ] **Step 6: Add immediate overlay/hidden layout without animation**

```swift
func setSelectedSidebarWidth(_ width: CGFloat) {
    selectedSidebarWidth = Self.clampedWidth(width, maxWidth: maxSidebarWidth)
    pendingWidth = selectedSidebarWidth
    if case .overlay = hostMode { layoutOverlay(presented: true) }
    else if case .persistent = hostMode { setSidebarWidth(selectedSidebarWidth) }
}

func setOverlayPresentedImmediately(_ presented: Bool) {
    guard isSidebarHidden else { return }
    if presented {
        moveSidebarHost(to: overlayContentView)
        layoutOverlay(presented: true)
        hostMode = .overlay(width: selectedSidebarWidth)
    } else {
        moveSidebarHost(to: sidebarPaneContainer)
        overlayClipView.isHidden = true
        hostMode = .hidden
    }
}
```

`layoutOverlay` clamps width against current root bounds and `SidebarWidthPolicy`, frames `overlayClipView` at the physical edge, fills it with `overlayContentView`, and leaves `splitView`, divider coordinate, and detail frame untouched. Fully hidden sets the translation to exactly `+/-width`, makes hit testing return `nil`, sets `sidebarChild.view.setAccessibilityHidden(true)`, removes the compositor animation key, and reparents only after it is offscreen.

- [ ] **Step 7: Update the same host root in every mode**

`SidebarSplitView.makeNSViewController` still evaluates `sidebar()` once to create one `NSHostingController`. `updateNSViewController` assigns `host.rootView = sidebar()` on that same controller regardless of hidden, overlay, animating, or persistent mode; it never constructs an overlay host. Bind `proxy.setSelectedWidth` to `controller.setSelectedSidebarWidth`. Initial hidden restoration immediately places the host in the hidden split container; initial visible restoration uses persistent mode.

For hidden, overlay-presented, overlay-mid-animation, and persistent fixtures, record `ObjectIdentifier(controller.sidebarViewController)`, run a representable root update, and assert identity/host count/parent/mode/divider/detail frame are unchanged while the new root value is visible through that same host.

- [ ] **Step 8: Run, format, and commit host architecture**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/SidebarOverlayClipView.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarOverlayClipViewTests.swift Tests/awesoMuxTests/SidebarSemanticPaneIdentityTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarOverlayClipViewTests
./script/swift-test.sh --filter SidebarSemanticPaneIdentityTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarSplitVisibilityOwnershipTests
git diff --check
```

Expected: suites pass; a single sidebar hosting view moves between containers; split/detail geometry is identical before/after immediate overlay reveal.

Commit: `feat(sidebar): host live hover overlay`

---

### Task 3: Add the Cancellable Compositor Slide

**Files:**
- Create: `Sources/awesoMux/Views/SidebarOverlayAnimator.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Create: `Tests/awesoMuxTests/SidebarOverlayAnimatorTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`

**Interfaces:**
- Produces: `SidebarOverlayAnimator`, `SidebarOverlayTransition`, `setOverlayPresented(_:transition:reduceMotion:)`.
- Consumes: `overlayContentView.layer`, current selected width, physical sidebar position.
- Guarantee: animation changes layer translation only; frames and split position remain fixed.

- [ ] **Step 1: Write failing transform and reversal tests**

Inject a Core Animation runner seam that records requests and holds completions:

```swift
@Test("left and right reveal transform from their physical edges")
func mirroredTransforms() {
    #expect(SidebarOverlayAnimator.hiddenTranslation(width: 300, position: .left) == -300)
    #expect(SidebarOverlayAnimator.hiddenTranslation(width: 300, position: .right) == 300)
    #expect(SidebarOverlayAnimator.presentedTranslation == 0)
}

@Test("reversal starts at current presentation transform and stale completion loses")
func reversalUsesPresentationTransform() {
    animator.setPresented(true, width: 300, position: .left, transition: .hover(duration: 0.140), reduceMotion: false, completion: record)
    driver.presentationTranslationX = -120
    animator.setPresented(false, width: 300, position: .left, transition: .hover(duration: 0.140), reduceMotion: false, completion: record)
    #expect(driver.requests.last?.fromTranslationX == -120)
    firstCompletion()
    #expect(animator.requestedPresentedForTesting == false)
}
```

Add tests for equal-target idempotence, same-intent active animation not restarting, and Reduce Motion invoking no animation request.

Add pure fraction mapping tests:

```swift
#expect(SidebarOverlayAnimator.visibleFraction(translationX: -225, hiddenTranslationX: -300) == 0.25)
#expect(SidebarOverlayAnimator.translation(width: 60, position: .left, visibleFraction: 0.25) == -45)
#expect(SidebarOverlayAnimator.translation(width: 300, position: .right, visibleFraction: 0.25) == 225)
```

Cover rail→full, full→rail, and window-reclamp mapping at 0%, 25%, 50%, and 100% on both physical sides.

- [ ] **Step 2: Run and verify RED**

Run: `./script/swift-test.sh --filter SidebarOverlayAnimatorTests`

Expected: compilation fails because `SidebarOverlayAnimator` does not exist.

- [ ] **Step 3: Implement one-purpose layer animator**

Create the file with `import AppKit` and `import QuartzCore`. Use one `CALayer` and one key (`"awesomux.sidebarOverlay.translation"`). The default runner wraps `layer.add` in `CATransaction.begin()`, `CATransaction.setCompletionBlock`, and `CATransaction.commit()`; tests inject the exact `AnimationRunner` closure above to hold completion. Before a new request, sample `layer.presentation()?.transform.m41`, remove the prior animation, set the model layer's final `CATransform3DMakeTranslation(targetTranslation, 0, 0)`, and add:

```swift
let animation = CABasicAnimation(keyPath: "transform.translation.x")
animation.fromValue = currentTranslation
animation.toValue = targetTranslation
animation.duration = duration
animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
layer.add(animation, forKey: Self.animationKey)
```

Maintain `generation`, `requestedPresented`, and `activeTargetTranslation`. Completion normalizes only when its generation still wins. An equal current/target settles synchronously. `cancelAndSettle` removes the animation and sets the exact newest model transform.

For resize or selected-width changes during animation, preserve the visible fraction:

```swift
let fraction = Self.visibleFraction(
    translationX: currentPresentationTranslation,
    hiddenTranslationX: oldHiddenTranslation
)
removeActiveAnimationAndInvalidateCompletion()
reframeOverlay(to: newWidth)
setModelTranslation(Self.translation(
    width: newWidth,
    position: position,
    visibleFraction: fraction
))
restartTowardRequestedStateIfNeeded()
```

`visibleFraction` clamps to `0...1` and treats zero/non-finite width as `0`. A configured side change is an explicit lifecycle invalidation: settle hidden immediately on the old side, clear transform, then rebuild on the new side; fraction preservation applies to resize/rail-full changes and is tested independently for left and right.

- [ ] **Step 4: Integrate animator with overlay visibility**

```swift
func setOverlayPresented(
    _ presented: Bool,
    transition: SidebarOverlayTransition,
    reduceMotion: Bool
) {
    guard isSidebarHidden else { return }
    if presented { prepareSingleHostOverlay() }
    overlayAnimator.setPresented(
        presented,
        width: selectedSidebarWidth,
        position: sidebarPosition,
        transition: transition,
        reduceMotion: reduceMotion
    ) { [weak self] generation in
        self?.finishOverlayTransition(presented: presented, generation: generation)
    }
}
```

Keep `overlayClipView` at its final edge-aligned frame for the full animation; transform `overlayContentView.layer` only. `SidebarOverlayClipView.presentationTranslationX` samples the same presentation/model translation, binding input pixels to visible pixels during every partial frame. On winning reveal completion, expose sidebar descendants to accessibility. At hide start, suppress AX exposure unless active AX focus has retained/cancelled the hide; on winning hide completion, reparent the sidebar host into the zero-width split container and hide the overlay clip. On reversal, keep the host in overlay until the newest hide actually completes.

- [ ] **Step 5: Add resize and side-change cancellation tests**

Resize reclamps overlay frame/selected width using the fraction mapping above, then restarts toward the newest requested state without touching split geometry. Position change immediately cancels, hides/reparents overlay, clears the animation key/model transform, moves tracker, then allows a fresh reveal on the new side. Tests re-run presentation-aware hit testing after every reframe so an old-width invisible hit shield cannot survive.

- [ ] **Step 6: Run, format, and commit compositor animation**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarOverlayAnimator.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Tests/awesoMuxTests/SidebarOverlayAnimatorTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift
./script/swift-test.sh --filter SidebarOverlayAnimatorTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarOverlayClipViewTests
./script/swift-test.sh --filter SidebarSplitControllerTests
git diff --check
```

Expected: all suites pass; reversal begins at presentation transform; stale completions cannot hide/reveal newer state; Reduce Motion is immediate.

Commit: `feat(sidebar): animate overlay reveal transform`

---

### Task 4: Route Hidden Width and Persistent Handoff

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift`

**Interfaces:**
- Produces proxy closures: `setOverlayVisible`, `setPersistentVisible`, `setSelectedWidth` and controller-authoritative `SidebarHostPresentationState`.
- Produces controller actions: `setPersistentSidebarVisible(_:)`, `setOverlayPresented(_:transition:reduceMotion:)`.
- Consumes: completed `SidebarPresentationModel.userWantsHidden`, `proximityState`, width stores.

- [ ] **Step 1: Write failing runtime-routing tests**

```swift
@Test("proximity uses overlay while explicit show uses persistent split")
func routesPresentationKinds() {
    #expect(SidebarPresentationRouting.command(userWantsHidden: true, proximity: .revealed) == .showOverlay)
    #expect(SidebarPresentationRouting.command(userWantsHidden: true, proximity: .cue) == .hideOverlay)
    #expect(SidebarPresentationRouting.command(userWantsHidden: false, proximity: .dormant) == .showPersistent)
}

@Test("hidden rail toggle updates overlay width without persistent geometry")
func hiddenWidthMode() {
    let result = SidebarHiddenWidthTogglePolicy.resolve(currentWidth: 300, lastNonCollapsedWidth: 300, persistentlyHidden: true)
    #expect(result.targetWidth == SidebarWidthPolicy.collapsedWidth)
    #expect(!result.shouldReveal)
}
```

Controller handoff tests inject an action recorder and require this exact overlay→persistent trace:

```swift
[
    .beginNoActionsTransaction,
    .cancelOverlayGeneration,
    .captureSidebarResponder,
    .removeOverlayAnimation,
    .reparentHostToSplitContainer,
    .setPersistentState,
    .applySingleDividerIntent(selectedWidth),
    .settleLayout,
    .clearTransform,
    .hideOverlayContainer,
    .restoreSidebarResponder,
    .endNoActionsTransaction,
]
```

No observable callback may fire between those actions. Assert persistent→hidden uses one collapse intent and leaves overlay absent. Repeated settled commands record no actions.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
./script/swift-test.sh --filter SidebarHoverIntegrationTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
```

Expected: routing test fails because overlay/persistent command types and proxy closures do not exist.

- [ ] **Step 3: Implement atomic overlay/persistent handoff**

Add the pure routing type used by the RED test:

```swift
enum SidebarPresentationCommand: Equatable {
    case showOverlay
    case hideOverlay
    case showPersistent
}

enum SidebarPresentationRouting {
    static func command(
        userWantsHidden: Bool,
        proximity: SidebarPresentationModel.ProximityState
    ) -> SidebarPresentationCommand {
        guard userWantsHidden else { return .showPersistent }
        return proximity == .revealed ? .showOverlay : .hideOverlay
    }
}
```

Implement `performAtomicHostHandoff(to:)` and call it from `setPersistentSidebarVisible`. It captures the existing first responder when it is inside `sidebarChild.view`, suppresses live/commit callbacks, then uses both AppKit and Core Animation no-action scopes:

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = 0
    context.allowsImplicitAnimation = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    invalidateOverlayGeneration()
    overlayContentView.layer?.removeAnimation(forKey: SidebarOverlayAnimator.animationKey)
    moveSidebarHost(to: sidebarPaneContainer)
    isSidebarHidden = false
    hostMode = .persistent(width: selectedSidebarWidth)
    setDividerPosition(selectedSidebarWidth) // the single divider intent
    splitView.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    overlayContentView.layer?.transform = CATransform3DIdentity
    overlayClipView.isHidden = true
    restoreResponderIfStillValid(capturedResponder)
}
publishSettledHostMode()
```

The overlay clip stays unhidden until the same-host split pane is laid out; because actions are disabled and layout settles before return, no display pass sees a blank or stale transformed host. Callback publication happens only after the transaction. If destination/layer/layout is invalid, roll back to hidden split-container ownership, identity/offscreen cleanup, and no persistent visible state.

Persistent hide uses the corresponding no-actions transaction: hand off focus only for hide, reparent to split container, issue one zero divider intent, settle layout, clear transform/AX/overlay, then publish hidden. Guard idempotent calls so settled persistent/hidden commands perform zero actions. Disable edge tracking only after persistent show owns the sidebar; enable it after persistent hide settles.

- [ ] **Step 4: Wire the runtime proxy as the sole enactor**

In `makeNSViewController`:

```swift
proxy.setSelectedWidth = { [weak controller] in controller?.setSelectedSidebarWidth($0) }
proxy.setOverlayVisible = { [weak controller] visible, transition, reduceMotion in
    controller?.setOverlayPresented(visible, transition: transition, reduceMotion: reduceMotion)
}
proxy.setPersistentVisible = { [weak controller] in controller?.setPersistentSidebarVisible($0) }
```

Add `let hostPresentation: SidebarHostPresentationState` to `SidebarSplitView`; assign it once to `controller.hostPresentationState` in `makeNSViewController` and reassert the same object identity in updates. Controller calls `hostPresentationState.settle(mode:effectiveVisibleWidth:)` only after a handoff transaction or overlay transition reaches its authoritative phase. Do not infer chrome state in SwiftUI.

`updateNSViewController` contains none of those calls. Update the structural ownership test accordingly.

- [ ] **Step 5: Route `ContentView` without duplicate effects**

On proximity changes while `userWantsHidden`, sample Reduce Motion and call overlay only:

```swift
splitProxy.setOverlayVisible?(
    state == .revealed,
    .hover(duration: 0.140),
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
)
```

On `Command-Shift-Backslash` or Focus Sidebar: invalidate transient model state, then call `setPersistentVisible` once. Do not also call overlay visibility from the resulting dormant state; gate proximity handling with `userWantsHidden`. Position/lifecycle invalidation first hides overlay immediately, then changes position.

`toggleSidebarWidth()` persists the selected target through the existing width store, then calls `setSelectedWidth`. If hidden dormant, no visual geometry changes. If overlay revealed, its frame/transform updates to rail/full while detail remains unchanged. If persistent, the real divider uses existing immediate rail/full behavior.

- [ ] **Step 6: Keep titlebar semantics deliberate**

Create one `@State private var hostPresentation = SidebarHostPresentationState()` in `ContentView` and pass it into `SidebarSplitView`; controller updates it only through the post-settlement `publishSettledHostMode` callback. During reveal/hide animation it reports overlay width until winning hide completion; hidden reports `0`; persistent reports settled split width. `AppTitlebarView` derives temporary visibility/width from `hostPresentation.effectiveVisibleWidth`, never directly from proximity state.

Follow-up correction: a settled-width-only titlebar publication leaves the lockup visible until hide completion. Temporary titlebar chrome instead retains the selected overlay width offscreen and samples `SidebarOverlayAnimator.currentTranslation` on SwiftUI's animation timeline. This is the overlay layer's actual Core Animation presentation transform, not a separate SwiftUI animation with merely matching duration and easing. Persistent commands remain instant and continue to use real split width.

Add routing/parity tests for cue, overlay revealing/presented/hiding, winning hide completion, side invalidation, persistent show, hidden rail/full selection, and stale completion. In every case titlebar width/mode equals controller-authoritative host presentation; no temporary lockup outlives overlay removal. Preserve completed left/right alignment, icon-before-text order, and 60-point rail suppression.

- [ ] **Step 7: Run, format, and commit routing/handoff**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift
./script/swift-test.sh --filter SidebarHoverIntegrationTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarSplitVisibilityOwnershipTests
./script/swift-test.sh --filter SidebarPresentationLayoutTests
git diff --check
```

Expected: tests pass; overlay width toggles do not move divider; overlay↔persistent handoff performs one geometry mutation and retains one sidebar host.

Commit: `feat(sidebar): route overlay persistent handoff`

---

### Task 5: Preserve Focus, Input, Accessibility, Grace, and Lifecycle

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarPresentationModel.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Create: `Sources/awesoMux/Views/SidebarInteractionMonitor.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift`
- Create: `Tests/awesoMuxTests/SidebarInteractionMonitorTests.swift`

**Interfaces:**
- Produces: `SidebarPresentationModel.sidebarInteractionChanged(_:)`, `SidebarSplitView.onSidebarInteractionChanged`, `SidebarSplitProxy.sidebarPointerChanged`.
- Preserves: existing pointer/sidebar hover grace and explicit focus handoff.
- Guarantee: active pointer, keyboard/AX focus, menu tracking, or sidebar interaction prevents overlay removal.

- [ ] **Step 1: Write failing passive-focus and active-retention tests**

Host detail/sidebar `FirstResponderView`s in a window. Assert passive overlay reveal leaves terminal responder unchanged. Directly focus a sidebar control, emit tracker/sidebar leave, advance grace, and assert overlay remains. After focus returns to detail and interaction clears, advance a newly scheduled grace and assert overlay hides.

Add a structural assertion in `SidebarHoverIntegrationTests.swift` that extracts the `onChange(of: sidebarFocusRequestID)` handler from `ContentView.swift` and requires the source range of `splitProxy.setPersistentVisible?(true)` to precede the range of `deliveredSidebarFocusRequestID = requestID`. Also assert the `SidebarView` initializer uses `focusRequestID: deliveredSidebarFocusRequestID`, never the incoming ID directly.

Add assertions that `overlayClipView.isAccessibilityElement == false` does not introduce a wrapper element, while the reparented sidebar retains its existing accessibility children and labels. Tracker/cue remain ignored.

For collapsed-rail peek geometry, publish a known sidebar tile frame before and after split→overlay reparent on both sides; convert through the controller root coordinate space and assert the ContentView-level peek anchor remains on the overlay's inward edge with unchanged vertical offset. This catches coordinate drift from the new superview chain without duplicating the peek card.

Add an AX exposure matrix:

| Overlay phase | Sidebar descendants AX-hidden? |
| --- | --- |
| hidden/offscreen | yes |
| passive reveal partial | yes |
| fully presented | no |
| hide requested while AX focus inside | hide is retained/cancelled; no |
| hide animation after AX focus leaves | yes before movement starts |
| persistent handoff | no, same descendant identity/parent chain |

Tests inject a focused sidebar accessibility element, assert its parent chain survives overlay→persistent reparent, and assert offscreen/partial descendants cannot appear in accessibility children.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarPresentationModelTests
```

Expected: active-focus retention test fails because overlay dismissal currently considers pointer presence only.

- [ ] **Step 3: Extend model retention with one interaction signal**

```swift
private var sidebarInteractionActive = false

func sidebarInteractionChanged(_ active: Bool) {
    sidebarInteractionActive = active
    if active {
        cancelDelayedHide()
        transition(to: .revealed)
    } else if !sidebarPointerPresent, trackerState != .revealed {
        scheduleDelayedTransition(to: trackerState)
    }
}
```

The delayed completion guards `!sidebarInteractionActive`. Do not create separate booleans for focus, menu, AX, and pointer in the model; controller/view integration reduces those sources to this one retention input.

- [ ] **Step 4: Implement the concrete interaction monitor without stealing focus**

Create `SidebarInteractionMonitor(sidebarRoot:focusedAccessibilityElement:onActiveChange:)`, with production's focused-element closure `{ NSApp.accessibilityFocusedUIElement() }`. It observes `NSWindow.didUpdateNotification`, `NSMenu.didBeginTrackingNotification`, and `NSMenu.didEndTrackingNotification` while attached. On window updates it computes:

```swift
let keyboardFocused = (window.firstResponder as? NSView).map(isInsideSidebar) ?? false
let accessibilityFocused = containsAccessibilityElement(
    NSApp.accessibilityFocusedUIElement()
)
let active = keyboardFocused || accessibilityFocused || sidebarMenuTracking
```

`containsAccessibilityElement` accepts an `NSView` descendant immediately; otherwise it walks `accessibilityParent()` up to 32 hops and succeeds when it reaches `sidebarRoot`. On menu-begin, set `sidebarMenuTracking = pointerInside || keyboardFocused || accessibilityFocused`; menu-end clears it and refreshes. Expose `pointerChanged(_:)` for menu attribution and `detach()`; `detach()` removes observers and reports false. Pointer retention itself remains owned by the model's existing `sidebarPointerChanged`, so the monitor does not duplicate that signal. Tests inject focused-element and notification sources so they do not mutate global VoiceOver state.

Passive reveal never calls `makeFirstResponder`. Add `SidebarSplitProxy.sidebarPointerChanged`; `SidebarView.onSidebarHover` calls both `sidebarPresentation.sidebarPointerChanged` and the proxy closure, which feeds `monitor.pointerChanged`. `SidebarSplitView` exposes `onSidebarInteractionChanged`, and the monitor's one `onActiveChange` closure calls `SidebarPresentationModel.sidebarInteractionChanged`. Direct clicks behave normally because the live sidebar view is hittable.

Do not make overlay background outside its frame hittable. Keep edge tracker pass-through above terminal. Verify sidebar scroll, buttons, context menu, search focus, and peek cards use the reparented original view/model rather than duplicated callbacks.

- [ ] **Step 5: Handle lifecycle and explicit focus atomically**

Implement one idempotent `settleDetached()` used by tracker availability loss, `viewDidDisappear`, window detachment, and `deinit`: invalidate grace/compositor generations; remove `SidebarOverlayAnimator.animationKey`; detach interaction/menu/window/AX observers; report interaction false exactly once; disable sidebar AX exposure; clear transform; reparent the host to `sidebarPaneContainer` only when both views are loaded; hide the overlay; reset host mode/chrome state to hidden; and nil callback closures that could retain external models. A stale held completion after detach must be a no-op. Reattaching reinstalls a fresh monitor/tracker without duplicating observers.

Add teardown tests with held animation/menu/focused responder: call `settleDetached`, assert stable hidden parentage, identity transform, zero observers, false retention once, hidden chrome, and stale completion no-op; then release the controller and assert weak deallocation.

Side change performs the same immediate overlay cleanup before moving tracker, but retains live controller callbacks for the new side.

Serialize Focus Sidebar delivery with a separate `@State private var deliveredSidebarFocusRequestID: UUID?`. Pass that delivered ID into `SidebarView`, not the incoming `sidebarFocusRequestID`. In the incoming request handler:

```swift
sidebarPresentation.showPersistently()
splitProxy.setPersistentVisible?(true) // synchronous same-host reparent + split settle
deliveredSidebarFocusRequestID = requestID
```

This guarantees the existing `SidebarView.onChange(of: focusRequestID)` runs only after the host is persistent; never focus a view scheduled for overlay removal. Atomic handoff captures both first responder and the injected accessibility-focused element when they belong to `sidebarChild.view`; after settled reparent it asserts their ancestry still reaches the same host before publishing persistent state.

Explicit hide while sidebar-focused calls existing `onSidebarFocusHandoff` before real split collapse. If overlay-focused and an explicit persistent hide arrives, hand focus to active terminal before removing overlay.

- [ ] **Step 6: Run, format, and commit interaction hardening**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarInteractionMonitor.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift Tests/awesoMuxTests/SidebarInteractionMonitorTests.swift
./script/swift-test.sh --filter SidebarPresentationModelTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarEdgeTrackingViewTests
./script/swift-test.sh --filter SidebarInteractionMonitorTests
./script/swift-test.sh --filter SidebarPeekModelTests
git diff --check
```

Expected: suites pass; passive reveal preserves terminal focus; active sidebar input retains overlay; lifecycle and explicit commands settle without stale focus or duplicate views.

Commit: `fix(sidebar): retain overlay during interaction`

---

### Task 6: Prove Hover Geometry Isolation

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Create: `Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`

**Interfaces:**
- Produces secondary intent instrumentation: `splitPositionMutationIntentCountForTesting`, `resetGeometryInstrumentationForTesting()`.
- Primary guarantee: `GeometryRecordingView.changedSubmittedBackingSizes` stays empty for cue, overlay reveal/hide, transform ticks, reversal, resize reclamp, and hidden rail/full toggle. Persistent show records one divider intent and one final settled changed size; raw AppKit frame-notification count is not an acceptance contract.

- [ ] **Step 1: Add failing geometry-isolation tests**

```swift
@Test("hover overlay never mutates split or terminal backing geometry")
func hoverHasZeroGeometryMutations() {
    let (controller, _, detail) = makeHiddenController()
    let detailFrame = detail.view.frame
    controller.resetHoverGeometryInstrumentationForTesting()

    controller.setOverlayPresented(true, transition: .hover(duration: 0.140), reduceMotion: false)
    driver.advance(toTranslationX: -100)
    controller.setOverlayPresented(false, transition: .hover(duration: 0.140), reduceMotion: false)
    driver.finishLatest()

    #expect(controller.splitPositionMutationIntentCountForTesting == 0)
    #expect(detail.changedSubmittedBackingSizes.isEmpty)
    #expect(detail.view.frame == detailFrame)
}
```

Repeat for left/right, rail/full, Reduce Motion, rapid reversal, partial-animation width remap, and window resize. Add an explicit persistent-show control expecting exactly one split-position intent and one final changed submitted backing size. Frame notifications may coalesce or repeat internally; they are diagnostic only and cannot substitute for the recording view's changed-size evidence.

- [ ] **Step 2: Run and verify RED**

Run: `./script/swift-test.sh --filter SidebarHoverGeometryIsolationTests`

Expected: compilation fails because geometry instrumentation does not exist.

- [ ] **Step 3: Instrument the only geometry mutation boundaries**

Route every divider setter—persistent reveal/hide, cold restoration, position change normalization, resize reclamp, and delegate normalization—through existing `setDividerPosition(_:)`; increment `splitPositionMutationIntentCountForTesting` whenever instrumentation is armed. `resetGeometryInstrumentationForTesting()` zeros and arms the secondary counter; `stopGeometryInstrumentationForTesting()` disarms it. No other direct `splitView.setPosition` call may remain; add a structural source test allowing that symbol only inside `setDividerPosition`.

Instrumentation is internal and inert until `resetHoverGeometryInstrumentationForTesting()` arms it; it must not log, allocate per animation frame, or ship telemetry.

- [ ] **Step 4: Add a real terminal-resize policy regression**

Use a test-only `GeometryRecordingView: NSView` as `detailChild.view`; override `setFrameSize(_:)`, compare against the previous size, append only changed values to `changedSubmittedBackingSizes`, and clear the array after fixture layout. Overlay transform requests must append zero sizes. Persistent show control appends one final settled size. This changed-size array is the primary zero-Ghostty proof; intent count proves the controller did not ask the split to move.

- [ ] **Step 5: Run focused and full automated verification**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitController.swift Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
./script/swift-test.sh --filter SidebarHoverGeometryIsolationTests
./script/swift-test.sh --filter SidebarOverlayAnimatorTests
./script/swift-test.sh --filter SidebarOverlayHostControllerTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh
git diff --check
```

Expected: all tests pass; hover matrix reports zero split intents and an empty changed-size array; persistent-show control reports one intent and one final changed size; full suite is green.

- [ ] **Step 6: Commit instrumentation/regressions**

Commit: `test(sidebar): prove hover geometry isolation`

---

### Task 7: Full Build, Live QA, Two Hard Review Gates, and Documentation

**Files:**
- Modify only if verification exposes an approved defect: files from Tasks 1–6 and their focused tests.
- Update the private session note outside this repository.

**Interfaces:**
- Consumes all prior task interfaces.
- Produces no new architecture; closes verification and records durable outcomes.

- [ ] **Step 1: Run targeted formatting, full tests, and production build**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarOverlayAnimator.swift Sources/awesoMux/Views/SidebarOverlayClipView.swift Sources/awesoMux/Views/SidebarInteractionMonitor.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift Tests/awesoMuxTests/SidebarOverlayAnimatorTests.swift Tests/awesoMuxTests/SidebarOverlayClipViewTests.swift Tests/awesoMuxTests/SidebarSemanticPaneIdentityTests.swift Tests/awesoMuxTests/SidebarInteractionMonitorTests.swift Tests/awesoMuxTests/SidebarOverlayHostControllerTests.swift Tests/awesoMuxTests/SidebarHoverGeometryIsolationTests.swift Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift
./script/swift-test.sh
script/format.sh --lint Sources/awesoMux/Views/SidebarOverlayAnimator.swift Sources/awesoMux/Views/SidebarOverlayClipView.swift Sources/awesoMux/Views/SidebarInteractionMonitor.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift
git diff --check
./script/build_and_run.sh
```

Expected: formatting/lint clean, full Swift suite green, development app builds, launches, and stays running.

- [ ] **Step 2: Verify proximity and motion live on both sides**

For left and right, with rail then full selected:

1. Hide instantly with `Command-Shift-Backslash`.
2. At 80–40 points observe only the 4-point cue and zero terminal movement.
3. At or inside 40 points observe the live sidebar slide over the terminal in exactly 140ms.
4. Type continuously during slide; terminal focus/input remains live and text does not reflow.
5. Rapidly reverse across 40 points; animation continues from its visible transform without jumps or stale completion.
6. Enable Reduce Motion; overlay appears/disappears instantly.
7. During a held/slow partial reveal, click, drag-select, scroll, and contextual-click both the visually covered sliver and visually uncovered terminal edge: only covered pixels target sidebar; uncovered pixels target terminal.
8. Resize and switch rail/full during a partial reveal; visible fraction is preserved on left and right, hit-test bounds follow the new presentation, and terminal/detail geometry remains stable.

- [ ] **Step 3: Verify live sidebar interaction and grace**

Use search, scroll, workspace selection, buttons, context menus, rail peek cards, keyboard focus, and VoiceOver navigation in the overlay. Move outside while a control/menu/AX focus is active: overlay stays. End interaction and leave both regions: 220ms grace dismisses it. Passive partial reveal must never expose offscreen sidebar descendants to VoiceOver, announce a persistent preference change, or steal terminal/VoiceOver focus. Fully presented overlay exposes its existing children; persistent handoff preserves the focused element's identity/ancestry.

- [ ] **Step 4: Verify width and explicit handoff**

While hidden dormant press `Command-Backslash`: no overlay, cue, split movement, or terminal resize. Next hover uses chosen rail/full width. While overlay is visible or partially animated press it again: fraction maps to the new width without reflow or hit shield. While overlay is visible press `Command-Shift-Backslash`: the no-actions handoff produces no double sidebar/blank flash, preserves sidebar responder/AX identity, clears transform residue, and issues one persistent geometry intent. Focus Sidebar from hidden performs persistent show before focus. Explicit hide hands focus to terminal and collapses once. At each state confirm the titlebar lockup width/visibility matches the actual controller host mode and disappears only after overlay hide completes.

- [ ] **Step 5: Verify detach and root-update resilience**

With overlay partial, fully presented, keyboard-focused, AX-focused, and contextual-menu-active, deactivate/detach/close the window. It settles hidden, removes menu/window/animation observers, clears AX exposure/transform/titlebar state, and never resurrects from stale completion. Reopen and confirm one tracker/monitor only. Trigger unrelated SwiftUI/sidebar data updates in hidden, animating overlay, presented overlay, and persistent modes; the same sidebar host retains search/scroll state and parentage with no reparent or terminal resize.

- [ ] **Step 6: Capture visible UI evidence**

Capture focused screenshots:

```bash
screencapture -i /tmp/awesomux-overlay-left-full.png
screencapture -i /tmp/awesomux-overlay-left-rail.png
screencapture -i /tmp/awesomux-overlay-right-full.png
screencapture -i /tmp/awesomux-overlay-right-rail.png
screencapture -i /tmp/awesomux-overlay-right-persistent-handoff.png
```

Expected: terminal content remains full-width beneath overlays; sidebar is edge-aligned; right title lockup is trailing with 10-point padding and icon-before-text; rail suppression is unchanged; persistent handoff shows one sidebar. Preserve a left/right overlay comparison for the eventual PR body; do not commit `/tmp` artifacts.

- [ ] **Step 7: Build the final merge-base review package**

After implementation, the full automated suite, and every live-QA step above are complete, create an ignored local package under `.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/`. Run:

```bash
mkdir -p .superpowers/reviews/sidebar-hover-overlay/pre-pr/package
BASE=$(git merge-base origin/main HEAD)
printf '%s\n' "$BASE" > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/merge-base.txt
git diff --name-status "$BASE"...HEAD > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/full-changed-files.txt
git diff --stat "$BASE"...HEAD > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/diff-stat.txt
git diff --check "$BASE"...HEAD
git diff --find-renames --find-copies "$BASE"...HEAD > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/full-branch.diff
git diff --name-status "$BASE"...HEAD -- . ':(exclude)docs/superpowers/**' ':(exclude).superpowers/**' > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/changed-files.txt
git diff --find-renames --find-copies "$BASE"...HEAD -- . ':(exclude)docs/superpowers/**' ':(exclude).superpowers/**' > .superpowers/reviews/sidebar-hover-overlay/pre-pr/package/final.diff
```

Preserve those outputs at:

```text
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/merge-base.txt
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/full-changed-files.txt
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/changed-files.txt
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/diff-stat.txt
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/full-branch.diff
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/final.diff
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/test-evidence.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/package/live-qa-evidence.md
```

`test-evidence.md` records exact commands, exit statuses, suite/test counts, and geometry-isolation results. `live-qa-evidence.md` records the completed checklist and screenshot paths. `full-branch.diff` is available to Gate A. `final.diff` and `changed-files.txt` deliberately exclude `docs/superpowers/**` and `.superpowers/**`, so Gate B cannot receive specs, plans, architecture reviews, or prior reports. Do not copy design discussion, brainstorming, conversational history, or earlier findings into evidence files.

- [ ] **Step 8: Hard Gate A — run the full specialist review matrix**

Read the user-selected local multi-reviewer orchestrator skill completely at execution time, then read every complete sibling reviewer prompt it requires. The committed plan uses neutral lane labels because reviewer/persona terminology must not enter public artifacts. Run independent read-only subagents in parallel for:

```text
core lane 01
core lane 02
core lane 03
core lane 04
core lane 05
Swift/macOS specialist lane
Codex generalist
```

Paste the full tuned prompt into each corresponding worker. Require actual-file reads, exact file/line references, `AUTO-FIX`/`ASK`/`NIT` classification, and no edits. Preserve unabridged raw reports plus consolidation/disposition:

```text
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/core-01.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/core-02.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/core-03.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/core-04.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/core-05.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/swift-macos.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/codex-generalist.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/consolidated.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/specialist/round-01/disposition.md
```

`consolidated.md` deduplicates by severity while retaining exact references. `disposition.md` maps every finding to `fixed`, `not reproducible` with evidence, `declined NIT` with rationale, or `ASK resolved` with the decision.

For each valid defect: add/adjust a focused test, run it RED, implement the minimum fix, run the focused suite GREEN, then run:

```bash
./script/swift-test.sh
git diff --check
./script/build_and_run.sh
```

Repeat affected live-QA checks. Refresh the package, preserve the next complete matrix under `specialist/round-02/` (then `round-03/`, etc.), and rerun all seven lanes—not only the lane that found the issue. Gate A is clean only when a fresh full round has no unresolved `AUTO-FIX` or `ASK`, no reproducible correctness/accessibility/performance defect, and every retained NIT has an explicit disposition. Never overwrite a raw round.

Commit each verified review-fix batch locally with a conventional commit before refreshing the package; do not push it. The clean round must review committed `HEAD`, not an uncommitted working-tree variant.

- [ ] **Step 9: Hard Gate B — run a context-free adversarial review**

Only after Gate A is clean and its fixes pass the full automated/live loop, refresh the package from the new merge-base diff. Spawn one fresh adversarial subagent with `fork_turns="none"`. Give it only:

1. applicable `AGENTS.md` and imported repository rules;
2. `package/changed-files.txt`;
3. `package/final.diff`;
4. `package/test-evidence.md`;
5. `package/live-qa-evidence.md`.

The prompt explicitly forbids reading or being told any spec, design, plan, issue description, conversation/history, prior reviewer report, consolidation, disposition, commit message/history, PR text, or repository file outside the supplied `AGENTS.md` chain and five package inputs. The worker reviews unfamiliar code adversarially for behavioral defects, unsafe ownership/lifecycle assumptions, AppKit/SwiftUI integration failures, missing negative tests, and claims not proved by the supplied diff/evidence. It is read-only and returns findings first with exact diff file/line references and severity.

Preserve its exact prompt, raw report, and disposition:

```text
.superpowers/reviews/sidebar-hover-overlay/pre-pr/adversarial/round-01/prompt.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/adversarial/round-01/report.md
.superpowers/reviews/sidebar-hover-overlay/pre-pr/adversarial/round-01/disposition.md
```

Fix valid findings through focused RED → minimum fix → focused GREEN → full suite → `git diff --check` → build → affected live QA. Refresh the package and launch a new `fork_turns="none"` adversary using only the five allowed final inputs; preserve it as `round-02/` and repeat until a fresh report has no unresolved actionable finding. Never give a later adversary earlier reports or dispositions.

Commit each verified adversarial-fix batch locally before returning to the complete Gate A matrix; do not push it.

**Hard stop:** do not create a PR, run `gh pr create`, run `git push`, push any review fix, or report the branch PR-ready until both Gate A and Gate B are clean against the same final HEAD/package.

- [ ] **Step 10: Reconfirm both gates on the exact final SHA**

If either gate causes any branch code/test/config change, rerun Gate A's complete seven-lane matrix first, then a new context-free Gate B against that exact HEAD. Record the final clean SHA alone in:

```text
.superpowers/reviews/sidebar-hover-overlay/pre-pr/FINAL-CLEAN-SHA.txt
```

Verify it equals `git rev-parse HEAD`. Any later branch code/test/config change invalidates both gates and requires both to rerun.

- [ ] **Step 11: Run preflight and refresh overlap**

Run:

```bash
./script/preflight.sh
gh pr list --base main --state open --json number,title,author,files
git diff --name-only origin/main...HEAD
git status --short
```

Expected: preflight passes, or only the already documented macOS Bash 3 `mapfile: command not found` infrastructure failure remains after preceding guards pass. Report every open PR touching changed files. Preserve unrelated concurrent worktree changes. A preflight-driven code change invalidates the recorded SHA and returns to Gate A.

- [ ] **Step 12: Finish private documentation after both review gates**

Update the private session note outside this repository.

- [ ] **Step 13: Commit verification-only fixes if any, then rerun both gates**

Commit only when verification required changes: `fix(sidebar): address overlay verification findings`. Because that changes HEAD, refresh the package and rerun Gate A then Gate B before any PR/push. Any final branch documentation/config/test change also invalidates `FINAL-CLEAN-SHA`.

---

## Subagent-Driven Execution Notes

- Dispatch a fresh implementation subagent per task, sequentially; Tasks 1–6 share `SidebarSplitController.swift` and must never write concurrently.
- After each task, dispatch a spec-compliance reviewer, then a code-quality reviewer. Resolve findings before the next task.
- Give every worker this plan, the approved spec at commit `3723e33`, the original sidebar design, their task number, and current SHA.
- Workers must preserve concurrent changes, demonstrate focused RED before production edits, run all GREEN commands, and commit only their task.
- Task 1 deliberately removes landed code; reviewers must verify retained persistent split behavior rather than demanding compatibility with the rejected divider animator.
- Task 7's specialist matrix and context-free adversary are mandatory separate pre-PR gates. Implementation is not ready for PR or push until both are clean on `FINAL-CLEAN-SHA`, geometry-isolation tests and live overlay QA are complete, screenshots are preserved, and session documentation is updated.
