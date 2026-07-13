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
- A right-positioned sidebar aligns the complete existing awesoMux icon-and-title lockup to the sidebar's trailing edge with the same 10-point outer titlebar padding; icon-before-text order is unchanged and left positioning is unchanged.
- Use targeted `script/format.sh` only on intentionally changed Swift files.
- Follow test-driven development: run each focused test and observe RED before production implementation.

## File Responsibility Map

- `Sources/awesoMux/Views/SidebarPresentationModel.swift`: owns `ProximityState`, exact boundary policy, grace scheduling, and generation invalidation.
- `Sources/awesoMux/Views/SidebarEdgeTrackingView.swift`: pass-through AppKit tracking surface and local left/right distance conversion.
- `Sources/awesoMux/Views/SidebarSplitController.swift`: hosts the split plus tracking surface, updates tracking geometry, and performs/cancels hover divider animations.
- `Sources/awesoMux/Views/SidebarSplitView.swift`: carries tracking callbacks and explicit/hover visibility commands across the SwiftUI/AppKit boundary.
- `Sources/awesoMux/Views/SidebarSplitSupport.swift`: defines the typed proxy transition API and pure titlebar lockup layout policy used by `ContentView`.
- `Sources/awesoMux/Views/ContentView.swift`: renders the 4-point cue, routes proximity events, permits hidden width selection, and keeps explicit actions instantaneous.
- `Sources/awesoMux/Views/AppTitlebarMetrics.swift`: names the existing 10-point titlebar lockup padding shared by left/right placement.
- `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`: boundary, state-machine, grace, lifecycle, and stale-token coverage.
- `Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift`: local geometry, resize, pass-through input, and responder preservation.
- `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`: animation policy, interruption, side symmetry, resize, Reduce Motion, focus, and persistence guards.
- `Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift`: structural regression proving representable updates cannot enact runtime visibility.
- `Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift`: pure orchestration policy for hidden width toggles and explicit-versus-hover transitions.
- `Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift`: left/right titlebar lockup alignment, padding, item order, and presentation-state invariants.
- `Tests/awesoMuxTests/BrandmarkStructureTests.swift`: structural regression pinning icon-before-text order inside the unchanged lockup.

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
    var setVisibility: ((Bool, SidebarSplitTransition, Bool) -> Void)?
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

`setVisibility` receives **visible**, not hidden, to avoid double-negatives at call sites. Its final argument is the current Reduce Motion value, sampled at the runtime transition boundary. `.hover(duration: 0.140)` is used only for proximity transitions; every other caller uses `.immediate`.

Runtime visibility has exactly one enactor:

```text
initial construction/restoration -> SidebarSplitView.makeNSViewController (immediate)
runtime visibility changes       -> SidebarSplitProxy.setVisibility only
updateNSViewController           -> callbacks, position, tracker; never visibility
```

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

`sidebarPointerPresent` is authoritative while true: `pointerMoved` may promote `.dormant/.cue` to `.revealed`, but it must not downgrade `.revealed` to `.cue` or `.dormant` while the pointer is inside the revealed sidebar. Collapse grace begins only after both the tracker/reveal zone and sidebar are absent.

Implement that arbitration at the top of the distance transition:

```swift
if sidebarPointerPresent {
    transition(to: .revealed)
    return
}
```

`sidebarPointerChanged(true)` cancels grace and promotes to `.revealed`; `sidebarPointerChanged(false)` schedules grace only when the latest tracker classification is not `.revealed`.

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

Add both overlap event orders so AppKit/SwiftUI delivery order cannot change behavior:

```swift
model.pointerMoved(x: 15, width: 40, position: .left)
model.sidebarPointerChanged(true)
model.pointerMoved(x: 30, width: 40, position: .left)
#expect(model.proximityState == .revealed)

model.invalidateTransientState()
model.sidebarPointerChanged(true)
model.pointerMoved(x: 30, width: 40, position: .left)
#expect(model.proximityState == .revealed)
```

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

