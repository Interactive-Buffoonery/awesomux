# Sidebar Hover Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the persistently hidden sidebar discoverable with a pass-through 40-point proximity region, a 4-point cue, and a 140-millisecond pointer-only reveal animation while preserving immediate commands and hidden rail/full selection.

**Architecture:** `SidebarPresentationModel` becomes the single source of truth for dormant/cue/revealed proximity state and stale-work cancellation. A new AppKit tracking view reports local pointer geometry without accepting events; `SidebarSplitController` owns cancellable divider animation, while `ContentView` renders the non-interactive cue and routes explicit versus hover transitions separately.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSView`, `NSTrackingArea`, `NSSplitView`, `NSAnimationContext`), Observation, swift-testing.

## Global Constraints

- macOS 15+ and SwiftPM only.
- The tracking region is exactly 40 points from the configured physical edge.
- At exactly 40 points the cue is active; only distances strictly less than 16 points reveal the sidebar.
- The cue is exactly 4 points wide, overlays the edge, and reserves no layout width.
- Hover reveal and hover hide use a 140-millisecond ease-in-out animation with no spring or overshoot.
- `Command-Shift-Backslash`, Focus Sidebar, side changes, restoration, and all other explicit actions remain immediate.
- `Command-Backslash` changes the remembered rail/full mode while persistently hidden without revealing, cueing, or moving the divider.
- Pointer tracking must not consume clicks, drags, scrolling, contextual clicks, terminal selection, keyboard focus, or accessibility focus.
- Do not install a window-wide event monitor or a SwiftUI hit-testing overlay.
- Reduce Motion makes pointer-driven divider movement immediate; cue opacity may still fade briefly.
- Hidden and intermediate animation widths are never persisted.
- Left/right behavior is symmetric and derives distance from current local bounds, not cached screen coordinates.
- Use targeted `script/format.sh` only on intentionally changed Swift files.
- Follow test-driven development: run each focused test and observe RED before production implementation.

## File Responsibility Map

- `Sources/awesoMux/Views/SidebarPresentationModel.swift`: owns `ProximityState`, exact boundary policy, grace scheduling, and generation invalidation.
- `Sources/awesoMux/Views/SidebarEdgeTrackingView.swift`: pass-through AppKit tracking surface and local left/right distance conversion.
- `Sources/awesoMux/Views/SidebarSplitController.swift`: hosts the split plus tracking surface, updates tracking geometry, and performs/cancels hover divider animations.
- `Sources/awesoMux/Views/SidebarSplitView.swift`: carries tracking callbacks and explicit/hover visibility commands across the SwiftUI/AppKit boundary.
- `Sources/awesoMux/Views/SidebarSplitSupport.swift`: defines the typed proxy transition API shared by `ContentView` and `SidebarSplitController`.
- `Sources/awesoMux/Views/ContentView.swift`: renders the 4-point cue, routes proximity events, permits hidden width selection, and keeps explicit actions instantaneous.
- `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`: boundary, state-machine, grace, lifecycle, and stale-token coverage.
- `Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift`: local geometry, resize, pass-through input, and responder preservation.
- `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`: animation policy, interruption, side symmetry, resize, Reduce Motion, focus, and persistence guards.
- `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`: pure orchestration policy for hidden width toggles and explicit-versus-hover transitions.

## Interfaces Shared Across Tasks

```swift
extension SidebarPresentationModel {
    enum ProximityState: Equatable { case dormant, cue, revealed }

    static let cueDistance: CGFloat = 40
    static let revealDistance: CGFloat = 16
    static let leaveGrace: Duration = .milliseconds(220)

    func pointerMoved(
        x: CGFloat,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition
    )
    func trackingRegionExited()
    func sidebarPointerChanged(_ isPresent: Bool)
    func invalidateTransientState()
}

enum SidebarSplitTransition: Equatable {
    case immediate
    case hover(duration: TimeInterval)
}

extension SidebarSplitProxy {
    // Existing setWidth and setPosition remain unchanged.
    var setVisibility: ((Bool, SidebarSplitTransition) -> Void)?
}

