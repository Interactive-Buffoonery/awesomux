# Hidden Sidebar Edge Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hidden-sidebar proximity glow with a solid directional edge tab while deleting the obsolete distance-intensity machinery.

**Architecture:** Keep the existing AppKit tracking region and `.dormant` / `.cue` / `.revealed` model as the only interaction state. A small pure policy selects no tab, an attention strip, or the ordinary cue tab; `SessionDetailView` renders that cue inside terminal or empty content so actionable top/bottom chrome stays above it, while the native full-sidebar overlay remains unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, swift-testing

## Global Constraints

- The attraction field remains the sidebar-side one third of content width.
- Full sidebar reveal remains at or inside 40pt and overlays Ghostty without moving it.
- `.cue` displays the directional tab; `.revealed` resolves to no tab because the full sidebar replaces it.
- The cue is a solid highlight-color strip spanning `TerminalPaneView` below any top banner and above the bottom action/path bar, plus a vertically centered directional chevron; it does not brighten, widen, or pulse with distance.
- The cue slides inward about 10pt; Reduce Motion removes translation without changing state transitions.
- Hidden attention outside the attraction field is a static needs-attention strip with no chevron.
- The edge tab is non-clickable, non-focusable, accessibility-hidden, and excluded from hit testing.
- Left/right sidebar positions mirror the strip, animation direction, and chevron.
- Preserve the corrected tracking-area lifecycle and narrow-window overlay sizing behavior.
- Preserve the window-local mouse-moved delivery fallback for the one-third attraction field, and restore each owning window's prior `acceptsMouseMovedEvents` value when the monitor stops or transfers.
- Contrast-tune cue and attention colors against the live terminal background (or `Color.aw.surface.terminal` in the empty detail), not the app window surface.
- Preserve the approved titlebar split: the sidebar body slides while the brand lockup fades in place; a 60-point rail reserves its actual width and partially presented branding stays out of accessibility.
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

Replace the strength tests in `SidebarAttentionCuePolicyTests.swift` with a table that requires `.cue` to display the cue, `.revealed` to display no tab, attention to appear only while dormant and persistently hidden, and no tab otherwise:

```swift
@Test("edge tab style follows hidden proximity and attention")
func edgeTabStyle() {
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .cue, hasAttention: false) == .cue)
    #expect(SidebarEdgeTabPolicy.resolve(
        isPersistentlyHidden: true, proximity: .revealed, hasAttention: true) == nil)
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
        case .cue:
            return .cue
        case .revealed:
            return nil
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

Implement `SidebarEdgeTab` in place of `SidebarProximityCue` using existing tokens. Its rendered geometry is a 7pt content-height edge strip plus a centered 28×52pt rounded tab for `.cue`; `.attention` renders only the 7pt strip. The later footer-inset refinement constrains that content height above the measured terminal action/path bar. Use `chevron.right` for the left sidebar and `chevron.left` for the right sidebar. Align the tab to the configured edge, keep the whole overlay pass-through and accessibility-hidden, and do not add gestures.

The ordinary cue uses `Color.aw.focusAccent(accentResolver.accent, terminalBackground: terminalBackground)`; attention passes `Color.aw.status.needs` through `Color.aw.contrastTuned(_:terminalBackground:)` against the same content surface. While the full overlay animates, use `currentOverlayVisibleFraction` to reduce the tab opacity from 1 to 0 so the sidebar replaces it. Outside an overlay transition, render directly without a `TimelineView`. Animate the tab's presence with `.easeOut(duration: 0.12)` and a hidden directional offset of -10pt on the left or +10pt on the right; when `accessibilityReduceMotion` is true, use zero offset and no transition animation.

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

---

### Task 2: Keep the edge cue above the terminal action bar

> Dogfood-history task: Task 3 replaces this measured footer inset with structural terminal-content ownership and removes the temporary state added here.

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift`

**Interfaces:**
- Consumes: `SessionDetailView.onFooterHeightChange`, the dynamically measured `TerminalPathBarView` height, and the existing app-level `onTerminalFooterHeightChange` callback.
- Produces: `ContentView.terminalFooterHeight`, used only as the decorative `SidebarEdgeTab` bottom inset.

- [ ] **Step 1: Write the failing source-contract assertions**

Extend `SidebarAttentionCuePolicyTests.edgeTabSourceContract()` after extracting the `detail` closure:

```swift
#expect(detail.contains("terminalFooterHeight = height"))
#expect(detail.contains(".padding(.bottom, terminalFooterHeight)"))
```