Create a flipped, accessibility-hidden view with a rebuilt `.mouseEnteredAndExited`, `.mouseMoved`, `.activeInKeyWindow`, `.inVisibleRect` tracking area. Entry and movement call the same coordinate-report helper so entering the band produces a cue/reveal without requiring a second movement:

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
        report(event)
    }

    override func mouseEntered(with event: NSEvent) {
        report(event)
    }

    private func report(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onPointerMove?(local.x, bounds.width)
    }

    override func mouseExited(with event: NSEvent) { onExit?() }
}
```

`distance` clamps non-finite/negative input and mirrors `x` against the supplied live width. Override `viewDidMoveToWindow()` to replace a scoped `NSWindow.didResignKeyNotification` observer for the current window; call `onAvailabilityLost` when the view detaches or that window resigns key. Remove the observer in `deinit`. Add a synthetic local-event test proving `mouseEntered` reports immediately, and that `mouseMoved` uses the identical helper result.

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
var onTrackingAvailabilityLost: (() -> Void)?
```

Forward tracker events without touching first responder. Add `setEdgeTrackingEnabled(_:)`; disabling removes/hides tracking immediately and emits `onEdgeExit` once.

- [ ] **Step 6: Wire callbacks through `SidebarSplitView` and verify**

Add representable properties `edgeTrackingEnabled`, `onEdgePointerMove`, `onEdgeExit`, and `onTrackingAvailabilityLost`; assign them in both `makeNSViewController` and `updateNSViewController`. The availability callback must survive ordinary SwiftUI updates exactly like the movement callbacks.

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
- Create: `Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift`

**Interfaces:**
- Consumes: selected width already held in `pendingWidth`/`lastExpandedPaneWidth` and semantic left/right divider math.
- Produces: `SidebarSplitTransition`, `SidebarSplitController.setSidebarVisible(_:transition:reduceMotion:)`, `SidebarSplitProxy.setVisibility`.
- Preserves: existing `setSidebarHidden(_:)` as an immediate compatibility wrapper until all callers migrate in Task 4.
- Ownership: `SidebarSplitController` is the sole runtime visibility enactor. `SidebarSplitView.makeNSViewController` performs initial restoration only; `updateNSViewController` must never apply visibility.

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

Add a delegate-policy test that places an in-flight hover animation at widths strictly between `SidebarWidthPolicy.collapsedWidth` and `SidebarWidthPolicy.railThreshold` and asserts `constrainSplitPosition` returns the proposed coordinate unchanged on both sides. Add a control assertion that the same coordinate still snaps when no hover animation is active.

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
    if case .hover = transition,
        isHoverAnimating,
        requestedSidebarVisible == visible,
        activeHoverTargetWidth == targetWidth(forVisible: visible)
    {
        return
    }
    cancelHoverAnimation()
    let target = targetWidth(forVisible: visible)
    if abs(sidebarPaneWidth - target) < 0.5 {
        normalizeSidebarVisibility(visible)
        return
    }
    switch transition {
    case .immediate:
        applySidebarVisibilityImmediately(visible)
    case let .hover(duration) where !reduceMotion:
        animateSidebarVisibility(visible, duration: duration)
    case .hover:
        applySidebarVisibilityImmediately(visible)
    }
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

During `isHoverAnimating`, `splitView(_:constrainSplitPosition:ofSubviewAt:)` returns `proposedPosition` unchanged so the divider traverses the rail/full dead zone smoothly. Clamp the final target before animation and keep the normal min/max/terminal-floor policy; bypass only the dead-zone snap, not target safety.

- [ ] **Step 5: Add failing interruption and resize tests**

Inject an animation driver seam so tests can hold completions. Assert:

- reveal begins `0 -> 300`;
- simulated midpoint width `120`, then hide begins `120 -> 0` rather than `300 -> 0`;
- completing the old reveal token cannot reopen after the hide;
- resizing clamps both current and target width, cancels invalid work, and settles at the newest requested state;
- no `onCommitWidth` fires and no width preference callback sees `0` or an intermediate value;
- `.immediate` during animation invalidates the completion and settles synchronously.
- a repeated request matching `requestedSidebarVisible` during the active matching animation is a no-op and does not increment the generation or invoke the animation runner again;
- a request whose target equals `sidebarPaneWidth` normalizes synchronously and never invokes the animation runner.

