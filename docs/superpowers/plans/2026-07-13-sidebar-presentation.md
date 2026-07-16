# Sidebar Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent sidebar hide/show with edge-hover reveal, left/right sidebar placement, and a vertically centered Markdown Files/Document toggle while preserving the existing collapsed rail.

**Architecture:** `AppearanceConfig` owns the durable left/right choice, while a focused UserDefaults store owns the command-driven hidden preference. A small presentation model separates persistent intent from temporary hover reveal; `ContentView` orchestrates it, and a position-aware `SidebarSplitController` performs native AppKit pane ordering and divider math without encoding hidden as a fake width.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSSplitView`, Observation, UserDefaults, TOML configuration, swift-testing.

## Global Constraints

- macOS 15+ and SwiftPM only.
- `Command-Backslash` remains Collapse/Expand Sidebar; `Command-Shift-Backslash` becomes Hide/Show Sidebar.
- Hidden state persists across launches but never overwrites sidebar width or last expanded width.
- `appearance.sidebar_position` lives in the Sidebar section of Appearance settings and defaults to `left`.
- Hover reveal uses the normal split pane and shifts detail content; it does not float above the terminal.
- Traffic-light clearance remains on the physical left regardless of sidebar position.
- Peek cards open inward: right from a left sidebar, left from a right sidebar.
- awesoMux command routing stays in SwiftUI/AppKit menus, the palette, and `KeyboardShortcutCatalog`; do not add Ghostty app-action bindings.
- User-facing localized strings use literal-as-key `String(localized:comment:)` calls.
- Use targeted `script/format.sh` only on intentionally changed Swift files.
- Follow test-driven development: see each new test fail before implementing its behavior.

## Component Map

- `Sources/AwesoMuxConfig/AppearanceConfig.swift`: durable `SidebarPosition` value and TOML ownership.
- `Sources/awesoMux/Views/Settings/Panes/AppearanceSettingsPane.swift`: Left/Right control inside the existing Sidebar section.
- `Sources/awesoMux/Services/SidebarPresentationPreferenceStore.swift`: persistent hidden intent only.
- `Sources/awesoMux/Views/SidebarPresentationModel.swift`: temporary reveal and hover-handoff state machine.
- `Sources/awesoMux/Views/SidebarSplitController.swift`: position-aware native pane order, width conversion, hide/reveal.
- `Sources/awesoMux/Views/SidebarSplitView.swift`: SwiftUI-to-AppKit inputs and proxy wiring.
- `Sources/awesoMux/Views/SidebarSplitSupport.swift`: proxy API plus position-aware peek anchors.
- `Sources/awesoMux/Views/ContentView.swift`: presentation orchestration, edge trigger, titlebar ordering, focus behavior.
- `Sources/awesoMux/Services/KeyboardShortcutCatalog.swift` and app routing files: Hide/Show command family.
- `Sources/awesoMux/Views/DocumentTabStripView.swift`: existing PR #68 full-bar geometry already satisfies the alignment requirement; no sidebar-feature change is needed.

## Architecture Review Fold-In

The pre-implementation architecture review rated the first draft **FORMING**. The feature shape was sound, but the native split boundary hid four load-bearing assumptions: divider thickness was omitted from right-side math, divider drag tracking assumed the sidebar was always the first subview, runtime side changes could disturb the terminal's first responder, and app-wide hidden state was being over-designed as per-window state. This revision resolves all four before code begins.

### Component flow

```text
Appearance TOML ── sidebarPosition ───────────────┐
                                                  v
Menu / key / palette ── persistent toggle ──> SidebarPresentationModel
Edge + sidebar hover ── temporary events ────────┤
                                                  v
                                      ContentView orchestration
                                         │              │
                                position/hidden      inward edge
                                         │              │
                                         v              v
                              SidebarSplitController  Peek overlay
                                         │
                               NSSplitView role layout

UserDefaults ── hidden intent only
Width store  ── visible/expanded widths only
```

### Presentation state machine

```text
VISIBLE_PERSISTENT
  Command-Shift-Backslash -> HIDDEN

HIDDEN
  edge enter              -> HOVER_REVEALED
  Command-Shift-Backslash -> VISIBLE_PERSISTENT
  Focus Sidebar           -> VISIBLE_PERSISTENT + focus request