final class SidebarEdgeTrackingView: NSView {
    var position: AppearanceConfig.SidebarPosition
    var onPointerMove: ((CGFloat, CGFloat) -> Void)?
    var onExit: (() -> Void)?
    var onAvailabilityLost: (() -> Void)?
    static func distance(
        x: CGFloat,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition
    ) -> CGFloat
}
```

`setVisibility` receives **visible**, not hidden, to avoid double-negatives at call sites. `.hover(duration: 0.140)` is used only for proximity transitions; every other caller uses `.immediate`.

---

### Task 1: Replace Hover Booleans with the Proximity State Machine

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarPresentationModel.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`

**Interfaces:**
- Consumes: `AppearanceConfig.SidebarPosition`.
- Produces: `ProximityState`, `isCueVisible`, `isSidebarVisible`, `pointerMoved(x:width:position:)`, `trackingRegionExited()`, `invalidateTransientState()`.
- Preserves: `togglePersistentVisibility()`, `showPersistently()`, `sidebarPointerChanged(_:)`.

- [ ] **Step 1: Write failing exact-boundary and side-symmetry tests**

Replace edge-presence tests with table-driven local-coordinate tests:

```swift
@Test("40 points cues and inside 16 points reveals on both sides")
func exactProximityBoundaries() throws {
    let (model, _, defaults, suiteName) = try makeHiddenModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    model.pointerMoved(x: 60, width: 100, position: .right) // distance 40
    #expect(model.proximityState == .cue)
    #expect(model.isCueVisible)
    #expect(!model.isSidebarVisible)

    model.pointerMoved(x: 84, width: 100, position: .right) // distance 16
    #expect(model.proximityState == .cue)
    model.pointerMoved(x: 84.5, width: 100, position: .right)
    #expect(model.proximityState == .revealed)

    model.invalidateTransientState()
    model.pointerMoved(x: 40, width: 100, position: .left)
    #expect(model.proximityState == .cue)
    model.pointerMoved(x: 15.5, width: 100, position: .left)
    #expect(model.proximityState == .revealed)
}

@Test("distance outside 40 points is dormant")
func outsideCueZoneIsDormant() throws {
    let (model, _, defaults, suiteName) = try makeHiddenModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    model.pointerMoved(x: 40.5, width: 100, position: .left)
    #expect(model.proximityState == .dormant)
}
```

- [ ] **Step 2: Run the model suite and verify RED**

Run: `./script/swift-test.sh --filter SidebarPresentationModelTests`

Expected: compilation fails because `ProximityState`, `pointerMoved`, and `isCueVisible` do not exist.

- [ ] **Step 3: Implement the minimal deterministic state classifier**

Use one enum and one mutation path; do not retain `edgePointerPresent` or derive state from multiple booleans:

```swift
enum ProximityState: Equatable { case dormant, cue, revealed }
static let cueDistance: CGFloat = 40
static let revealDistance: CGFloat = 16
static let leaveGrace: Duration = .milliseconds(220)

private(set) var proximityState: ProximityState = .dormant

var isTemporarilyRevealed: Bool { proximityState == .revealed }
var isCueVisible: Bool { userWantsHidden && proximityState == .cue }
var isSidebarVisible: Bool { !userWantsHidden || proximityState == .revealed }

func pointerMoved(x: CGFloat, width: CGFloat, position: AppearanceConfig.SidebarPosition) {
    guard userWantsHidden, width.isFinite, width > 0, x.isFinite else { return }
    let clampedX = min(max(0, x), width)
    let distance = position == .left ? clampedX : width - clampedX
    let next: ProximityState
    if distance < Self.revealDistance { next = .revealed }
    else if distance <= Self.cueDistance { next = .cue }
    else { next = .dormant }
    transition(to: next)
}
```

`transition(to:)` cancels the pending hide before accepting `.cue` or `.revealed`. A direct `.revealed -> .cue/.dormant` caused by leaving the tracker must schedule the existing 220ms grace instead of collapsing immediately while the pointer crosses into the sidebar.

- [ ] **Step 4: Add failing grace, jitter, and stale-generation tests**

Add tests that prove:

```swift
model.pointerMoved(x: 15, width: 100, position: .left) // revealed
model.trackingRegionExited()
#expect(await waitUntil { gate.sleeperCount == 1 })
model.sidebarPointerChanged(true)
gate.advance()
await drainMainQueue()
#expect(model.proximityState == .revealed)

model.sidebarPointerChanged(false)
#expect(await waitUntil { gate.sleeperCount == 2 })
model.pointerMoved(x: 30, width: 100, position: .left) // newer cue
gate.advance()
await drainMainQueue()
#expect(model.proximityState == .cue)
```

Also alternate points `40`, `39.9`, `16`, and `15.9` and assert every call produces exactly one stable enum value.

- [ ] **Step 5: Implement generation-safe grace and lifecycle invalidation**

Use `generation` for every delayed completion. `togglePersistentVisibility()`, `showPersistently()`, `positionDidChange()`, and new `invalidateTransientState()` must call one helper:

```swift
private func clearTransientState() {
    cancelDelayedHide()
    sidebarPointerPresent = false
    proximityState = .dormant
}
```

The delayed closure captures `scheduledGeneration` and changes state only when the generation still matches, the sidebar pointer is absent, and `userWantsHidden` remains true.

- [ ] **Step 6: Run, format, and commit the state machine**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarPresentationModel.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift
./script/swift-test.sh --filter SidebarPresentationModelTests
git diff --check
```

Expected: all `SidebarPresentationModelTests` pass; diff check emits no output.

Commit: `refactor(sidebar): model proximity reveal states`

---

### Task 2: Add the Pass-Through AppKit Edge Tracker

**Files:**
- Create: `Sources/awesoMux/Views/SidebarEdgeTrackingView.swift`
- Create: `Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`

**Interfaces:**
- Consumes: `AppearanceConfig.SidebarPosition`, `SidebarPresentationModel.pointerMoved(x:width:position:)` through callbacks.
- Produces: `SidebarEdgeTrackingView`, `SidebarSplitController.onEdgePointerMove`, `SidebarSplitController.onEdgeExit`.
- Invariant: tracker frame is 40 points wide only while persistently hidden; `hitTest(_:)` always returns `nil`.

- [ ] **Step 1: Write failing tracker geometry and pass-through tests**

```swift
@MainActor
@Suite("SidebarEdgeTrackingView")
struct SidebarEdgeTrackingViewTests {
    @Test("hit testing always passes through")
    func passThroughHitTesting() {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }

    @Test("distance mirrors across current local bounds")
    func mirroredDistance() {
        #expect(SidebarEdgeTrackingView.distance(x: 12, width: 40, position: .left) == 12)
        #expect(SidebarEdgeTrackingView.distance(x: 28, width: 40, position: .right) == 12)
        #expect(SidebarEdgeTrackingView.distance(x: 20, width: 80, position: .right) == 60)
    }
}
```

- [ ] **Step 2: Run tracker tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarEdgeTrackingViewTests`

Expected: compilation fails because `SidebarEdgeTrackingView` does not exist.

- [ ] **Step 3: Implement the local tracking view**

Create a flipped, accessibility-hidden view with a rebuilt `.mouseEnteredAndExited`, `.mouseMoved`, `.activeInKeyWindow`, `.inVisibleRect` tracking area:

```swift
final class SidebarEdgeTrackingView: NSView {
    var position: AppearanceConfig.SidebarPosition
    var onPointerMove: ((CGFloat, CGFloat) -> Void)?
    var onExit: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onPointerMove?(local.x, bounds.width)
    }

    override func mouseExited(with event: NSEvent) { onExit?() }
}
```

`distance` clamps non-finite/negative input and mirrors `x` against the supplied live width. Override `viewDidMoveToWindow()` to replace a scoped `NSWindow.didResignKeyNotification` observer for the current window; call `onAvailabilityLost` when the view detaches or that window resigns key. Remove the observer in `deinit`.

- [ ] **Step 4: Write failing controller-host tests**

Add controller tests that set left/right position, resize from 1,200 to 900, and assert a testing accessor returns tracker frames `(x: 0, width: 40)` and `(x: 860, width: 40)`. Put a `FirstResponderView` in detail, make it first responder, update tracker geometry, and assert it stays first responder. Assert tracker visibility becomes false when persistently visible or detached/inactive invalidation is requested.