Use a protocol-free closure seam:

```swift
typealias AnimationRunner = (
    TimeInterval, @escaping () -> Void, @escaping () -> Void
) -> Void
```

Production runs the changes in `NSAnimationContext`; tests capture both closures.

- [ ] **Step 6: Wire proxy and preserve initial hidden restoration**

Add `setVisibility` to `SidebarSplitProxy`. Rename the representable input to `initiallyHidden` to make its one-shot role unmistakable. In `SidebarSplitView.makeNSViewController`, apply `initiallyHidden` immediately before width restoration and bind:

```swift
proxy.setVisibility = { [weak controller] visible, transition, reduceMotion in
    controller?.setSidebarVisible(
        visible,
        transition: transition,
        reduceMotion: reduceMotion
    )
}
```

`updateNSViewController` updates terminal minimum, callbacks, position, tracking enablement, and hosted root views only. It must contain no call to `setSidebarHidden`, `setSidebarVisible`, or any other visibility setter. Do not animate cold launch.

Add a structural ownership regression that extracts `updateNSViewController` from `SidebarSplitView.swift` and fails if a visibility setter returns:

```swift
@Test("representable updates never enact runtime visibility")
func updatePathHasNoVisibilitySetter() throws {
    let testURL = URL(fileURLWithPath: #filePath)
    let root = testURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitView.swift"),
        encoding: .utf8
    )
    let update = try #require(source.split(separator: "func updateNSViewController", maxSplits: 1).last)
    let body = try #require(update.split(separator: "\n    }", maxSplits: 1).first)
    #expect(!body.contains("setSidebarHidden"))
    #expect(!body.contains("setSidebarVisible"))
    #expect(!body.contains("setVisibility"))
}
```

In controller tests, invoke `proxy.setVisibility?(true, .hover(duration: 0.140), false)` through the installed closure and assert the injected animation runner receives exactly one request with duration `0.140`; no `.immediate` request is recorded.

- [ ] **Step 7: Run, format, and commit animation support**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift
./script/swift-test.sh --filter SidebarSplitControllerTests
./script/swift-test.sh --filter SidebarSplitVisibilityOwnershipTests
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

Add `.onChange(of: sidebarPresentation.proximityState)` and route `.revealed` to visible, `.cue/.dormant` to hidden through the sole runtime proxy path. Read Reduce Motion at that boundary, not once at launch:

```swift
.onChange(of: sidebarPresentation.proximityState) { _, state in
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    splitProxy.setVisibility?(
        state == .revealed,
        .hover(duration: 0.140),
        reduceMotion
    )
}
```

Pass `initiallyHidden: !sidebarPresentation.isSidebarVisible` to construction, but do not bind runtime visibility to a representable update property. A proximity rerender may update callbacks/cue/root views; only the `.onChange` proxy call enacts the runtime divider transition.

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
splitProxy.setVisibility?(sidebarPresentation.isSidebarVisible, .immediate, true)
```

The final `true` deliberately disables motion for explicit actions independent of the current accessibility preference. For pointer transitions, sample `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` immediately before the proxy call and pass that current value as the third argument.

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

### Task 5: Align the Right-Side Title Lockup

**Files:**
- Modify: `Sources/awesoMux/Views/AppTitlebarMetrics.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/AppTitlebarMetricsTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift`
- Create: `Tests/awesoMuxTests/BrandmarkStructureTests.swift`

**Interfaces:**
- Consumes: `AppearanceConfig.SidebarPosition`, existing `Brandmark`, existing sidebar live width/visibility.
- Produces: `AppTitlebarMetrics.lockupPadding: CGFloat == 10`, `AppTitlebarLockupAlignment`, and `SidebarPresentationLayoutPolicy.titlebarLockupAlignment`.
- Preserves: `Brandmark` internals and its icon-before-text `HStack`; existing left-sidebar padding, thresholds, and alignment; no new preference or animation.

- [ ] **Step 1: Write failing titlebar alignment, padding, and order tests**

Extend the pure layout-policy suite:

```swift
@Test("title lockup alignment follows sidebar position")
func titleLockupAlignment() {
    #expect(
        SidebarPresentationLayoutPolicy(position: .left).titlebarLockupAlignment
            == .leading
    )
    #expect(
        SidebarPresentationLayoutPolicy(position: .right).titlebarLockupAlignment
            == .trailing
    )
}