HOVER_REVEALED
  edge/sidebar re-enter   -> cancel pending hide
  leave both              -> grace -> HIDDEN
  Command-Shift-Backslash -> VISIBLE_PERSISTENT
  position change         -> HIDDEN on the newly configured edge
```

Only transitions into `HIDDEN` or `VISIBLE_PERSISTENT` from the explicit command/focus path write UserDefaults. Hover transitions never write. Width persistence is outside this state machine.

### Native split invariants

- `sidebarChild` and `detailChild` are semantic roles; physical `subviews` order is never used to infer a role.
- Divider coordinates use `paneExtent = max(0, bounds.width - dividerThickness)`. Left width is `coordinate`; right width is `paneExtent - coordinate`.
- Runtime side changes reorder existing attached views with `sortSubviews`, never destroy/recreate hosting controllers, and preserve the current first responder when it remains inside either child.
- Hidden layout may use a zero divider coordinate (left) or `paneExtent` (right), but zero is never sent to `SidebarWidthPolicy` or a preference store.
- `DividerTrackingSplitView` compares the semantic sidebar width through an injected closure; it never reads `subviews.first`.
- Position changes cancel open peek cards and temporary reveal before moving the edge, preventing stale geometry from the old side.

### Named failure modes and required responses

| Failure | Trigger | Required response |
| --- | --- | --- |
| Divider-thickness drift | Right-side conversion treats total bounds as pane extent | Include divider thickness in both conversion directions and round-trip tests. |
| First-responder loss | Live position change reorders attached hosting views | Reorder in place, assert child identity, and preserve/restore the existing responder without recreating terminal views. |
| Stale hover resurrection | A delayed hide from the old side fires after a position change | Cancel the task and advance the generation before moving sides. |
| Hidden-width corruption | A zero-width layout callback reaches commit persistence | Suppress live/commit callbacks while hidden and test width keys remain unchanged. |
| Hidden resize expansion | A window layout pass runs restore-on-grow while hidden | Hidden state bypasses reclamp/restore decisions until reveal. |
| Wrong-side drag commit | Drag tracking reads the leading view rather than the sidebar role | Measure through `sidebarWidthProvider` before/after tracking. |
| Edge-trigger dead zone | Trigger exit arrives before sidebar enter during reveal | The shared 220ms grace covers the handoff; sidebar enter cancels it. |
| Position-change peek orphan | A card keeps old-side coordinates | Hide both session and group peek state before changing split position. |

---

### Task 1: Persist Sidebar Position in Appearance

**Files:**
- Modify: `Sources/AwesoMuxConfig/AppearanceConfig.swift`
- Modify: `Sources/awesoMux/Views/Settings/Panes/AppearanceSettingsPane.swift`
- Create: `Tests/AwesoMuxConfigTests/AppearanceConfigSidebarPositionTests.swift`
- Modify: `Tests/AwesoMuxConfigTests/TOMLConfigCodecTests.swift`
- Modify: `Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: `AppearanceConfig.SidebarPosition: String, Codable, CaseIterable, Equatable, Sendable` with `.left` and `.right`.
- Produces: `AppearanceConfig.sidebarPosition` defaulting through `DefaultSidebarPosition` to `.left`.
- Consumed later by: `ContentView`, `SidebarSplitView`, peek geometry, and titlebar layout.

- [ ] **Step 1: Add failing config tests**

Create tests that assert:

```swift
@Suite("AppearanceConfig.sidebarPosition")
struct AppearanceConfigSidebarPositionTests {
    @Test func defaultsLeft() {
        #expect(AppearanceConfig.defaultValue.sidebarPosition == .left)
    }

    @Test func rightRoundTripsThroughTOML() throws {
        var config = AwesoMuxConfig.defaultValue
        config.appearance.sidebarPosition = .right
        let codec = TOMLConfigCodec()
        let encoded = try codec.encodeString(config)
        #expect(encoded.contains("sidebar_position = \"right\""))
        #expect(try codec.decode(encoded).appearance.sidebarPosition == .right)
    }
}
```