Keep the existing assertions that the tab belongs to the detail host and remains outside the split-level overlay.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
./script/swift-test.sh --filter SidebarAttentionCuePolicyTests
```

Expected: FAIL because `ContentView` neither retains the measured footer height nor applies it to `SidebarEdgeTab`.

- [ ] **Step 3: Retain and forward the dynamic footer height**

Add content-local state beside the other sidebar presentation state:

```swift
@State private var terminalFooterHeight: CGFloat = 0
```

Replace the direct `SessionDetailView` callback argument with a closure that retains the measurement and preserves the app-level callback:

```swift
onFooterHeightChange: { height in
    terminalFooterHeight = height
    onTerminalFooterHeightChange(height)
},
```

- [ ] **Step 4: Inset only the decorative edge cue**

Apply the dynamic bottom inset directly to `SidebarEdgeTab`:

```swift
SidebarEdgeTab(
    style: edgeTabStyle,
    position: sidebarPosition
)
.padding(.bottom, terminalFooterHeight)
```

Do not change `SidebarSplitController`, `SidebarEdgeTrackingView`, or the native overlay clip geometry: the attraction field and the fully revealed sidebar must continue spanning the split host.

- [ ] **Step 5: Run focused verification and make it GREEN**

Run:

```bash
./script/swift-test.sh --filter 'SidebarAttentionCuePolicyTests|SidebarHoverArchitectureTests|SidebarOverlayHostControllerTests'
```

Expected: PASS; the source contract proves the cue consumes the dynamic footer measurement while overlay-host geometry remains unchanged.

- [ ] **Step 6: Format and inspect the scoped diff**

Run:

```bash
./script/format.sh Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift
./script/format.sh --lint
git diff --check
```

Expected: all commands exit 0. Do not commit yet; this refinement remains part of the pending dogfood batch and must pass the required final reviews before commit/PR.

---

### Task 3: Move cue ownership into terminal content

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Sources/awesoMux/Views/SessionDetailView.swift`
- Modify: `Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift`
- Modify: `Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift`

**Interfaces:**
- Consumes: `SidebarEdgeTabPolicy.Style?`, `AppearanceConfig.SidebarPosition`, `SessionDetailView.onFooterHeightChange`, `TerminalPaneView`, and `EmptyWorkspaceView`.
- Produces: `SessionDetailView.edgeTabStyle` and `SessionDetailView.sidebarPosition`; `SidebarEdgeTab` renders only inside the terminal/empty content regions.

- [x] **Step 1: Write failing ownership-contract tests**

Update `SidebarAttentionCuePolicyTests.edgeTabSourceContract()` to read both `ContentView.swift` and `SessionDetailView.swift`, then require structural ownership rather than a measured footer inset:

```swift
let contentSource = try String(
    contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
    encoding: .utf8
)
let detailSource = try String(
    contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SessionDetailView.swift"),
    encoding: .utf8
)
let terminalRegion = try #require(
    detailSource.split(separator: "TerminalPaneView(", maxSplits: 1).last?
        .split(separator: "TerminalPathBarView(", maxSplits: 1).first
)
let emptyRegion = try #require(
    detailSource.split(separator: "EmptyWorkspaceView(", maxSplits: 1).last?
        .split(separator: "private enum EmptyWorkspaceMode", maxSplits: 1).first
)

#expect(contentSource.contains("edgeTabStyle: edgeTabStyle"))
#expect(contentSource.contains("sidebarPosition: sidebarPosition"))
#expect(contentSource.contains("onFooterHeightChange: onTerminalFooterHeightChange"))
#expect(!contentSource.contains("@State private var terminalFooterHeight"))
#expect(!contentSource.contains(".padding(.bottom, terminalFooterHeight)"))
#expect(terminalRegion.contains("SidebarEdgeTab("))
#expect(terminalRegion.contains(".overlay(alignment: sidebarPosition == .left ? .leading : .trailing)"))
#expect(emptyRegion.contains("SidebarEdgeTab("))
#expect(detailSource.contains("onFooterHeightChange(height)"))
#expect(detailSource.contains("private struct SidebarEdgeTab"))
#expect(
    detailSource.contains(
        "Color.aw.backgroundIsDark(color) ? Color.white : Color.black"
    )
)
```

Update `SidebarHoverArchitectureTests.edgeTabRenderingContract()` so its `content` string reads `Sources/awesoMux/Views/SessionDetailView.swift`; keep every existing geometry, contrast, animation, hit-testing, and accessibility assertion unchanged.

- [x] **Step 2: Run focused tests and verify RED**

Run:

```bash
./script/swift-test.sh --filter 'SidebarAttentionCuePolicyTests|SidebarHoverArchitectureTests'
```

Expected: FAIL because the cue still belongs to the outer `ContentView` detail overlay, the temporary footer state still exists, and `SessionDetailView` does not yet own `SidebarEdgeTab`.

- [x] **Step 3: Pass cue state into `SessionDetailView` and remove the temporary footer workaround**