@Test("title lockup contract is stable across presentation states")
func titleLockupPresentationMatrix() {
    let states: [(width: CGFloat, persistent: Bool, temporary: Bool)] = [
        (SidebarWidthPolicy.collapsedWidth, true, false),
        (SidebarWidthPolicy.expandedWidth, true, false),
        (SidebarWidthPolicy.collapsedWidth, false, true),
        (SidebarWidthPolicy.expandedWidth, false, true),
    ]
    for state in states {
        _ = state // Width/visibility decide whether the existing lockup renders, not its ordering.
        let policy = SidebarPresentationLayoutPolicy(position: .right)
        #expect(policy.titlebarLockupAlignment == .trailing)
        #expect(policy.titlebarLockupOuterPadding == 10)
    }
}
```

Extend `AppTitlebarMetricsTests`:

```swift
#expect(AppTitlebarMetrics.lockupPadding == 10)
```

Add `import AwesoMuxCore` to `SidebarPresentationLayoutTests.swift` for the rail/full constants. Create a structural `Brandmark` regression so item order is checked against the real lockup rather than duplicated in a policy enum:

```swift
@Test("brandmark keeps icon before title text")
func iconPrecedesTitle() throws {
    let testURL = URL(fileURLWithPath: #filePath)
    let root = testURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/Brandmark.swift"),
        encoding: .utf8
    )
    let icon = try #require(source.range(of: "ShrugMark("))
    let title = try #require(source.range(of: "Text(\"awesoMux\")"))
    #expect(icon.lowerBound < title.lowerBound)
}
```

The presentation matrix explicitly covers persistent rail, persistent full, temporary rail, and temporary full. It does not create separate layout state because position alone owns alignment.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
./script/swift-test.sh --filter SidebarPresentationLayoutTests
./script/swift-test.sh --filter AppTitlebarMetricsTests
./script/swift-test.sh --filter BrandmarkStructureTests
```

Expected: layout/metrics compilation fails because `AppTitlebarLockupAlignment`, `titlebarLockupAlignment`, `titlebarLockupOuterPadding`, and `lockupPadding` do not exist. `BrandmarkStructureTests` passes against the unchanged existing lockup and remains a regression guard during implementation.

- [ ] **Step 3: Add the minimal pure layout contract**

In `AppTitlebarMetrics.swift` name the existing literal rather than changing its value:

```swift
static let lockupPadding: CGFloat = 10
```

In `SidebarSplitSupport.swift` add:

```swift
enum AppTitlebarLockupAlignment: Equatable {
    case leading
    case trailing
}

extension SidebarPresentationLayoutPolicy {
    var titlebarLockupAlignment: AppTitlebarLockupAlignment {
        position == .left ? .leading : .trailing
    }

    var titlebarLockupOuterPadding: CGFloat { AppTitlebarMetrics.lockupPadding }
}
```

Do not add width, persistent/temporary state, or animation to this policy: those inputs decide visibility/size elsewhere and must not change horizontal alignment or item order.

- [ ] **Step 4: Run focused tests and verify the policy is GREEN**

Run:

```bash
./script/swift-test.sh --filter SidebarPresentationLayoutTests
./script/swift-test.sh --filter AppTitlebarMetricsTests
./script/swift-test.sh --filter BrandmarkStructureTests
```

Expected: all three suites pass.

- [ ] **Step 5: Apply the policy to the complete existing lockup**

In `AppTitlebarView.sidebarColumn`, extract only the existing conditional `Brandmark` selection into a helper; do not edit `Brandmark.swift`:

```swift
@ViewBuilder
private var titleLockup: some View {
    if sidebarWidth >= Self.brandWithTextMinimumWidth {
        Brandmark().allowsHitTesting(false)
    } else if sidebarWidth >= Self.brandIconMinimumWidth {
        Brandmark(showsText: false).allowsHitTesting(false)
    }
}
```