Also extend the default/missing-key TOML cases to assert `.left`. Add `sidebar_position = "middle"` and assert decoding throws rather than silently defaulting; `@TOMLDefault` defaults missing keys only and must fail closed for present invalid values.

- [ ] **Step 2: Run tests and verify RED**

Run: `./script/swift-test.sh --filter AppearanceConfigSidebarPositionTests`

Expected: compilation fails because `sidebarPosition` and `SidebarPosition` do not exist.

- [ ] **Step 3: Add the minimal config type**

Add the wrapped property, initializer parameter/assignment, coding key `sidebar_position`, owned TOML key, default provider, and enum:

```swift
@TOMLDefault<DefaultSidebarPosition> public var sidebarPosition: SidebarPosition

public struct DefaultSidebarPosition: DefaultProvider {
    public static let defaultValue: AppearanceConfig.SidebarPosition = .left
}

public extension AppearanceConfig {
    enum SidebarPosition: String, Codable, CaseIterable, Equatable, Sendable {
        case left
        case right
    }
}
```

- [ ] **Step 4: Run config tests and verify GREEN**

Run: `./script/swift-test.sh --filter AppearanceConfigSidebarPositionTests`

Expected: PASS.

- [ ] **Step 5: Add the Appearance control and reset behavior**

Inside the existing Sidebar `SettingsSection`, add a `Picker` using `.segmented` with literal localized labels "Left" and "Right", bound to `appSettingsStore.appearance.binding(\.sidebarPosition)`. Update the section subtitle and Reset Appearance copy, mutation, and `didReset` comparison to include sidebar position.

- [ ] **Step 6: Format, run focused config/settings checks, and commit**

Run:

```bash
script/format.sh Sources/AwesoMuxConfig/AppearanceConfig.swift Sources/awesoMux/Views/Settings/Panes/AppearanceSettingsPane.swift Tests/AwesoMuxConfigTests/AppearanceConfigSidebarPositionTests.swift Tests/AwesoMuxConfigTests/TOMLConfigCodecTests.swift
./script/swift-test.sh --filter AppearanceConfigSidebarPositionTests
./script/swift-test.sh --filter TOMLConfigCodecTests
git diff --check
```

Expected: all tests pass and the diff check is clean.

Commit: `feat(settings): add sidebar position preference`

---

### Task 2: Model Persistent Hide Intent and Hover Reveal

**Files:**
- Create: `Sources/awesoMux/Services/SidebarPresentationPreferenceStore.swift`
- Create: `Sources/awesoMux/Views/SidebarPresentationModel.swift`
- Create: `Tests/awesoMuxTests/SidebarPresentationPreferenceStoreTests.swift`
- Create: `Tests/awesoMuxTests/SidebarPresentationModelTests.swift`

**Interfaces:**
- Produces: `SidebarPresentationPreferenceStore.isHidden() -> Bool` and `saveHidden(_:)`.
- Produces: `@Observable @MainActor final class SidebarPresentationModel`.
- Produces model state: `private(set) var userWantsHidden: Bool`, `private(set) var isTemporarilyRevealed: Bool`, and computed `var isSidebarVisible: Bool`.
- Produces model actions: `togglePersistentVisibility()`, `showPersistently()`, `edgePointerChanged(_:)`, and `sidebarPointerChanged(_:)`.

- [ ] **Step 1: Add failing preference-store tests**

Use an isolated `UserDefaults` suite and assert missing defaults to visible, save/restore round trips, and writing hidden state does not change `SidebarWidthPreferenceStore.widthKey` or `lastNonCollapsedWidthKey`. Hidden state is app-wide because awesoMux has one primary window; do not add speculative per-window keys.

- [ ] **Step 2: Run store tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarPresentationPreferenceStoreTests`

Expected: compilation fails because the store does not exist.

- [ ] **Step 3: Implement the preference store**

Use key `awesomux.sidebar.hidden`, the same non-empty window-ID suffix behavior as the width store, and `UserDefaults.bool(forKey:)`/`set(_:forKey:)`. Do not read or write width keys.

- [ ] **Step 4: Add failing presentation-model tests**

With an injectable async sleep gate, cover:

```swift
#expect(model.userWantsHidden)
#expect(!model.isSidebarVisible)
model.edgePointerChanged(true)
#expect(model.isTemporarilyRevealed)
#expect(model.isSidebarVisible)
model.edgePointerChanged(false)
model.sidebarPointerChanged(true)
await gate.release()
#expect(model.isSidebarVisible) // handoff cancelled hide
```

Add cases for persistent toggle, explicit show for Focus Sidebar, leaving both regions, re-entry cancellation, a stale delay unable to hide a newer reveal, and hover events doing nothing while persistently visible.

- [ ] **Step 5: Run model tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarPresentationModelTests`