- [ ] **Step 5: Host the tracker above—not inside—the NSSplitView pane list**

Change the controller root to a plain `NSView` containing `splitView` and `edgeTrackingView`; keep only sidebar/detail as direct `splitView` subviews. Pin both by frame in `viewDidLayout()`:

```swift
splitView.frame = view.bounds
let width = min(SidebarPresentationModel.cueDistance, view.bounds.width)
edgeTrackingView.frame = CGRect(
    x: sidebarPosition == .left ? 0 : view.bounds.width - width,
    y: 0,
    width: width,
    height: view.bounds.height
)
```

Expose callbacks:

```swift
var onEdgePointerMove: ((CGFloat, CGFloat) -> Void)?
var onEdgeExit: (() -> Void)?
```

Forward tracker events without touching first responder. Add `setEdgeTrackingEnabled(_:)`; disabling removes/hides tracking immediately and emits `onEdgeExit` once.

- [ ] **Step 6: Wire callbacks through `SidebarSplitView` and verify**

Add representable properties `edgeTrackingEnabled`, `onEdgePointerMove`, and `onEdgeExit`; assign them in both `makeNSViewController` and `updateNSViewController`.

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
./script/swift-test.sh --filter SidebarEdgeTrackingViewTests
./script/swift-test.sh --filter SidebarSplitControllerTests
git diff --check
```

Expected: tracker and split-controller suites pass; responder assertion remains true; diff check is clean.

Commit: `feat(sidebar): track hidden edge proximity`

---

### Task 3: Add Cancellable Pointer-Only Divider Animation

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`

**Interfaces:**
- Consumes: selected width already held in `pendingWidth`/`lastExpandedPaneWidth` and semantic left/right divider math.
- Produces: `SidebarSplitTransition`, `SidebarSplitController.setSidebarVisible(_:transition:reduceMotion:)`, `SidebarSplitProxy.setVisibility`.
- Preserves: existing `setSidebarHidden(_:)` as an immediate compatibility wrapper until all callers migrate in Task 4.

- [ ] **Step 1: Write failing transition-policy and target tests**

Add tests for the public transition API:

```swift
controller.setSidebarWidth(300)
controller.setSidebarHidden(true)
controller.setSidebarVisible(true, transition: .hover(duration: 0.140), reduceMotion: false)
#expect(controller.lastAnimationForTesting == .init(fromWidth: 0, toWidth: 300, duration: 0.140))

controller.setSidebarVisible(false, transition: .hover(duration: 0.140), reduceMotion: true)
#expect(controller.lastAnimationForTesting == nil)
#expect(sidebar.view.frame.width == 0)
```

Repeat for `.right` and assert target divider coordinates use `dividerCoordinate(forSidebarWidth:paneExtent:position:)`.

- [ ] **Step 2: Run controller tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarSplitControllerTests`

Expected: compilation fails because `SidebarSplitTransition` and `setSidebarVisible` do not exist.

- [ ] **Step 3: Implement immediate and hover transition routing**

```swift
enum SidebarSplitTransition: Equatable {
    case immediate
    case hover(duration: TimeInterval)
}

func setSidebarVisible(
    _ visible: Bool,
    transition: SidebarSplitTransition,
    reduceMotion: Bool
) {
    cancelHoverAnimation()
    let shouldAnimate = !reduceMotion && transition == .hover(duration: 0.140)
    if shouldAnimate { animateSidebarVisibility(visible, duration: 0.140) }
    else { applySidebarVisibilityImmediately(visible) }
}
```

Do not compare the enum to one hard-coded associated value in production; switch over it and use the provided duration. Explicit calls pass `.immediate`; hover calls pass `.hover(duration: 0.140)`.

- [ ] **Step 4: Implement cancellable animation from the current presentation width**

Maintain `animationGeneration`, `requestedSidebarVisible`, and `isHoverAnimating`. Before starting, read `sidebarPaneWidth`; target `0` when hiding or the clamped remembered width when revealing. For reveal, clear `isSidebarHidden` before starting so delegate constraints permit motion. For hide, keep `isSidebarHidden == false` until the winning completion reaches zero; `isHoverAnimating` suppresses drag, reclamp, live-width, and commit behavior during both directions. Use:

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = duration
    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    context.allowsImplicitAnimation = true
    splitView.animator().setPosition(targetCoordinate, ofDividerAt: 0)
} completionHandler: { [weak self] in
    Task { @MainActor in self?.finishHoverAnimation(generation: generation) }
}
```