Place that whole helper before or after the single spacer according to position:

```swift
HStack(spacing: 0) {
    if layoutPolicy.titlebarLockupAlignment == .trailing {
        Spacer(minLength: 0)
        titleLockup
    } else {
        titleLockup
        Spacer(minLength: 0)
    }
}
```

Keep the existing left leading calculation byte-for-byte equivalent. Replace only the existing magic trailing `10` with `AppTitlebarMetrics.lockupPadding`, then use that same value as the right sidebar's physical trailing inset. Set the frame alignment from the policy:

```swift
.frame(
    width: sidebarWidth,
    alignment: layoutPolicy.titlebarLockupAlignment == .trailing ? .trailing : .leading
)
```

Do not reverse `Brandmark` itself: `ShrugMark` remains the first child and `Text("awesoMux")` remains second. Hidden state still produces zero titlebar sidebar width; persistent and temporary reveals reuse the same `AppTitlebarView` path.

- [ ] **Step 6: Format and run focused/full titlebar checks**

Run:

```bash
script/format.sh Sources/awesoMux/Views/AppTitlebarMetrics.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/AppTitlebarMetricsTests.swift Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift Tests/awesoMuxTests/BrandmarkStructureTests.swift
./script/swift-test.sh --filter SidebarPresentationLayoutTests
./script/swift-test.sh --filter AppTitlebarMetricsTests
./script/swift-test.sh --filter BrandmarkStructureTests
./script/swift-test.sh --filter SidebarHoverIntegrationTests
./script/swift-test.sh --filter SidebarSplitControllerTests
git diff --check
```

Expected: all focused suites pass, left-side assertions remain unchanged, and diff check emits no output.

- [ ] **Step 7: Build and capture the titlebar screenshot matrix**

Run: `./script/build_and_run.sh`

Expected: the development app builds, launches, and remains running.

Capture focused window screenshots with the macOS screenshot crosshair after arranging each named state:

```bash
screencapture -i /tmp/awesomux-title-left-full-persistent.png
screencapture -i /tmp/awesomux-title-left-rail-persistent.png
screencapture -i /tmp/awesomux-title-right-full-persistent.png
screencapture -i /tmp/awesomux-title-right-rail-persistent.png
screencapture -i /tmp/awesomux-title-right-full-temporary.png
screencapture -i /tmp/awesomux-title-right-rail-temporary.png
```

Expected visual evidence:

- both left images match the pre-change placement and padding;
- right full images show the entire `icon → awesoMux` lockup anchored 10 points from the physical right edge, never text-before-icon;
- right rail images preserve the existing narrow-width suppression (no clipped or misplaced lockup remnant); if a future width crosses the existing icon-only threshold, that icon uses the same trailing inset;
- persistent and temporary images for a given width have identical titlebar alignment—the hover animation moves the column width but does not animate or independently reposition the lockup;
- use representative narrow and wide windows and preserve at least one focused left/right full comparison for the eventual visible-UI PR body.

Do not add `/tmp` screenshots to git.

- [ ] **Step 8: Commit the isolated titlebar change**

Commit: `fix(sidebar): align right title lockup`

---

### Task 6: Harden Lifecycle, Regression, and Live Interaction

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