Expected: compilation fails because the model does not exist.

- [ ] **Step 6: Implement the minimal state machine**

Use one cancellable `Task<Void, Never>?`, booleans for edge/sidebar pointer presence, and a generation counter. Production sleep is 220ms, matching the existing sidebar peek grace. `togglePersistentVisibility()` saves through the store; hover reveal never saves. `showPersistently()` clears temporary state, cancels delayed work, and saves `false`.

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
script/format.sh Sources/awesoMux/Services/SidebarPresentationPreferenceStore.swift Sources/awesoMux/Views/SidebarPresentationModel.swift Tests/awesoMuxTests/SidebarPresentationPreferenceStoreTests.swift Tests/awesoMuxTests/SidebarPresentationModelTests.swift
./script/swift-test.sh --filter SidebarPresentation
git diff --check
```

Expected: all presentation tests pass.

Commit: `feat(sidebar): model persistent hide and hover reveal`

---

### Task 3: Make the Native Split Position-Aware and Hideable

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Tests/awesoMuxTests/SidebarSplitControllerTests.swift`

**Interfaces:**
- Consumes: `AppearanceConfig.SidebarPosition`.
- Produces: `SidebarSplitController.setSidebarPosition(_:)` and `setSidebarHidden(_:)`.
- Produces pure helpers `dividerCoordinate(forSidebarWidth:paneExtent:position:)` and `sidebarWidth(forDividerCoordinate:paneExtent:position:)`, where `paneExtent = bounds.width - dividerThickness`.
- Extends `SidebarSplitProxy` with `setPosition` and `setHidden` closures.

- [ ] **Step 1: Add failing pure geometry tests**

Assert a 300pt sidebar in a 1,200pt split with a 1pt divider has pane extent 1,199 and maps to divider coordinate 300 on `.left` and 899 on `.right`; both coordinates map back to width 300. Cover zero/negative/non-finite pane extents using finite clamped results.

- [ ] **Step 2: Add failing controller behavior tests**

Instantiate the controller with empty child controllers, load a known frame, then assert:

- changing left→right preserves sidebar width and swaps physical child order;
- changing sides keeps the same hosting-controller/view identities and preserves a sentinel first responder;
- hidden collapses the sidebar role to 0 without emitting `onCommitWidth`;
- reveal restores the pre-hide width;
- `maxSidebarWidth` and reclamp use sidebar width on either side;
- a window resize while hidden does not trigger expanded-width restore;
- a divider drag cannot commit a width while hidden.

- [ ] **Step 3: Run split tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarSplitController`

Expected: compilation fails for missing position/hidden APIs.

- [ ] **Step 4: Implement position-aware divider math**

Store `sidebarPosition`, add child views in physical order based on it, and use role references rather than `subviews[0]`. Runtime changes reorder the already-attached views with `sortSubviews`; they do not remove views or recreate hosting controllers. Capture the first responder before reordering and restore it only when it was a descendant of one of the two child roots and AppKit did not preserve it automatically. All divider writes go through the pure conversion helper using `paneExtent = bounds.width - splitView.dividerThickness`. Delegate constraints mirror their coordinate for right placement while enforcing the same sidebar and terminal minimum widths.

- [ ] **Step 5: Implement explicit hide/reveal**

Store `isSidebarHidden`. Hidden sets the divider to 0 on the left or `paneExtent` on the right while the delegate temporarily permits that hidden endpoint, suppresses live/commit callbacks, and bypasses normal `SidebarWidthPolicy` floor enforcement. Revealing applies the last requested/visible sidebar width through the normal clamp. `setSidebarWidth` while hidden records the requested restore width without making the pane visible. `viewDidLayout` skips restore/reclamp while hidden. Inject a `sidebarWidthProvider` into `DividerTrackingSplitView` so drag completion compares semantic sidebar width instead of `subviews.first`.

- [ ] **Step 6: Wire representable inputs and proxy commands**

Add `position` and `isHidden` values to `SidebarSplitView`; set position before hidden state during make/update so hidden endpoints are calculated on the correct side. Extend the proxy with stable command closures installed once. Ensure host-controller lookup remains by stored child role rather than physical `children` order after a side swap.

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
script/format.sh Sources/awesoMux/Views/SidebarSplitController.swift Sources/awesoMux/Views/SidebarSplitView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Tests/awesoMuxTests/SidebarSplitControllerTests.swift
./script/swift-test.sh --filter SidebarSplitController
./script/swift-test.sh --filter SidebarWidthPreferenceStore
git diff --check
```