`finishHoverAnimation` no-ops for stale generations and normalizes to `requestedSidebarVisible`. A winning hide completion sets `isSidebarHidden = true` only after the divider reaches zero; a winning reveal completion leaves it false. Immediate transitions increment the generation and normalize synchronously. This ordering prevents the existing hidden delegate constraints from pinning an in-flight animation at zero. Suppress live and commit callbacks for programmatic/hover animation ticks.

- [ ] **Step 5: Add failing interruption and resize tests**

Inject an animation driver seam so tests can hold completions. Assert:

- reveal begins `0 -> 300`;
- simulated midpoint width `120`, then hide begins `120 -> 0` rather than `300 -> 0`;
- completing the old reveal token cannot reopen after the hide;
- resizing clamps both current and target width, cancels invalid work, and settles at the newest requested state;
- no `onCommitWidth` fires and no width preference callback sees `0` or an intermediate value;
- `.immediate` during animation invalidates the completion and settles synchronously.

Use a protocol-free closure seam:

```swift
typealias AnimationRunner = (
    TimeInterval, @escaping () -> Void, @escaping () -> Void
) -> Void
```

Production runs the changes in `NSAnimationContext`; tests capture both closures.

- [ ] **Step 6: Wire proxy and preserve initial hidden restoration**

Add `setVisibility` to `SidebarSplitProxy`. In `SidebarSplitView.makeNSViewController`, apply the initial hidden value immediately before width restoration; in updates, side changes and explicit hidden values use `.immediate`. Do not animate cold launch.

- [ ] **Step 7: Run, format, and commit animation support**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarPresentationModelTests
git diff --check
```

Expected: both suites pass; interruption tests reject stale completions; diff check is clean.

Commit: `feat(sidebar): animate pointer reveal transitions`

---

### Task 4: Integrate the Cue and Hidden Width Selection

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Create: `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`

**Interfaces:**
- Consumes: `proximityState`, `isCueVisible`, `SidebarSplitProxy.setVisibility`, `SidebarSplitTransition`.
- Produces: `SidebarHoverTransitionPolicy.transition(for:reduceMotion:)` and `SidebarHiddenWidthTogglePolicy.targetWidth(...)` as pure, testable orchestration policies.
- Preserves: `commitSidebarWidth(_:)` as the sole width persistence path.

- [ ] **Step 1: Write failing hidden-width and transition-routing tests**

```swift
@Suite("Sidebar hover integration")
struct SidebarHoverIntegrationTests {
    @Test("hidden width toggle changes selection without visibility")
    func hiddenWidthToggle() {
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: 300,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == SidebarWidthPolicy.collapsedWidth)
        #expect(!result.shouldReveal)
    }

    @Test("only pointer transitions animate")
    func transitionKinds() {
        #expect(SidebarHoverTransitionPolicy.transition(for: .pointer, reduceMotion: false) == .hover(duration: 0.140))
        #expect(SidebarHoverTransitionPolicy.transition(for: .pointer, reduceMotion: true) == .immediate)
        #expect(SidebarHoverTransitionPolicy.transition(for: .explicit, reduceMotion: false) == .immediate)
    }
}
```

- [ ] **Step 2: Run integration tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarHoverIntegrationTests`

Expected: compilation fails because both policies do not exist.

- [ ] **Step 3: Add the minimal pure orchestration policies**

Define the policies beside `ContentView` (internal visibility) with exact result types:

```swift
enum SidebarVisibilitySource { case pointer, explicit }

struct SidebarHiddenWidthToggleResult: Equatable {
    let targetWidth: CGFloat
    let shouldReveal: Bool
}

enum SidebarHoverTransitionPolicy {
    static func transition(
        for source: SidebarVisibilitySource,
        reduceMotion: Bool
    ) -> SidebarSplitTransition {
        source == .pointer && !reduceMotion ? .hover(duration: 0.140) : .immediate
    }
}
```