Also add an end-to-end availability test: enter reveal, start a held animation, call the tracker/controller `onAvailabilityLost`, and assert model state is `.dormant`, the held completion is stale, sidebar width is `0`, and no cue remains. Cover cold launch hidden on both sides, visible divider dragging, remembered expanded width, detail first responder through cue/reveal/hide, narrow-window reveal clamp, position change during a pending grace, and tracker resize using current local bounds.

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
    splitProxy.setVisibility?(false, .immediate, true)
}
```

This is end-to-end invalidation, not only cue cleanup: detachment or key-window loss cancels the model grace generation, cancels the controller animation generation through the immediate proxy request, and settles the persistently hidden sidebar at zero immediately.

In `SidebarSplitController.viewDidLayout`, if bounds change while `isHoverAnimating`, increment `animationGeneration`, clear the animation flag, clamp `pendingWidth` to the new `maxSidebarWidth`, and call `setSidebarVisible(requestedSidebarVisible, transition: .immediate, reduceMotion: true)`. `setSidebarPosition` begins with the same animation cancellation before it reorders panes. Keep keyboard/menu/palette routing unchanged. Do not add a global monitor fallback when tracking is unavailable.

- [ ] **Step 4: Run targeted format and the full automated suite**

Run:

```bash
script/format.sh Sources/awesoMux/Views/AppTitlebarMetrics.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/AppTitlebarMetricsTests.swift Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift Tests/awesoMuxTests/BrandmarkStructureTests.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift Tests/awesoMuxTests/SidebarEdgeTrackingViewTests.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift Tests/awesoMuxTests/SidebarSplitVisibilityOwnershipTests.swift Tests/awesoMuxTests/SidebarHoverIntegrationTests.swift
./script/swift-test.sh
script/format.sh --lint Sources/awesoMux/Views/AppTitlebarMetrics.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Sources/awesoMux/Views/SidebarEdgeTrackingView.swift Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/ContentView.swift
git diff --check
```

Expected: the complete Swift suite passes; targeted lint and diff check emit no errors.

- [ ] **Step 5: Build and perform live worktree verification**

Run: `./script/build_and_run.sh`

Expected: the development app builds, launches, and stays running.

Verify manually in the development bundle on both left and right:

1. Hide with `Command-Shift-Backslash`; the action is instant.
2. Move inside 40 points: a clear 4-point strip appears without terminal shift.
3. Enter the 40-point band and stop moving immediately: the cue appears from `mouseEntered`, without a second movement.
4. Move to exactly/approximately 16 points: cue remains; move closer: selected rail/full sidebar shifts detail over 140ms.
5. Watch the reveal/hide traverse widths between the collapsed rail and full threshold smoothly on both left and right; there must be no dead-zone snap or jump. Repeat once with the rail selected and once with the full sidebar selected.
6. Rest inside the revealed sidebar while the edge tracker also reports movement: it remains revealed without flicker or collapse.
7. Move away and rapidly reverse several times, including repeating the same movement within one target state: no animation restarts, flicker, stale reopen, or partial width.
8. Click, drag-select, scroll, and contextual-click terminal content inside the 40-point zone on both sides; terminal behavior is unchanged.
9. Type continuously during cue and animation; first responder remains the terminal.
10. While hidden press `Command-Backslash`; nothing reveals. Hover again and confirm the opposite rail/full width appears.
11. Resize during reveal and switch position while cue/reveal is active; old-side cue disappears and layout settles on the new edge.
12. Deactivate or detach the development window during cue/reveal; cue and sidebar settle hidden immediately and do not resurrect on stale completion.
13. Enable Reduce Motion in System Settings; hover movement becomes immediate while the cue remains legible.
14. Quit while persistently hidden, relaunch, and confirm hidden cold launch remains stable.
15. At representative narrow and wide window sizes, compare the saved left/right titlebar screenshots: left is unchanged; right anchors the whole lockup to the trailing edge with matching 10-point padding.
16. Confirm full right-side persistent and hover-revealed screenshots retain `icon → awesoMux` order; 60-point rail screenshots retain the existing hidden-lockup treatment without clipping or a misplaced remnant.
17. Switch rail/full while hidden, then hover reveal: the title lockup immediately uses the selected width but remains trailing-aligned throughout the temporary presentation.

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

- Dispatch one fresh implementation subagent per task in order; Tasks 2–5 share central files and must not write concurrently.
- After each task, dispatch a spec-compliance reviewer, then a code-quality reviewer. Fix findings before starting the next task.
- Give every worker this plan path, the approved refinement spec, the original sidebar presentation spec, the task number, and the current commit SHA.
- Each worker must preserve user changes, show the focused RED result before production edits, run the task's GREEN commands, and commit only its task.
- After Task 6, run one whole-branch review against `origin/main...HEAD`; implementation is not publication-ready until that review, titlebar screenshot comparison, and live verification are clean.