Expected: split and existing width tests pass.

Commit: `feat(sidebar): support hidden and trailing split layouts`

---

### Task 4: Integrate Position, Edge Reveal, Titlebar, and Peek Geometry

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Modify: `Sources/awesoMux/Views/SidebarView.swift`
- Modify: `Sources/awesoMux/Views/SidebarGroupHeaderView.swift`
- Modify: `Sources/awesoMux/Views/SidebarSessionTile.swift`
- Modify: `Tests/awesoMuxTests/SidebarPeekModelTests.swift`
- Create: `Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift`

**Interfaces:**
- Consumes: `appearance.sidebarPosition`, `SidebarPresentationModel`, and split proxy APIs.
- Produces pure layout decisions for edge (`.leading`/`.trailing`), titlebar physical order, and peek inward direction.
- Changes peek geometry from a single `anchorX = frame.maxX` assumption to a position-aware inward anchor.

- [ ] **Step 1: Add failing layout-policy tests**

Create pure expectations that left maps to leading trigger/rightward peek and right maps to trailing trigger/leftward peek. Assert traffic-light ownership remains physical leading in both cases. Extend peek-model tests so `show`/`showGroup` and frame updates retain the correct inward edge for a supplied position.

- [ ] **Step 2: Run layout tests and verify RED**

Run: `./script/swift-test.sh --filter SidebarPresentationLayoutTests`

Expected: compilation fails for missing policy and position-aware peek input.

- [ ] **Step 3: Integrate presentation state in ContentView**

Own one `@State` `SidebarPresentationModel`, initialized from the preference store. Pass `position` and `!model.isSidebarVisible` to `SidebarSplitView`. On state changes, command the proxy without persisting width. Add a 6pt clear edge target spanning the window content height only while `userWantsHidden`; position it with an overlay alignment matching the configured side and route `onHover` into the model. Give the trigger no accessibility element and no keyboard focusability because menu/palette/shortcut are the accessible controls.

- [ ] **Step 4: Complete hover handoff and focus behavior**

Attach sidebar-root hover entry/exit to `sidebarPointerChanged`. A temporary reveal remains visible while either trigger or sidebar is hovered. When Focus Sidebar is requested, call `showPersistently()` before dispatching the existing focus notification so the focus destination has non-zero width.

On a position change, cancel delayed hover work, return a persistently hidden sidebar to `HIDDEN` rather than carrying a reveal across the window, hide both peek-card variants, update split position, then update edge/peek geometry. A persistently visible sidebar stays visible at the same semantic width.

- [ ] **Step 5: Reorder titlebar without moving traffic-light responsibility**

Make `AppTitlebarView` accept `sidebarPosition`. Build physical left/right columns from position, but apply traffic-light leading padding to the window-leading column, not to the semantic sidebar column. Keep divider gutter attached to the actual split boundary.

- [ ] **Step 6: Make peek anchors position-aware**

Pass `SidebarPosition` into row/header geometry publication. Store the inward row edge and direction in `SidebarPeekModel`; left uses `frame.maxX` and leading transition, right uses `frame.minX` and trailing transition. Clamp the overlay to available detail bounds on either side.

- [ ] **Step 7: Test, format, and commit**

Run:

```bash
script/format.sh Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarSplitSupport.swift Sources/awesoMux/Views/SidebarView.swift Sources/awesoMux/Views/SidebarGroupHeaderView.swift Sources/awesoMux/Views/SidebarSessionTile.swift Tests/awesoMuxTests/SidebarPeekModelTests.swift Tests/awesoMuxTests/SidebarPresentationLayoutTests.swift
./script/swift-test.sh --filter SidebarPresentation
./script/swift-test.sh --filter SidebarPeekModel
./script/swift-test.sh --filter AppTitlebarMetrics
git diff --check
```

Expected: presentation, peek, and titlebar tests pass.

Commit: `feat(sidebar): integrate edge reveal and side placement`

---

### Task 5: Add the Hide/Show Sidebar Command Family

**Files:**
- Modify: `Sources/awesoMux/Services/KeyboardShortcutCatalog.swift`
- Modify: `Sources/awesoMux/Services/SidebarFocusRequest.swift`
- Modify: `Sources/awesoMux/App/AwesoMuxApplication.swift`
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift`
- Modify: `Sources/awesoMux/Services/PaletteCommand.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift`
- Modify: `Tests/awesoMuxTests/KeyboardShortcutCatalogTests.swift`
- Modify: `Tests/awesoMuxTests/PaletteCommandRegistryTests.swift`
- Modify: `docs/shortcuts.md`
- Modify: `Resources/Localizable.xcstrings`

**Interfaces:**
- Produces stable catalog binding `KeyboardShortcutCatalog.toggleSidebarVisibility` with ID `toggleSidebarVisibility`, action `Hide/Show Sidebar`, key `\\`, modifiers `[.command, .shift]`.
- Produces notification `.awesoMuxToggleSidebarVisibilityRequested` and a non-repeat event matcher.
- Produces app request `sidebarVisibilityToggleRequestID: UUID?` consumed by `ContentView`.

- [ ] **Step 1: Add failing catalog and registry tests**

Assert:

```swift
let binding = KeyboardShortcutCatalog.toggleSidebarVisibility
#expect(binding.id == "toggleSidebarVisibility")
#expect(binding.key == "\\")
#expect(binding.modifiers == [.command, .shift])
#expect(binding.displaySymbol == "⇧⌘\\")
#expect(binding.spokenForm == "Shift Command Backslash")
```

Assert it appears in shortcut settings and the palette, while `toggleSidebarWidth` remains `Command-Backslash` with its existing ID/action.

- [ ] **Step 2: Run command tests and verify RED**

Run: `./script/swift-test.sh --filter KeyboardShortcutCatalog`

Expected: compilation fails because the new binding does not exist.

- [ ] **Step 3: Add catalog/menu/palette registration**

Add the new binding beside `toggleSidebarWidth`, include it in settings/cheatsheet sections, add Window menu and command palette entries, and route their closures to a new app request method. Preserve all existing width-toggle copy and identifiers.

- [ ] **Step 4: Add terminal-first-responder interception**

Mirror `SidebarWidthToggleShortcut` with a `SidebarVisibilityToggleShortcut` matcher. In `AwesoMuxApplication.sendEvent`, handle it before the width chord, ignore repeats, respect the same modal/no-window gate, and post the new notification. Add diagnostics using neutral action names.

- [ ] **Step 5: Route the request into ContentView**

Add `sidebarVisibilityToggleRequestID` to `ContentView`. On a new non-nil ID, call `presentationModel.togglePersistentVisibility()`. Do not call `toggleSidebarWidth()` and do not save a width.

- [ ] **Step 6: Update shortcut docs, run tests, and commit**

Run:

```bash
script/format.sh Sources/awesoMux/Services/KeyboardShortcutCatalog.swift Sources/awesoMux/Services/SidebarFocusRequest.swift Sources/awesoMux/App/AwesoMuxApplication.swift Sources/awesoMux/App/AwesoMuxApp.swift Sources/awesoMux/Services/PaletteCommand.swift Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/KeyboardShortcutCatalogTests.swift Tests/awesoMuxTests/PaletteCommandRegistryTests.swift
./script/swift-test.sh --filter KeyboardShortcutCatalog
./script/swift-test.sh --filter PaletteCommandRegistry
./script/swift-test.sh --filter SidebarPresentation
git diff --check
```

Expected: command and presentation tests pass; docs list both related shortcuts.

Commit: `feat(sidebar): add hide and show keyboard command`

---

### Task 6: Center the Markdown Files/Document Toggle

**Files:**
- Inspect only: `Sources/awesoMux/Views/DocumentTabStripView.swift`

**Interfaces:**
- Preserves the merge-base PR #68 full-bar geometry: every document-strip control uses a 24-point visible pill centered within 28-point chrome, and its outer frame provides the full 28-point hit target.

- [ ] **Step 1: Confirm the merge-base geometry**

Inspect `DocumentTabStripView.height`, `pillHeight`, and each outer control frame. Confirm that tabs, Files/Document, and revision controls share the same full-bar centering model.

- [ ] **Step 2: Keep the existing implementation unchanged**

Do not introduce a vertical offset or a Files/Document-only metric. The requested alignment is already satisfied by the full-bar implementation.

- [ ] **Step 3: Run focused regression tests**

Run:

```bash
./script/swift-test.sh --filter PaneTitleBarBandTreatmentTests
./script/swift-test.sh --filter DocumentRevisionIndicatorStateTests
git diff --check
```

Expected: both test selections pass, and no Markdown alignment code change is present in this feature diff.

---

### Task 7: Integration Verification and Public-Artifact Preparation

**Files:**
- Potentially modify after a reproduced integration failure: `Sources/awesoMux/Views/ContentView.swift`
- Potentially modify after a reproduced integration failure: `Sources/awesoMux/Views/SidebarSplitController.swift`
- Potentially modify after a reproduced integration failure: `Sources/awesoMux/Views/SidebarSplitView.swift`
- Potentially modify after a reproduced integration failure: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Potentially modify after a reproduced integration failure: `Sources/awesoMux/Views/DocumentTabStripView.swift`
- Update the private session note outside this repository after implementation.

**Interfaces:**
- Consumes all prior tasks.
- Produces a preflight-clean, visually verified branch ready for review/PR preparation.

- [ ] **Step 1: Run targeted lint and full tests**

Run:

```bash
script/format.sh --lint
./script/swift-test.sh
```

Expected: formatter lint passes; all tests pass (baseline was 3,518 tests in 383 suites).

- [ ] **Step 2: Run repository preflight**

Run: `./script/preflight.sh`

Expected: PASS. If a known unrelated infrastructure failure occurs, capture the exact failure and verify every earlier preflight stage rather than claiming a pass.

- [ ] **Step 3: Launch the isolated worktree build**

Run: `./script/build_and_run.sh`

Verify manually:

- left visible, 60pt rail, persistent hidden, and edge-hover reveal;
- right visible, 60pt rail, persistent hidden, and edge-hover reveal;
- `Command-Backslash` only collapses/expands;
- `Command-Shift-Backslash` only hides/shows;
- Focus Sidebar reveals then focuses;
- hover handoff does not flicker and stale grace cannot re-hide an explicit show;
- divider drag and narrow-window resize preserve terminal minimum width on both sides;
- relaunch restores hidden state and right/left position without losing width;
- traffic lights remain correctly padded on the physical left;
- session and group peek cards open inward;
- Files and Document states are vertically centered and retain the full hit target.

- [ ] **Step 4: Re-check overlapping PR state**

Run:

```bash
gh pr list --base main --state open --json number,title,author,files
git fetch origin main
git diff --name-only origin/main...HEAD
```

If PR #22 or its successor still overlaps app/sidebar command files, record the exact files and rebase/reconcile before publishing. Do not overwrite another assignee's branch.

- [ ] **Step 5: Run the required pre-commit review checkpoint for code**

Run the repository's multi-reviewer code-review workflow, address valid findings, and repeat focused/full verification for any fixes. Use neutral public wording; never copy internal reviewer/persona names into commits, PRs, comments, or issues.

- [ ] **Step 6: Finish private documentation and commit final integration fixes**

Update the private session note outside this repository.

If integration fixes exist, commit them as: `fix(sidebar): address integration findings`

Do not open a PR until the user supplies the required AI assistance level (`none`, `light`, `moderate`, or `substantial`).