The width policy calls `SidebarWidthPolicy.toggleWidth` and always returns `shouldReveal: false` when persistently hidden.

- [ ] **Step 4: Replace the 6-point SwiftUI hover target with AppKit callbacks**

Delete the current `.overlay { Color.clear.frame(width: 6).onHover(...) }`. Configure `SidebarSplitView` with:

```swift
edgeTrackingEnabled: sidebarPresentation.userWantsHidden,
onEdgePointerMove: { x, width in
    sidebarPresentation.pointerMoved(
        x: x,
        width: width,
        position: appliedSidebarPosition
    )
},
onEdgeExit: sidebarPresentation.trackingRegionExited
```

Add `.onChange(of: sidebarPresentation.proximityState)` and route `.revealed` to visible, `.cue/.dormant` to hidden using `.hover(duration: 0.140)` unless Reduce Motion is active. Read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` at the transition boundary, not once at launch.

- [ ] **Step 5: Render the non-interactive 4-point cue**

Add a dedicated leaf view so cue opacity changes do not re-host terminal content:

```swift
private struct SidebarProximityCue: View {
    let edge: SidebarPhysicalEdge
    let visible: Bool
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        Rectangle()
            .fill(Color.aw.focusAccent(accentResolver.accent, terminalBackground: Color.aw.surface.window))
            .frame(width: 4)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.08), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
```

Overlay it on `layoutPolicy.edge`; never insert it into the split or titlebar layout. If the exact `focusAccent` API requires a terminal background not available here, use the existing environment-resolved `Color.aw.accent(accentResolver.accent)` at full opacity—do not invent a new design token in this task.

- [ ] **Step 6: Make explicit actions immediate and clear transient state**

For `Command-Shift-Backslash`, Focus Sidebar, and `applySidebarPosition`:

```swift
sidebarPresentation.invalidateTransientState()
splitProxy.setVisibility?(sidebarPresentation.isSidebarVisible, .immediate)
```

Side change order remains: invalidate transient state and animator, hide peek cards, settle visibility immediately, move the native split, publish the new position/tracker edge.

- [ ] **Step 7: Permit rail/full selection while hidden without revealing**

Remove the `guard sidebarPresentation.permitsWidthChanges else { return }`. Resolve the target from the remembered selection while hidden, update `sidebarWidth`, `sidebarLiveWidth.value`, `lastNonCollapsedSidebarWidth`, and the width stores through `commitSidebarWidth(targetWidth)`, then call `splitProxy.setWidth?(targetWidth)`. The controller's existing hidden branch stores the target in `pendingWidth` without moving the divider. Assert model proximity remains `.dormant` and `userWantsHidden` remains true.

When temporarily revealed, read `sidebarLiveWidth.value` and retain the existing visible rail/full behavior.

- [ ] **Step 8: Run integration and regression suites, then commit**

Run:

```bash
script/format.sh Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarSplitView.swift Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift
./script/swift-test.sh --filter SidebarHoverIntegrationTests
./script/swift-test.sh --filter SidebarPresentationModelTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter KeyboardShortcutCatalogTests
git diff --check
```

Expected: all focused suites pass; no shortcut defaults change; diff check is clean.

Commit: `feat(sidebar): add proximity cue and hidden width toggle`

---

### Task 5: Harden Lifecycle, Regression, and Live Interaction

**Files:**
- Modify: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`
- Modify: `docs/superpowers/specs/2026-07-13-sidebar-hover-refinement-design.md` only if live verification exposes an approved design correction.

**Interfaces:**
- Consumes: all prior task interfaces.
- Produces: no new production interface; this task closes failure-mode and regression coverage.

- [ ] **Step 1: Add lifecycle and input-preservation regression tests**

Add explicit tests for:

```swift
// Inactive/detached invalidation clears cue and reveal immediately.
model.pointerMoved(x: 20, width: 40, position: .left)
model.invalidateTransientState()
#expect(model.proximityState == .dormant)
#expect(!model.isCueVisible)

// A persistent explicit show during a held hover completion wins synchronously.
controller.setSidebarVisible(true, transition: .hover(duration: 0.140), reduceMotion: false)
controller.setSidebarVisible(true, transition: .immediate, reduceMotion: false)
heldHoverCompletion()
#expect(abs(sidebar.view.frame.width - selectedWidth) < 1)
```