In the `ContentView` call, add the two values and restore the original direct footer callback:

```swift
SessionDetailView(
    session: sessionStore.selectedSession,
    sessionStore: sessionStore,
    ghosttyRuntime: ghosttyRuntime,
    onRenameWorkspace: onRenameWorkspace,
    onManagedSSHWorkspaceOffer: onManagedSSHWorkspaceOffer,
    onReopenClosedWorkspace: onReopenClosedWorkspace,
    onOpenSelectedWorkspaceInIDE: onOpenSelectedWorkspaceInIDE,
    onOpenSelectedWorkspaceInIDEWithApp: onOpenSelectedWorkspaceInIDEWithApp,
    onFooterHeightChange: onTerminalFooterHeightChange,
    hasRecoveryWarning: hasRecoveryWarning,
    edgeTabStyle: edgeTabStyle,
    sidebarPosition: sidebarPosition
)
```

Delete `@State private var terminalFooterHeight`, delete the `SidebarEdgeTab` overlay currently attached to `SessionDetailView` in `ContentView`, and remove the `SidebarEdgeTab` type from `ContentView.swift`.

- [x] **Step 4: Host the unchanged cue on terminal and empty content**

Add these stored properties to `SessionDetailView`:

```swift
let edgeTabStyle: SidebarEdgeTabPolicy.Style?
let sidebarPosition: AppearanceConfig.SidebarPosition
```

Attach the cue directly to `TerminalPaneView` after its existing initializer:

```swift
.overlay(alignment: sidebarPosition == .left ? .leading : .trailing) {
    SidebarEdgeTab(
        style: edgeTabStyle,
        position: sidebarPosition,
        terminalBackground: Color(nsColor: ghosttyRuntime.terminalBackgroundColor)
    )
}
```

Attach the same overlay to `EmptyWorkspaceView` after its existing background/frame modifiers so hidden-sidebar discovery remains available without a selected session:

```swift
.overlay(alignment: sidebarPosition == .left ? .leading : .trailing) {
    SidebarEdgeTab(
        style: edgeTabStyle,
        position: sidebarPosition,
        terminalBackground: Color.aw.surface.terminal
    )
}
```

Move the existing edge-tab type into `SessionDetailView.swift` unchanged except for its new file location:

```swift
private struct SidebarEdgeTab: View {
    let style: SidebarEdgeTabPolicy.Style?
    let position: AppearanceConfig.SidebarPosition
    let terminalBackground: Color
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = style == .attention
            ? Color.aw.contrastTuned(Color.aw.status.needs, terminalBackground: terminalBackground)
            : Color.aw.focusAccent(accentResolver.accent, terminalBackground: terminalBackground)
        let hiddenOffset: CGFloat = position == .left ? -10 : 10
        return ZStack(alignment: position == .left ? .leading : .trailing) {
            Rectangle()
                .fill(color)
                .frame(width: 7)
            if style == .cue {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .frame(width: 28, height: 52)
                    .overlay {
                        if position == .left {
                            Image(systemName: "chevron.right")
                        } else {
                            Image(systemName: "chevron.left")
                        }
                    }
                    .foregroundStyle(
                        Color.aw.backgroundIsDark(color) ? Color.white : Color.black
                    )
            }
        }
        .frame(width: 28, alignment: position == .left ? .leading : .trailing)
        .frame(maxHeight: .infinity, alignment: position == .left ? .leading : .trailing)
        .opacity(style == nil ? 0 : 1)
        .offset(x: style == nil && !reduceMotion ? hiddenOffset : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: style)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

Do not alter `NeedsInputBar`, `BridgePermissionPromptView`, `TerminalPathBarView`, `SidebarSplitController`, or `SidebarEdgeTrackingView`. Their existing sibling/host placement supplies the desired hierarchy.

- [x] **Step 5: Run focused verification and make it GREEN**

Run:

```bash
./script/swift-test.sh --filter 'SidebarAttentionCuePolicyTests|SidebarHoverArchitectureTests|SidebarOverlayHostControllerTests'
```

Expected: PASS. The ownership contract proves both session and empty-state cue placement; the unchanged overlay-host tests prove native full-sidebar geometry remains intact.

- [x] **Step 6: Format and inspect the scoped diff**

Run:

```bash
./script/format.sh Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SessionDetailView.swift Tests/awesoMuxTests/SidebarAttentionCuePolicyTests.swift Tests/awesoMuxTests/SidebarHoverArchitectureTests.swift
./script/format.sh --lint
git diff --check
```

Expected: all commands exit 0. Do not commit yet; this structural refinement remains part of the pending dogfood batch and must pass the required final reviews before commit/PR.

**Task 3 checkpoint:** Terminal Cue Ownership complete (dirty-tree scoped diff, 47 focused tests green, task review clean; live visual QA pending).