Also cover cold launch hidden on both sides, visible divider dragging, remembered expanded width, detail first responder through cue/reveal/hide, narrow-window reveal clamp, position change during a pending grace, and tracker resize using current local bounds.

- [ ] **Step 2: Run focused suites and verify any new test fails for the intended omission**

Run:

```bash
./script/swift-test.sh --filter SidebarPresentationModelTests
./script/swift-test.sh --filter SidebarEdgeTrackingViewTests
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarHoverIntegrationTests
```

Expected before hardening: at least the newly introduced lifecycle/interruption assertion fails for the missing invalidation path; no unrelated failure is accepted.

- [ ] **Step 3: Make only the minimal hardening changes required by RED tests**

Wire `SidebarEdgeTrackingView.onAvailabilityLost` through `SidebarSplitController.onTrackingAvailabilityLost` and `SidebarSplitView.onTrackingAvailabilityLost` to this concrete `ContentView` closure:

```swift
onTrackingAvailabilityLost: {
    sidebarPresentation.invalidateTransientState()
    splitProxy.setVisibility?(false, .immediate)
}
```

In `SidebarSplitController.viewDidLayout`, if bounds change while `isHoverAnimating`, increment `animationGeneration`, clear the animation flag, clamp `pendingWidth` to the new `maxSidebarWidth`, and call `setSidebarVisible(requestedSidebarVisible, transition: .immediate, reduceMotion: true)`. `setSidebarPosition` begins with the same animation cancellation before it reorders panes. Keep keyboard/menu/palette routing unchanged. Do not add a global monitor fallback when tracking is unavailable.

- [ ] **Step 4: Run targeted format and the full automated suite**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift
./script/swift-test.sh
script/format.sh --lint Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift
git diff --check
```

Expected: the complete Swift suite passes; targeted lint and diff check emit no errors.

- [ ] **Step 5: Build and perform live worktree verification**

Run: `./script/build_and_run.sh`

Expected: the development app builds, launches, and stays running.

Verify manually in the development bundle on both left and right:

1. Hide with `Command-Shift-Backslash`; the action is instant.
2. Move inside 40 points: a clear 4-point strip appears without terminal shift.
3. Move to exactly/approximately 16 points: cue remains; move closer: selected rail/full sidebar shifts detail over 140ms.
4. Move away and rapidly reverse several times: no flicker, stale reopen, or partial width.
5. Click, drag-select, scroll, and contextual-click terminal content inside the 40-point zone; terminal behavior is unchanged.
6. Type continuously during cue and animation; first responder remains the terminal.
7. While hidden press `Command-Backslash`; nothing reveals. Hover again and confirm the opposite rail/full width appears.
8. Resize during reveal and switch position while cue/reveal is active; old-side cue disappears and layout settles on the new edge.
9. Enable Reduce Motion in System Settings; hover movement becomes immediate while the cue remains legible.
10. Quit while persistently hidden, relaunch, and confirm hidden cold launch remains stable.

- [ ] **Step 6: Run preflight, refresh overlap, and commit verification hardening**

Run:

```bash
./script/preflight.sh
gh pr list --base main --state open --json number,title,author,files
git diff --name-only origin/main...HEAD
git status --short
```

Expected: preflight passes, or the already documented Bash 3 `mapfile: command not found` infrastructure failure is reported with all preceding guards passing. Report every open PR touching any changed file before publication. Working tree is clean except for the intended task changes before commit.

Commit: `test(sidebar): harden hover refinement regressions`

---

## Subagent-Driven Execution Notes

- Dispatch one fresh implementation subagent per task in order; Tasks 2–4 share central files and must not write concurrently.
- After each task, dispatch a spec-compliance reviewer, then a code-quality reviewer. Fix findings before starting the next task.
- Give every worker this plan path, the approved refinement spec, the original sidebar presentation spec, the task number, and the current commit SHA.
- Each worker must preserve user changes, show the focused RED result before production edits, run the task's GREEN commands, and commit only its task.
- After Task 5, run one whole-branch review against `origin/main...HEAD`; implementation is not publication-ready until that review and live verification are clean.
