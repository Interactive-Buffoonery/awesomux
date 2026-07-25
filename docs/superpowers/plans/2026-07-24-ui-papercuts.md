# UI Papercuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four independent awesoMux UI papercuts — a wrapping sidebar footer label, dead bands that break cross-group workspace drags, a missing in-group new-workspace affordance, and a modal workspace rename that should be inline.

**Architecture:** No new interaction patterns. Papercut 1 swaps a `Text` for a stdlib `ViewThatFits`. Papercut 2 is a pure geometry change — bottom-only padding bracketing `.sidebarDrop`, reclaimed with negative padding so nothing about layout, group frames, or group reordering moves. Papercut 3 mounts an already-shipped view in one more place, with its three case-differences hoisted into a policy enum matching the local `SidebarGroupClosePolicy` pattern. Papercut 4 ports the inline-edit pattern from `PaneTitleBarView` into the titlebar workspace cluster.

**Tech Stack:** Swift 6, SwiftUI + AppKit interop, swift-testing (`@Suite`/`@Test`/`#expect`), SwiftPM. macOS 15+.

**Spec:** `docs/superpowers/specs/2026-07-24-ui-papercuts-design.md`
**Issue:** [#220](https://github.com/Interactive-Buffoonery/awesomux/issues/220)
**Branch:** `issue/220-ui-papercuts` (worktree `.worktrees/sidebar-papercuts`)

## Global Constraints

- New tests use swift-testing (`@Suite` / `@Test` / `#expect`). Existing XCTest tests stay until touched. Existing suites in this plan (`SidebarInsertionResolverTests`, `SidebarGroupHeaderHitTargetTests`) are already swift-testing — match their style.
- Localized strings use literal-as-key: `String(localized: "…", comment: "…")`. Never `defaultValue:` (ADR 0014).
- Count-dependent user-facing strings must use `Localizable.stringsdict` plural entries via `String(localized:)`. **No new plural entries are needed in this plan** — papercut 1 reuses the existing `accessibility.footer.agentsTotal` key.
- Run tests with `./script/swift-test.sh` (never bare `swift test` — a fresh worktree fails module resolution without the Ghostty preflight). Filter with `./script/swift-test.sh --filter <pattern>`.
- Formatting: `script/format.sh` **only** with the files you intentionally changed. Never repository-wide. `script/format.sh --lint` is the non-mutating gate — and note that `--lint` is line-scoped while `format` is whole-file, so prefer `--lint` and hand-fix.
- Comments explain *why*, never narrate *what*. Don't add backwards-compatibility shims for code paths that don't exist yet.
- Conventional Commits: `<type>(<scope>): <lowercase imperative>`, subject ≤72 chars, no period.
- Known constants used below: `AwSpacing.footerChrome == 38`, `AwSpacing.titlebar == 38`, `SessionStore.appendIndex == Int.max`. Density: comfortable `groupStackSpacing 14` / `sessionStackSpacing 5`; compact `8` / `3`.

## Review gate outcomes (2026-07-24)

This plan was revised after an architecture review. Findings folded in, so a fresh implementer doesn't rediscover them:

| Finding | Severity | Resolution |
|---|---|---|
| Papercut 2's padding-bracket technique was asserted as fact but never verified | Blocker | Falsified empirically before approval. Evidence recorded in Task 2's preamble; the technique holds. Task 2 Step 7 adds a permanent guard against the real view. |
| Stale draft could rename the wrong workspace when one closes mid-rename | Major (writes wrong data) | Guard moved to `AppTitlebarView.body` keyed on `session?.id` — Task 5 Steps 6b/6c, with a red-first regression test. |
| New-workspace row's behavior under an active filter was undecided | Major | Decided: hidden while filtering. A create button whose result instantly fails the filter reads as a broken click. Task 3 Step 8. |
| Row's `canRemoveGroup` parameter now carries a presentation value | Minor | Renamed `showsRemoveButton`. Task 3 Step 6. |
| Plan over-claimed that existing hit-target tests would catch a failed reclaim | Minor | Claim softened; the real detector is the new Task 2 Step 7 guard. |
| Commit can revert a concurrent agent retitle | Minor | Documented, not fixed — `PaneTitleBarView` has the same shape, so a fix belongs in a change covering both. Task 5 Step 10, item 8c. |

## Coverage honesty requirement

`SidebarHostedTestHarness` has **no synthetic drag-session support** — `sendClick` hardcodes `clickCount: 1` and there is no drag helper. Papercut 2's behavior change is therefore **not** covered end-to-end by any automated test in this plan. Task 2 ships a characterization test that documents the resolver contract the geometry change depends on, plus a manual verification script. The PR body must state this limitation in those terms. Do not describe Task 2 as "tested" without that qualifier.

## File Structure

**Created:**

- `Sources/awesoMux/Views/NewWorkspaceInGroupRowPolicy.swift` — pure policy for the three empty-vs-populated differences in the new-workspace row. Mirrors `SidebarGroupClosePolicy`.
- `Sources/awesoMux/Views/WorkspaceTitleCommit.swift` — pure commit resolver for the inline workspace rename (`WorkspaceTitleCommit` enum + resolver).
- `Tests/awesoMuxTests/SidebarStatusFooterLayoutTests.swift` — footer height regression test.
- `Tests/awesoMuxTests/NewWorkspaceInGroupRowPolicyTests.swift` — policy unit tests.
- `Tests/awesoMuxTests/WorkspaceTitleCommitTests.swift` — commit resolver unit tests.
- `Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift` — titlebar double-click no longer requests the sheet.

**Modified:**

- `Sources/awesoMux/Views/SidebarStatusFooter.swift:78-98` — `ViewThatFits` total label.
- `Sources/awesoMux/Views/SidebarGroupView.swift:131-374` — padding brackets, overlay reorder, unconditional row mount.
- `Sources/awesoMux/Views/SidebarDropDelegates.swift:473-595` — rename `EmptyGroupDropTarget` → `NewWorkspaceInGroupRow`, add `showsRestingBorder`.
- `Sources/awesoMux/Views/SidebarGroupHeaderView.swift` — one comment referencing `EmptyGroupDropTarget` by name.
- `Sources/awesoMux/Views/ContentView.swift:555-830` — drop `private` from `AppTitlebarView` and `WindowDragRenameHandle`, inline rename state and field.
- `Tests/awesoMuxTests/SidebarHostedTestHarness.swift` — add `sendDoubleClick`.
- `Tests/awesoMuxTests/SidebarGroupHeaderHitTargetTests.swift:177-330` — add `entries` parameter to the private harness.
- `Tests/awesoMuxTests/SidebarInsertionResolverTests.swift` — gutter characterization test.

---

### Task 1: Footer total never wraps

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarStatusFooter.swift:78-98`
- Test: `Tests/awesoMuxTests/SidebarStatusFooterLayoutTests.swift` (create)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks rely on. Fully independent.

- [ ] **Step 1: Write the failing test**

Create `Tests/awesoMuxTests/SidebarStatusFooterLayoutTests.swift`:

```swift
import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct SidebarStatusFooterLayoutTests {
    /// The footer is a single chrome row. With every chip visible and a
    /// two-digit total it must still fit one line — a wrapped total pushes the
    /// row past `AwSpacing.footerChrome` and mis-centers the disclosure chevron
    /// against the two-line block.
    @Test("expanded footer stays one row tall when every chip is visible")
    func expandedFooterStaysOneRowTall() {
        let footer = SidebarStatusFooter(
            counts: [.thinking: 12, .output: 3, .needs: 4],
            total: 19,
            displayMode: .expanded,
            onOpenQuickSettings: {},
            onSelectNextMatchingState: { _ in },
            onToggleActivityPanel: { _ in },
            activityPanelOpen: false
        )
        let hostingView = NSHostingView(rootView: footer.frame(width: 200))
        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height <= AwSpacing.footerChrome)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/swift-test.sh --filter SidebarStatusFooterLayoutTests`

Expected: FAIL — `fittingSize.height` exceeds 38 because the total label wraps to two lines.

**If it PASSES, the test is not yet exercising the bug.** Do not proceed. Reduce the `.frame(width:)` (try 180, then 160) until it fails, then keep that width. A passing test here would lock in nothing.

- [ ] **Step 3: Write minimal implementation**

In `Sources/awesoMux/Views/SidebarStatusFooter.swift`, replace the total `Button`'s label (currently the `HStack` at lines 81-89) with a `ViewThatFits` over a shared builder. Add this private method to the struct:

```swift
    /// One rendering of the total label, so both `ViewThatFits` candidates keep
    /// identical styling and chevron direction and can't drift apart.
    @ViewBuilder
    private func totalLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .monospacedDigit()
                // Load-bearing, not decoration: `ViewThatFits` falls back to its
                // LAST candidate unconditionally when none fit, so without this
                // a narrow enough rail still wraps — just with the bare count.
                .lineLimit(1)
            // The panel slides in directly above the footer, so the disclosure
            // points up when closed and down when open.
            Image(systemName: activityPanelOpen ? "chevron.down" : "chevron.up")
                .font(.system(size: 8, weight: .semibold))
                .accessibilityHidden(true)
        }
        .awFont(AwFont.Mono.meta)
        .foregroundStyle(Color.aw.textFaint)
        // Match the chips' hit target — this is the panel's only guaranteed
        // entry point, so bare text height is too small a target (WCAG 2.5.8).
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
```

and change the button's label to:

```swift
            Button {
                onToggleActivityPanel(nil)
            } label: {
                // Degrade "19 agents" to "19" rather than wrapping to two lines.
                // The full plural stays on the Button's accessibilityLabel below,
                // so VoiceOver output is identical at every width.
                ViewThatFits(in: .horizontal) {
                    totalLabel(LocalizedPluralStrings.footerAgentsTotal(count: total))
                    totalLabel("\(total)")
                }
            }
```

Leave the `Button`'s `.buttonStyle`, `.accessibilityLabel`, `.accessibilityValue`, `.accessibilityHint`, and `.help` modifiers (lines 99-111) exactly as they are — they already carry the full plural string and the open/closed state.

- [ ] **Step 4: Run test to verify it passes**

Run: `./script/swift-test.sh --filter SidebarStatusFooterLayoutTests`
Expected: PASS

- [ ] **Step 5: Verify no regression in the wider suite**

Run: `./script/swift-test.sh --filter Sidebar`
Expected: PASS (no test currently asserts a two-line footer).

- [ ] **Step 6: Lint the touched files**

Run: `script/format.sh --lint Sources/awesoMux/Views/SidebarStatusFooter.swift Tests/awesoMuxTests/SidebarStatusFooterLayoutTests.swift`

Expected: no findings. Note `--lint` exits 0 even when it prints warnings — **read the output**, don't trust the exit code.

- [ ] **Step 7: Commit**

```bash
git add Sources/awesoMux/Views/SidebarStatusFooter.swift Tests/awesoMuxTests/SidebarStatusFooterLayoutTests.swift
git commit -m "fix(sidebar): stop the footer agent total wrapping to two lines"
```

---

### Task 2: Reclaim the dead bands around workspace drop regions

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarGroupView.swift:131-374`
- Test: `Tests/awesoMuxTests/SidebarInsertionResolverTests.swift` (add one `@Test`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks rely on by name. Task 3 mounts a row inside the padded region this task creates, but does not reference any new symbol from it.

**Read first:** the "Modifier order" section of the spec. The one non-obvious edit is that two *existing* modifiers swap relative order.

**Technique already validated — do not re-derive it.** The padding bracket rests on an undocumented SwiftUI hit-testing behavior, so it was falsified empirically before this plan was approved, using a throwaway probe inside the real container shape (`ScrollView` + `LazyVStack`, 50pt rows, 40pt spacing). The probe walked the hosted `NSView` tree for views with non-empty `registeredDraggedTypes` and compared bounds:

| | drop-registrant height | `NSHostingView.fittingSize.height` |
|---|---|---|
| control — `.onDrop` with no padding | **50.0** (= row height) | 140.0 |
| bracketed — `.padding(.bottom, 40)` → `.onDrop` → `.padding(.bottom, -40)` | **90.0** (= row + gap) | 140.0 |

Both halves hold: the drop region extends the full gap past the row, and the negative padding reclaims the layout space exactly (identical `fittingSize`, so siblings do not move). The probe was deleted rather than committed — it tested SwiftUI, not awesoMux. Step 9 below adds the equivalent guard against the *real* view instead.

Caveat to keep in mind: the probe measured the registered drag-destination view's bounds, not a delivered drag session. AppKit resolves drag destinations by hit-testing views with registered types, so a registrant spanning the gap is what "the region extends" means — but it is a proxy. The manual drag walk in Step 6 is not optional.

- [ ] **Step 1: Write the characterization test**

This test **passes on `main`** — that is expected and correct. `SidebarInsertionResolver` is already right; the bug is region geometry. This test pins the contract the geometry change depends on, so a future resolver change can't silently break it.

Add to `Tests/awesoMuxTests/SidebarInsertionResolverTests.swift`, inside the existing `SidebarInsertionResolverTests` struct:

```swift
    /// The inter-group gutter is reclaimed into the tile stack's drop region
    /// (SidebarGroupView's bottom padding bracket), so a drop y inside that
    /// gutter is resolved by the LIST delegate and must land as append. This is
    /// the contract that lets the geometry change need no index math.
    @Test("a drop y in the reclaimed inter-group gutter appends to the group")
    func gutterDropYAppendsToGroup() {
        // Two 30pt tiles with the comfortable 5pt stack spacing between them.
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 260, height: 30),
            "b": CGRect(x: 0, y: 35, width: 260, height: 30),
        ]
        let ids = ["a", "b"]
        let lastTileMaxY: CGFloat = 65
        let comfortableGroupStackSpacing: CGFloat = 14

        // Anywhere in the reclaimed gutter resolves to append (index 2).
        for offset in stride(from: CGFloat(1), through: comfortableGroupStackSpacing, by: 1) {
            #expect(
                SidebarInsertionResolver.insertionIndex(
                    forDropY: lastTileMaxY + offset,
                    orderedIDs: ids,
                    frames: frames
                ) == ids.count
            )
        }

        // The compact gutter is narrower but behaves identically.
        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: lastTileMaxY + 8,
                orderedIDs: ids,
                frames: frames
            ) == ids.count
        )
    }
```

- [ ] **Step 2: Run it and confirm it passes for the right reason**

Run: `./script/swift-test.sh --filter SidebarInsertionResolver`
Expected: PASS.

Sanity-check the reason rather than accepting the green: temporarily change the expectation to `== 0`, re-run, confirm it FAILS, then change it back. That proves the assertion is live and not vacuously true.

- [ ] **Step 3: Bracket the header's drop region**

In `Sources/awesoMux/Views/SidebarGroupView.swift`, the header currently reads (lines 131-194, abridged):

```swift
            SidebarGroupHeaderRow(...)
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering && displayMode != .collapsed,
                    delegate: SidebarWorkspaceHeaderDropDelegate(...)
                )
                .overlay(alignment: .bottom) {
                    if activeDragKind == .workspace && !isFiltering && headerWorkspaceDropTargeted {
                        SidebarInsertionIndicator(tint: tint.hue)
                            .offset(y: SidebarInsertionIndicator.height / 2)
                            .allowsHitTesting(false)
                    }
                }
```

Reorder so the overlay precedes the padding bracket, and wrap only `.sidebarDrop`:

```swift
            SidebarGroupHeaderRow(...)
                // Indicator first: it anchors to the header's REAL bottom edge.
                // Below the padding it would anchor to the padded bottom and
                // draw `sessionStackSpacing` too low.
                .overlay(alignment: .bottom) {
                    if activeDragKind == .workspace && !isFiltering && headerWorkspaceDropTargeted {
                        SidebarInsertionIndicator(tint: tint.hue)
                            .offset(y: SidebarInsertionIndicator.height / 2)
                            .allowsHitTesting(false)
                    }
                }
                // Reach down through the header→first-tile gap so a workspace
                // drag crossing it never hits dead space (which fires
                // dropExited and blinks the insertion indicator out mid-aim).
                // Bottom-only keeps the origin put; the negative padding below
                // reclaims the layout space so nothing visually moves.
                .padding(.bottom, density.sessionStackSpacing)
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering && displayMode != .collapsed,
                    delegate: SidebarWorkspaceHeaderDropDelegate(...)
                )
                .padding(.bottom, -density.sessionStackSpacing)
```

Keep the `SidebarWorkspaceHeaderDropDelegate(...)` argument list byte-identical — only the modifier order and the two padding lines change.

- [ ] **Step 4: Bracket the tile stack's drop region**

The tile stack currently ends (lines 307-373, abridged):

```swift
                .coordinateSpace(name: coordinateSpaceName)
                .animation(structuralAnimation, value: sessionIDs)
                .onPreferenceChange(SidebarRowFramePreferenceKey.self) { ... }
                .onChange(of: sessionIDs) { ... }
                .overlay(alignment: .topLeading) { ... }
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering,
                    delegate: SidebarWorkspaceListDropDelegate(...)
                )
```

Add the bracket around `.sidebarDrop` only:

```swift
                .coordinateSpace(name: coordinateSpaceName)
                .animation(structuralAnimation, value: sessionIDs)
                .onPreferenceChange(SidebarRowFramePreferenceKey.self) { ... }
                .onChange(of: sessionIDs) { ... }
                .overlay(alignment: .topLeading) { ... }
                // Reach down through the inter-group gutter (LazyVStack spacing
                // in SidebarView owns it and its only delegate rejects workspace
                // drags), so a cross-group drag stays over a live target the
                // whole way. Bottom-only: row frames are measured in
                // `.named(coordinateSpaceName)` while DropInfo.location is
                // relative to this view, and padding only the bottom leaves the
                // shared top-left origin untouched — so no hit-test math moves.
                // `.padding(.top,)` here would offset every drop by half a gap.
                .padding(.bottom, density.groupStackSpacing)
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering,
                    delegate: SidebarWorkspaceListDropDelegate(...)
                )
                // Reclaim the space: keeping the reported frame identical means
                // collapsed groups keep their gutter (their tile stack isn't
                // rendered at all) and SidebarGroupFramePreferenceKey still
                // reports unchanged group frames, so group-reorder midY flip
                // points don't move.
                .padding(.bottom, -density.groupStackSpacing)
```

Do **not** change `LazyVStack(spacing: density.groupStackSpacing)` in `SidebarView.swift:191`. Do **not** change the outer `VStack(alignment: .leading, spacing: density.sessionStackSpacing)` at line 122.

- [ ] **Step 5: Run the sidebar suite**

Run: `./script/swift-test.sh --filter Sidebar`
Expected: PASS, including `SidebarGroupHeaderHitTargetTests`.

Do **not** treat those hit-target tests as the detector for a failed reclaim. They pass `entries: []` and assert points on a header anchored at the *top* of the group, so a downward overflow may move nothing they measure. They are a guard against gross breakage only. Step 9 adds the real detector.

- [ ] **Step 6: Build and verify manually**

Run: `./script/build_and_run.sh`

Walk this script and record the result in the commit body:

1. Create two workspace groups, each with two or more workspaces, sidebar expanded.
2. Drag a workspace from group A toward group B slowly, crossing the gap between the groups. **The insertion indicator must stay visible continuously** — on `main` it blinks off while the pointer is in the gap.
3. Release in the gap below group A's last tile. It must land at the END of group A.
4. Release on group B's header. It must land at the TOP of group B (unchanged behavior).
5. Confirm the indicator under a targeted header still draws flush at the header's bottom edge, not several points below it — this is the modifier-order check from Step 3.
6. Collapse group A. Confirm the visual gap between it and group B is unchanged.
7. Drag a group header to reorder groups. Confirm the flip points feel unchanged.
8. Repeat step 2 in compact density (8pt gutter) to confirm both density values work.

- [ ] **Step 7: Add the geometry regression guard**

Nothing automated currently proves either half of the bracket against the real view. The padding bracket depends on undocumented SwiftUI behavior, so a future macOS or Swift toolchain could silently revert papercut 2 with a green suite. Guard the actual `SidebarGroupView`, not a synthetic stand-in.

Create `Tests/awesoMuxTests/SidebarGroupDropRegionTests.swift`. Build the group via the same `SidebarGroupHitTargetHarness`-style construction used in `SidebarGroupHeaderHitTargetTests` (populate `entries` with two sessions so the tile stack has real frames), host it, then walk for drag registrants:

```swift
    /// Papercut 2 (#220) extends the tile stack's drop region down through the
    /// inter-group gutter using a padding bracket around `.sidebarDrop`, then
    /// reclaims the layout space with negative padding. Both halves rest on
    /// undocumented SwiftUI hit-testing behavior, so assert them directly: a
    /// toolchain change that clips the overflow, or drops the reclaim, would
    /// otherwise revert the fix with a green suite.
    private static func dropRegistrantHeights(in root: NSView) -> [CGFloat] {
        var heights: [CGFloat] = []
        func walk(_ view: NSView) {
            if !view.registeredDraggedTypes.isEmpty {
                heights.append(view.bounds.height)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return heights
    }
```

Assert two things:

1. **The region extends.** With a workspace drag active (`activeDragKind: .workspace`, non-nil `activeDragID` — the `.sidebarDrop` modifier is gated on those, so a registrant only exists while a drag is live), the tallest drag registrant must exceed the tile stack's own content height by `density.groupStackSpacing`. Derive the expected value from the harness's density rather than hardcoding 14.
2. **The space is reclaimed.** The hosting view's `fittingSize.height` must equal the height measured with the bracket's two padding lines removed. Since you cannot have both trees in one test, assert against an explicit expected total instead: header height + tile heights + stack spacings, with **no** `groupStackSpacing` term. Compute it from the same density constants the view uses so the number is derived, not magic.

Run: `./script/swift-test.sh --filter SidebarGroupDropRegion`
Expected: PASS. Then temporarily delete the `.padding(.bottom, -density.groupStackSpacing)` line, re-run, and confirm assertion 2 FAILS — that proves the guard is live rather than vacuously true. Restore the line.

- [ ] **Step 8: Lint the touched files**

Run: `script/format.sh --lint Sources/awesoMux/Views/SidebarGroupView.swift Tests/awesoMuxTests/SidebarInsertionResolverTests.swift Tests/awesoMuxTests/SidebarGroupDropRegionTests.swift`

Expected: no findings. Read the output — `--lint` exits 0 with warnings.

- [ ] **Step 9: Commit**

```bash
git add Sources/awesoMux/Views/SidebarGroupView.swift Tests/awesoMuxTests/SidebarInsertionResolverTests.swift Tests/awesoMuxTests/SidebarGroupDropRegionTests.swift
git commit -m "fix(sidebar): reclaim dead bands so cross-group drags stay on target"
```

Include in the commit body: the manual verification results from Step 6, and the sentence "Automated coverage is the resolver characterization test only — SidebarHostedTestHarness has no synthetic drag support."

---

### Task 3: Mount the new-workspace row in populated groups

**Files:**
- Create: `Sources/awesoMux/Views/NewWorkspaceInGroupRowPolicy.swift`
- Create: `Tests/awesoMuxTests/NewWorkspaceInGroupRowPolicyTests.swift`
- Modify: `Sources/awesoMux/Views/SidebarDropDelegates.swift:473-595`
- Modify: `Sources/awesoMux/Views/SidebarGroupView.swift:288-305`
- Modify: `Sources/awesoMux/Views/SidebarGroupHeaderView.swift` (one comment)
- Modify: `Tests/awesoMuxTests/SidebarGroupHeaderHitTargetTests.swift:177-330`

**Interfaces:**
- Consumes: the padded tile-stack region from Task 2 (geometry only, no symbol).
- Produces:
  - `enum NewWorkspaceInGroupRowPolicy` with three `static` methods:
    - `showsRemoveButton(isGroupEmpty: Bool, canRemoveGroup: Bool) -> Bool`
    - `showsRestingBorder(isGroupEmpty: Bool) -> Bool`
    - `dropInsertionIndex(isGroupEmpty: Bool) -> Int`
  - `struct NewWorkspaceInGroupRow` (renamed from `EmptyGroupDropTarget`), gaining a `showsRestingBorder: Bool` stored property.

- [ ] **Step 1: Write the failing policy test**

Create `Tests/awesoMuxTests/NewWorkspaceInGroupRowPolicyTests.swift`:

```swift
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("NewWorkspaceInGroupRowPolicy")
struct NewWorkspaceInGroupRowPolicyTests {
    /// The row is the empty group's only always-visible removal path, so it
    /// keeps the X there. A populated group already has the header's hover X —
    /// two pointer paths to the same destructive action is one too many.
    @Test("only an empty group shows the row's remove button")
    func onlyEmptyGroupShowsRemoveButton() {
        #expect(
            NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: true,
                canRemoveGroup: true
            )
        )
        #expect(
            !NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: false,
                canRemoveGroup: true
            )
        )
        // An empty group that cannot be removed (the store refuses to remove
        // the last group) still gets no dead control.
        #expect(
            !NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                isGroupEmpty: true,
                canRemoveGroup: false
            )
        )
    }

    /// The dashed border is the empty group's "there's nothing here" cue. Once
    /// there are tiles above it, one dashed box per group reads as noise, so the
    /// row rests borderless and lights up only under an active drag.
    @Test("only an empty group shows a resting border")
    func onlyEmptyGroupShowsRestingBorder() {
        #expect(NewWorkspaceInGroupRowPolicy.showsRestingBorder(isGroupEmpty: true))
        #expect(!NewWorkspaceInGroupRowPolicy.showsRestingBorder(isGroupEmpty: false))
    }

    /// The row sits at the BOTTOM of a populated group, so its drop has to
    /// append — index 0 would contradict where the row visually is. An empty
    /// group has no tiles, so 0 and append are the same position; 0 is used
    /// there because it matches the existing shipped behavior.
    @Test("drop index matches where the row sits")
    func dropIndexMatchesRowPosition() {
        #expect(NewWorkspaceInGroupRowPolicy.dropInsertionIndex(isGroupEmpty: true) == 0)
        #expect(
            NewWorkspaceInGroupRowPolicy.dropInsertionIndex(isGroupEmpty: false)
                == SessionStore.appendIndex
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/swift-test.sh --filter NewWorkspaceInGroupRowPolicy`
Expected: FAIL to compile — `cannot find 'NewWorkspaceInGroupRowPolicy' in scope`.

- [ ] **Step 3: Write the policy**

Create `Sources/awesoMux/Views/NewWorkspaceInGroupRowPolicy.swift`:

```swift
import AwesoMuxCore

/// The three ways the `+ new workspace` row differs between an empty group and
/// a populated one. Hoisted out of the call site so the differences live in one
/// reviewable place instead of three ternaries in `SidebarGroupView.body`
/// (same reason `SidebarGroupClosePolicy` exists).
enum NewWorkspaceInGroupRowPolicy {
    /// The row's persistent remove-group X.
    ///
    /// An empty group has no tiles and its header X is hover-only, so the row
    /// is its only always-visible removal path. A populated group already has
    /// the header's hover X, and two pointer paths to the same destructive
    /// action invites the wrong one being clicked.
    static func showsRemoveButton(isGroupEmpty: Bool, canRemoveGroup: Bool) -> Bool {
        isGroupEmpty && canRemoveGroup
    }

    /// The dashed resting border.
    ///
    /// It reads as "there's nothing here" for an empty group. With tiles above
    /// it, one dashed box per group is visual noise, so the row rests
    /// borderless and only lights up while drag-targeted.
    static func showsRestingBorder(isGroupEmpty: Bool) -> Bool {
        isGroupEmpty
    }

    /// Where a workspace dropped on the row lands.
    ///
    /// The row sits at the bottom of a populated group, so it must append —
    /// inserting at 0 would contradict the row's own position. An empty group
    /// has no tiles, so 0 and append name the same slot; 0 preserves the
    /// shipped behavior.
    static func dropInsertionIndex(isGroupEmpty: Bool) -> Int {
        isGroupEmpty ? 0 : SessionStore.appendIndex
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./script/swift-test.sh --filter NewWorkspaceInGroupRowPolicy`
Expected: PASS

- [ ] **Step 5: Commit the policy**

```bash
git add Sources/awesoMux/Views/NewWorkspaceInGroupRowPolicy.swift Tests/awesoMuxTests/NewWorkspaceInGroupRowPolicyTests.swift
git commit -m "feat(sidebar): add new-workspace row policy for empty vs populated groups"
```

- [ ] **Step 6: Rename the view and add the border parameter**

In `Sources/awesoMux/Views/SidebarDropDelegates.swift`, rename `struct EmptyGroupDropTarget` to `struct NewWorkspaceInGroupRow` and add one stored property beside the existing ones:

```swift
struct NewWorkspaceInGroupRow: View {
    let isFiltering: Bool
    /// Renamed from `canRemoveGroup`: the value passed in is now a presentation
    /// decision (`NewWorkspaceInGroupRowPolicy.showsRemoveButton`), not the
    /// store's removal capability. Keeping the old name would invite a future
    /// caller to pass the raw capability and reintroduce a second X on
    /// populated groups, which already have the header's hover X.
    let showsRemoveButton: Bool
    /// False for a populated group — see `NewWorkspaceInGroupRowPolicy`.
    let showsRestingBorder: Bool
    let activeDragKind: SidebarDragKind?
    // ...remaining properties unchanged...
```

Update the two `if canRemoveGroup` uses inside the view's body (the trailing-space reservation at line 506 and the sibling X overlay at line 534) to `if showsRemoveButton`.

Change the `.overlay` stroke (currently lines 515-526) so the resting stroke can be suppressed while the drag-targeted stroke is untouched:

```swift
                .overlay {
                    let isDropLit = activeDragKind == .workspace && isDropTargeted
                    if isDropLit || showsRestingBorder {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                isDropLit
                                    ? Color.aw.mauve.opacity(0.90)
                                    : Color.aw.border2.opacity(0.75),
                                style: StrokeStyle(
                                    lineWidth: isDropLit ? 1.25 : 0.75,
                                    dash: [3, 3]
                                )
                            )
                    }
                }
```

Update the `accessibilityLabel` on line 530 so it isn't a lie in a populated group:

```swift
            .accessibilityLabel(String(
                localized: "New workspace in group",
                comment: "VoiceOver label for the row that creates a workspace in a sidebar group."
            ))
```

Leave the `SidebarEmptyWorkspaceDropDelegate` type name alone — it is a separate type and renaming it is out of scope.

- [ ] **Step 7: Fix the one stale comment reference**

Run: `grep -rn 'EmptyGroupDropTarget' Sources/ Tests/`

Update every hit to `NewWorkspaceInGroupRow`. There is a prose reference in `Sources/awesoMux/Views/SidebarGroupHeaderView.swift` (in the `SidebarGroupClosePolicy` doc comment, which says "`EmptyGroupDropTarget`'s persistent remove button stays as the always-visible removal path"). That sentence is now only true for empty groups — amend it to say so:

```
///   `NewWorkspaceInGroupRow`'s persistent remove button stays as the
///   always-visible removal path for an EMPTY group; a populated group's row
///   omits it so this X is the sole pointer path there.
```

- [ ] **Step 8: Mount the row unconditionally at the call site**

In `Sources/awesoMux/Views/SidebarGroupView.swift`, replace the conditional mount (lines 288-305) with:

```swift
                    // Hidden while filtering: the row's drop delegate already
                    // refuses filtered drags, but its BUTTON would still fire —
                    // creating a workspace that instantly fails the active
                    // filter and vanishes, which reads as a broken click. A
                    // create affordance that produces invisible results is
                    // worse than no affordance.
                    if displayMode != .collapsed, !isFiltering {
                        let isGroupEmpty = sessions.isEmpty
                        NewWorkspaceInGroupRow(
                            isFiltering: isFiltering,
                            showsRemoveButton: NewWorkspaceInGroupRowPolicy.showsRemoveButton(
                                isGroupEmpty: isGroupEmpty,
                                canRemoveGroup: canRemoveGroup
                            ),
                            showsRestingBorder: NewWorkspaceInGroupRowPolicy.showsRestingBorder(
                                isGroupEmpty: isGroupEmpty
                            ),
                            activeDragKind: activeDragKind,
                            activeDragID: activeDragID,
                            activeDragSourceIsPinned: activeDragSourceIsPinned,
                            verticalPadding: density.emptyGroupVerticalPadding,
                            onNewSessionInGroup: onNewSessionInGroup,
                            onRemoveGroup: onRemoveGroup,
                            onDragRefreshed: onDragRefreshed,
                            onDragEnded: onDragEnded,
                            onDragExited: onDragExited,
                            onAcceptDrop: { sessionID in
                                onMoveSession(
                                    sessionID,
                                    group.id,
                                    NewWorkspaceInGroupRowPolicy.dropInsertionIndex(
                                        isGroupEmpty: isGroupEmpty
                                    )
                                )
                            }
                        )
                    }
```

Note the `sessions.isEmpty && displayMode != .collapsed` condition becomes `displayMode != .collapsed` — the collapsed rail still renders no row.

- [ ] **Step 9: Add an `entries` parameter to the existing test harness**

In `Tests/awesoMuxTests/SidebarGroupHeaderHitTargetTests.swift`, the private `SidebarGroupHitTargetHarness` hardcodes `entries: []`, so every existing test exercises only the empty-group path. Add a stored property and thread it through:

```swift
private struct SidebarGroupHitTargetHarness: View {
    let group: SessionGroup
    let entries: [SidebarSessionEntry]
    let allGroups: [SessionGroup]
    // ...remaining properties unchanged...
```

and in `body`, change `entries: []` to `entries: entries`.

Then in the private `makeWindow` helper, add a parameter defaulting to the current behavior so **no existing call site changes**:

```swift
    private static func makeWindow(
        isCollapsed: Bool = false,
        displayMode: SidebarWidthMode = .expanded,
        width: CGFloat = SidebarWidthPolicy.expandedWidth,
        isGroupEmpty: Bool = false,
        entries: [SidebarSessionEntry] = [],
        totalGroupCount: Int = 1,
        // ...remaining parameters unchanged...
```

and pass `entries: entries` into `SidebarGroupHitTargetHarness(...)`.

- [ ] **Step 10: Write the failing hosted test**

Add to the `SidebarGroupHeaderHitTargetTests` struct:

```swift
    @Test("populated group's new-workspace row creates a workspace")
    func populatedGroupNewWorkspaceRowCreatesWorkspace() {
        let newWorkspaceCounter = ToggleCounter()
        let session = TerminalSession(
            id: UUID(uuidString: "0B1B7A26-0F1A-4F4D-9C41-2C6E9F0F41A2")!,
            title: "Populated workspace",
            workingDirectory: "~"
        )
        let window = Self.makeWindow(
            entries: [SidebarSessionEntry(session: session, match: nil)],
            onToggle: {},
            onNewSessionInGroup: newWorkspaceCounter.increment
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.populatedGroupNewWorkspaceRowPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { newWorkspaceCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(newWorkspaceCounter.count == 1)
    }
```

and a click-point constant beside the existing ones (around line 175):

```swift
    /// The row sits below the header and the single session tile. Y is measured
    /// from the harness window's bottom edge, matching the other constants here.
    private static let populatedGroupNewWorkspaceRowPoint = CGPoint(x: 100, y: 20)
```

`SidebarSessionEntry` is declared in `Sources/AwesoMuxCore/Search/SidebarSearchProjection.swift:68` with exactly `public init(session: TerminalSession, match: SessionMatch?)`, so `SidebarSessionEntry(session: session, match: nil)` is correct as written.

- [ ] **Step 11: Run the test and calibrate the click point**

Run: `./script/swift-test.sh --filter populatedGroupNewWorkspaceRow`

Expected on the first run: FAIL, because `y: 20` is a guess. The other constants in this file use a bottom-origin coordinate space (`y: 68` is the header, `y: 30` the empty-group row in a shorter window). Calibrate: the populated window is one tile taller, so the row sits lower in view coordinates and therefore at a *smaller* bottom-origin y than the empty case. Adjust in 8pt steps until it passes, then confirm the value is inside the row and not on the tile above it by checking that a point 30pt higher does **not** increment the counter.

Expected after calibration: PASS.

- [ ] **Step 12: Run the sidebar suite**

Run: `./script/swift-test.sh --filter Sidebar`
Expected: PASS — including the pre-existing `collapsedEmptyGroupActionPoint` tests, which must be unaffected since `makeWindow`'s new parameter defaults to `[]`.

- [ ] **Step 13: Build and verify manually**

Run: `./script/build_and_run.sh`

1. A populated group shows a borderless faint `+ new workspace` row at its bottom; an empty group still shows the dashed version.
2. Clicking the row in a populated group creates a workspace in that group.
3. The populated group's row has no X; the empty group's still does.
4. Drag a workspace over a populated group's row — the border lights mauve and the insertion line hides. Release: the workspace lands at the END of that group.
5. Collapse a group: no row appears.
6. Judgement call for eD: with several groups open, does one faint row per group read as clutter? If yes, the spec's documented fallback is gating visibility to group hover — flag it rather than implementing it.

- [ ] **Step 14: Lint the touched files**

Run: `script/format.sh --lint Sources/awesoMux/Views/SidebarDropDelegates.swift Sources/awesoMux/Views/SidebarGroupView.swift Sources/awesoMux/Views/SidebarGroupHeaderView.swift Tests/awesoMuxTests/SidebarGroupHeaderHitTargetTests.swift`

Expected: no findings. Read the output.

- [ ] **Step 15: Commit**

```bash
git add Sources/awesoMux/Views/SidebarDropDelegates.swift Sources/awesoMux/Views/SidebarGroupView.swift Sources/awesoMux/Views/SidebarGroupHeaderView.swift Tests/awesoMuxTests/SidebarGroupHeaderHitTargetTests.swift
git commit -m "feat(sidebar): offer new workspace inside populated groups"
```

---

### Task 4: Workspace title commit resolver

**Files:**
- Create: `Sources/awesoMux/Views/WorkspaceTitleCommit.swift`
- Create: `Tests/awesoMuxTests/WorkspaceTitleCommitTests.swift`

**Interfaces:**
- Consumes: `SessionStore.sanitizedTitle(_:)` — a `public nonisolated static func` on `SessionStore` (`SessionStore+Facade.swift:85`).
- Produces:
  - `enum WorkspaceTitleCommit: Equatable { case rename(String); case noChange }`
  - `static func resolveWorkspaceTitleCommit(input: String, current: String) -> WorkspaceTitleCommit`, declared `nonisolated` on `WorkspaceTitleCommit` so Task 5 can call it from the view and the test can call it off the main actor.

Note the deliberate difference from `PaneTitleBarView.resolveCommit`: a pane has a live terminal-supplied title to fall back to, so blank input means `.reset` and that resolver has three cases. A workspace has no live source, so blank input is rejected — two cases. Do not try to reuse the pane resolver.

- [ ] **Step 1: Write the failing test**

Create `Tests/awesoMuxTests/WorkspaceTitleCommitTests.swift`:

```swift
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("WorkspaceTitleCommit")
struct WorkspaceTitleCommitTests {
    /// A workspace title has no live terminal-supplied fallback (unlike a pane),
    /// so a blank commit cannot mean "reset" — it must leave the title alone.
    @Test("blank and whitespace-only input never renames")
    func blankInputNeverRenames() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "", current: "Old")
                == .noChange
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "   ", current: "Old")
                == .noChange
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "\t\n ", current: "Old")
                == .noChange
        )
    }

    /// Committing without editing must not write to the store — a redundant
    /// rename would churn persistence and any attention bookkeeping keyed on it.
    @Test("unchanged input does not rename")
    func unchangedInputDoesNotRename() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "Same", current: "Same")
                == .noChange
        )
        // Sanitizing is applied before comparison, so trailing whitespace is
        // still "unchanged" rather than a rename to an identical string.
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "Same  ", current: "Same")
                == .noChange
        )
    }

    /// The stored title is the sanitized form, not the raw keystrokes.
    @Test("changed input renames with the sanitized title")
    func changedInputRenamesWithSanitizedTitle() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "New name", current: "Old")
                == .rename("New name")
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "  Padded  ", current: "Old")
                == .rename(SessionStore.sanitizedTitle("  Padded  "))
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/swift-test.sh --filter WorkspaceTitleCommit`
Expected: FAIL to compile — `cannot find 'WorkspaceTitleCommit' in scope`.

- [ ] **Step 3: Write the resolver**

Create `Sources/awesoMux/Views/WorkspaceTitleCommit.swift`:

```swift
import AwesoMuxCore

/// What a committed inline workspace-title edit means.
///
/// Two cases, not three: unlike a pane — which has a live terminal-supplied
/// title to fall back to, so blank input there means "reset" — a workspace title
/// has no live source. Blank input is therefore rejected rather than clearing
/// the name, which is why this does not reuse `PaneTitleBarView.resolveCommit`.
enum WorkspaceTitleCommit: Equatable {
    case rename(String)
    case noChange

    /// - blank / whitespace-only → no change (nothing to fall back to)
    /// - sanitizes to the current title → no change (no redundant store write)
    /// - otherwise → rename with the sanitized title
    ///
    /// `nonisolated` so the pure logic is callable off the main actor; the view
    /// is implicitly `@MainActor` and the unit test exercises this directly.
    nonisolated static func resolveWorkspaceTitleCommit(
        input: String,
        current: String
    ) -> WorkspaceTitleCommit {
        let sanitized = SessionStore.sanitizedTitle(input)
        if sanitized.isEmpty {
            return .noChange
        }
        if sanitized == SessionStore.sanitizedTitle(current) {
            return .noChange
        }
        return .rename(sanitized)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./script/swift-test.sh --filter WorkspaceTitleCommit`
Expected: PASS

- [ ] **Step 5: Lint the touched files**

Run: `script/format.sh --lint Sources/awesoMux/Views/WorkspaceTitleCommit.swift Tests/awesoMuxTests/WorkspaceTitleCommitTests.swift`

Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add Sources/awesoMux/Views/WorkspaceTitleCommit.swift Tests/awesoMuxTests/WorkspaceTitleCommitTests.swift
git commit -m "feat(titlebar): add commit resolver for inline workspace rename"
```

---

### Task 5: Inline rename in the titlebar workspace cluster

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift:555-830`
- Modify: `Tests/awesoMuxTests/SidebarHostedTestHarness.swift` (add `sendDoubleClick`)
- Test: `Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift` (create)

**Interfaces:**
- Consumes: `WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input:current:)` from Task 4.
- Produces: nothing later tasks rely on. Final task.

Two visibility changes are needed so the behavior is testable. `AppTitlebarView` and `WindowDragRenameHandle` are both `private` in `ContentView.swift` and are used only within that file, so dropping the keyword is sufficient — no other call site changes.

- [ ] **Step 1: Add a double-click helper to the harness**

`SidebarHostedTestHarness.sendClick` hardcodes `clickCount: 1`, and `WindowDragRenameHandle.DragRegionView.mouseDown` branches on `event.clickCount >= 2`, so the existing helper cannot exercise this path. Add to `SidebarHostedTestHarness` in `Tests/awesoMuxTests/SidebarHostedTestHarness.swift`:

```swift
    /// A single `mouseDown` carrying `clickCount: 2`. AppKit views that branch
    /// on `clickCount` (the titlebar rename handle, the pane drag source) read
    /// the count off the event, so one event is enough — no inter-click timing
    /// to reproduce.
    static func sendDoubleClick(to view: NSView, at location: CGPoint, in window: NSWindow) {
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 2,
                pressure: 1
            )
        else { return }
        view.mouseDown(with: event)
        settleMainRunLoop()
    }
```

Delivering directly to the view avoids guessing the cluster's window coordinates, which depend on `AppTitlebarLayoutGeometry`'s sidebar-reservation math.

- [ ] **Step 2: Drop `private` from the two types**

In `Sources/awesoMux/Views/ContentView.swift`:

```swift
// line 555
struct AppTitlebarView: View {
```

```swift
// line 766
struct WindowDragRenameHandle: NSViewRepresentable {
```

Both are referenced only inside `ContentView.swift`, so nothing else changes. `WindowDragRenameHandle.tooltip` is already a `static let` and becomes reachable from tests, which is how the test locates the drag region.

- [ ] **Step 3: Write the failing test**

Create `Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift`:

```swift
import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct AppTitlebarInlineRenameTests {
    /// Double-clicking the titlebar workspace name must edit in place, not ask
    /// the app to present `WorkspaceEditSheet`. `onRenameWorkspace` is the sheet
    /// request, so it staying at zero is the observable proof the modal path is
    /// gone. (The sidebar context-menu path still uses that closure — this test
    /// only pins the titlebar caller.)
    @Test("titlebar double-click edits inline instead of requesting the sheet")
    func titlebarDoubleClickDoesNotRequestSheet() throws {
        let renameRequests = ToggleCounter()
        let session = TerminalSession(
            id: UUID(uuidString: "F2F1D0C9-4A21-4C0E-9E3B-7B4A2D6E5F10")!,
            title: "Original title",
            workingDirectory: "~"
        )
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: AppTitlebarView(
                session: session,
                onRenameWorkspace: { _ in renameRequests.increment() },
                sidebarPosition: .left,
                hostPresentation: SidebarHostPresentationState()
            )
            .environment(AppSettingsStore(legacySnapshotProvider: { nil })),
            frame: NSRect(x: 0, y: 0, width: 900, height: AwSpacing.titlebar)
        )
        defer { hosted.window.close() }

        let dragRegion = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSView.self,
                in: hosted.hostingView,
                where: { $0.toolTip == WindowDragRenameHandle.tooltip }
            )
        )

        SidebarHostedTestHarness.sendDoubleClick(
            to: dragRegion,
            at: CGPoint(x: dragRegion.bounds.midX, y: dragRegion.bounds.midY),
            in: hosted.window
        )

        #expect(renameRequests.count == 0)
    }
}

private final class ToggleCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `./script/swift-test.sh --filter AppTitlebarInlineRename`
Expected: FAIL — `renameRequests.count == 1`, because the titlebar still routes the double-click to `onRenameWorkspace`.

If it fails instead with `#require` finding no drag region, the handle isn't in the hosted tree — confirm `session` is non-nil (the cluster only renders under `if let session`) and that the frame width is wide enough for `contentColumn`'s leading padding to leave the cluster on screen.

- [ ] **Step 5: Add the edit state to `AppTitlebarView`**

Add beside the existing `@Environment(\.awAccent)` declaration (around line 578):

```swift
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFieldFocused: Bool
```

- [ ] **Step 6: Swap the label for a field while editing**

Replace `workspaceCluster`'s `Text(session.title)` (line 728) with a conditional, and gate the drag handle overlay so the field keeps first responder:

```swift
    private func workspaceCluster(_ session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.aw.accent(accentResolver.accent))
                .accessibilityHidden(true)

            if isEditingTitle {
                TextField("Workspace name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .focused($isTitleFieldFocused)
                    .lineLimit(1)
                    // A content-sized field jitters wider on every keystroke;
                    // the cap keeps it from reaching for the window edge.
                    .frame(minWidth: 160, idealWidth: 280, maxWidth: 420)
                    .onSubmit { commitTitle(for: session) }
                    .onExitCommand { isEditingTitle = false }
                    // Clicking away commits rather than stranding the titlebar
                    // in edit mode with the window-drag handle suppressed.
                    // `commitTitle` guards on `isEditingTitle`, so the focus loss
                    // that ⏎/esc themselves cause cannot double-fire.
                    .onChange(of: isTitleFieldFocused) { _, focused in
                        if !focused { commitTitle(for: session) }
                    }
                    .onAppear { isTitleFieldFocused = true }
            } else {
                Text(session.title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
            }
        }
        .overlay {
            // Suppressed while editing so the TextField keeps first responder —
            // the handle is the hit-test winner and would otherwise swallow
            // clicks meant for the field (same gating as PaneTitleBarView).
            if !isEditingTitle {
                WindowDragRenameHandle(onDoubleClick: { beginEditingTitle(session) })
                    // Fill the cluster: an NSViewRepresentable in an `.overlay`
                    // can otherwise collapse to its (zero) intrinsic size,
                    // leaving the name non-interactive.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .help("Drag to move window · double-click to rename")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        // Double-click is pointer-only; expose the same rename as a named
        // action so assistive-tech users reach it too (mirrors the sidebar tile).
        .accessibilityAction(named: "Rename Workspace") {
            beginEditingTitle(session)
        }
    }
```

**The stale-edit guard does NOT go here.** See Step 6b — putting it inside `workspaceCluster` is a data-corruption bug, not a style preference.

- [ ] **Step 6b: Put the stale-edit guard on the BODY, keyed on the optional**

`workspaceCluster` renders only under `if let session` (`ContentView.swift:697`). A guard placed inside it is destroyed the moment `session` becomes nil — so it cannot fire on the one transition that matters. Meanwhile `isEditingTitle` and `titleDraft` live on `AppTitlebarView` and survive. The sequence that corrupts data:

1. User double-clicks workspace A's title, types a new name.
2. Workspace A closes (or all workspaces close) → `session` becomes nil → `workspaceCluster` unmounts, taking any guard inside it with it.
3. Workspace B is selected → the cluster remounts with `isEditingTitle == true` and `titleDraft` still holding A's text, and `.onAppear` focuses the field.
4. The user presses ⏎ or clicks away → **workspace B is renamed to A's draft.**

Attach the guard to `AppTitlebarView`'s body instead, keyed on the optional so a nil transition also cancels. Add it to the `GeometryReader` chain in `body` (around line 593, beside `.frame(height: AwSpacing.titlebar)`):

```swift
        // Keyed on the OPTIONAL id, and on `body` rather than inside
        // `workspaceCluster`: that function only renders under `if let session`,
        // so a guard placed there is torn down by the very nil transition it
        // needs to catch — leaving a live draft to commit against whichever
        // workspace is selected next.
        .onChange(of: session?.id) { _, _ in
            isEditingTitle = false
            titleDraft = ""
        }
```

Clearing `titleDraft` too is belt-and-braces: `beginEditingTitle` always reseeds it, but leaving another workspace's text in state is exactly the condition this guard exists to eliminate.

- [ ] **Step 6c: Write the regression test for it**

Add to `Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift`:

```swift
    /// Closing a workspace mid-rename must not strand a live draft that then
    /// commits against the NEXT workspace. `isEditingTitle` lives on
    /// AppTitlebarView while the field lives inside `workspaceCluster`, which
    /// only renders under `if let session` — so the cancel has to be keyed on
    /// the optional at body level to survive a nil transition.
    @Test("a workspace closing mid-rename does not rename the next one")
    func closingWorkspaceMidRenameDoesNotRenameTheNext() throws {
        let workspaceA = TerminalSession(
            id: UUID(uuidString: "AA000000-0000-4000-8000-000000000001")!,
            title: "Workspace A",
            workingDirectory: "~"
        )
        let workspaceB = TerminalSession(
            id: UUID(uuidString: "BB000000-0000-4000-8000-000000000002")!,
            title: "Workspace B",
            workingDirectory: "~"
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Group", sessions: [workspaceA, workspaceB])],
            selectedSessionID: workspaceA.id,
            pinnedSessionIDs: []
        )
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: TitlebarRenameHarness(sessionStore: store)
                .environment(AppSettingsStore(legacySnapshotProvider: { nil })),
            frame: NSRect(x: 0, y: 0, width: 900, height: AwSpacing.titlebar)
        )
        defer { hosted.window.close() }

        let dragRegion = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSView.self,
                in: hosted.hostingView,
                where: { $0.toolTip == WindowDragRenameHandle.tooltip }
            )
        )
        SidebarHostedTestHarness.sendDoubleClick(
            to: dragRegion,
            at: CGPoint(x: dragRegion.bounds.midX, y: dragRegion.bounds.midY),
            in: hosted.window
        )

        // Simulate the workspace closing, then a different one being selected.
        store.selectedSessionID = nil
        SidebarHostedTestHarness.settleMainRunLoop()
        store.selectedSessionID = workspaceB.id
        SidebarHostedTestHarness.settleMainRunLoop()

        // B must keep its own name — neither A's title nor A's draft.
        #expect(store.session(id: workspaceB.id)?.title == "Workspace B")
    }
```

`TitlebarRenameHarness` is a small wrapper that reads `sessionStore.selectedSession` so the `session` parameter tracks store mutations (`AppTitlebarView` takes a plain value, so the test cannot mutate it directly):

```swift
private struct TitlebarRenameHarness: View {
    let sessionStore: SessionStore

    var body: some View {
        AppTitlebarView(
            session: sessionStore.selectedSession,
            sessionStore: sessionStore,
            onRenameWorkspace: { _ in },
            sidebarPosition: .left,
            hostPresentation: SidebarHostPresentationState()
        )
    }
}
```

Run it against the Step 6a code **before** adding the Step 6b guard and confirm it FAILS (B renamed to A's draft, or an unexpected title). Then add the guard and confirm it PASSES. If it passes before the guard exists, the test is not reproducing the sequence — check that `selectedSession` actually returns nil for a nil `selectedSessionID` and that the settle calls let SwiftUI re-render between mutations.

- [ ] **Step 7: Add the begin/commit methods**

Add to `AppTitlebarView`, beside `workspaceCluster`:

```swift
    private func beginEditingTitle(_ session: TerminalSession) {
        titleDraft = session.title
        isEditingTitle = true
    }

    private func commitTitle(for session: TerminalSession) {
        // Guard so the focus-loss `onChange` and ⏎ can't double-commit: the
        // first to fire flips the flag and the rest no-op.
        guard isEditingTitle else { return }
        defer { isEditingTitle = false }
        switch WorkspaceTitleCommit.resolveWorkspaceTitleCommit(
            input: titleDraft,
            current: session.title
        ) {
        case let .rename(title):
            sessionStore.renameSession(id: session.id, title: title)
        case .noChange:
            break
        }
    }
```

`AppTitlebarView` has no `sessionStore` today. `ContentView` holds it as `@Bindable var sessionStore: SessionStore` (`ContentView.swift:68`) and passes it explicitly into children (`sessionStore: sessionStore` at lines 359 and 393), so follow that: add a stored property to `AppTitlebarView` beside `session`,

```swift
    let sessionStore: SessionStore
```

and pass it at the call site (`ContentView.swift:327-332`):

```swift
            AppTitlebarView(
                session: sessionStore.selectedSession,
                sessionStore: sessionStore,
                onRenameWorkspace: onRenameWorkspace,
                sidebarPosition: sidebarPosition,
                hostPresentation: hostPresentation
            )
```

Then update the Step 3 test to construct one, matching `SidebarSearchInteractionTests.swift:239`:

```swift
        let store = SessionStore(
            groups: [SessionGroup(name: "Results", sessions: [session])],
            selectedSessionID: session.id,
            pinnedSessionIDs: []
        )
```

and pass `sessionStore: store` into `AppTitlebarView` in the test's `rootView`.

- [ ] **Step 8: Run the test to verify it passes**

Run: `./script/swift-test.sh --filter AppTitlebarInlineRename`
Expected: PASS

- [ ] **Step 9: Run the full suite**

Run: `./script/swift-test.sh`
Expected: PASS. `ContentView` is widely referenced, so a signature change to `AppTitlebarView` can break other hosted tests — fix any call sites the compiler flags.

- [ ] **Step 10: Build and verify manually — the two risk items**

Run: `./script/build_and_run.sh`

These two cannot be expressed as unit tests and are the reason this task ships as its own PR:

1. **First responder vs. the terminal surface.** `GhosttySurfaceContainerView` reclaims first responder only when the responder is vacant, and `PaneCloseButton` exists as a raw `NSButton` with `refusesFirstResponder` because a SwiftUI `Button` stealing focus broke that path. Double-click the workspace title, then type. **Every character must land in the field and none in the terminal.** Watch specifically for the surface yanking focus back mid-edit.
2. **Field width.** Type a long name and confirm the field does not grow per keystroke or stretch toward the window edge.

Then:

3. ⏎ commits and the titlebar shows the new name; the sidebar tile for that workspace shows it too.
4. esc cancels and the original name is intact.
5. Clicking the terminal commits the edit (does not strand edit mode).
6. Clicking the empty titlebar space beside the field starts a window drag and commits.
7. Blank the field and press ⏎ — the original title must remain, not an empty name.
8. Enter edit mode, then switch workspaces via the sidebar — no stale draft lands on the new workspace.
8b. Enter edit mode, then **close that workspace** and select a different one. The new workspace must keep its own name. This is the Step 6b/6c path; verify it by hand as well as in the test.
8c. Known and accepted (documented, not fixed): enter edit mode, type nothing, let an agent retitle the workspace via OSC, then click away. The commit compares the pre-edit draft against the new title and reverts the agent's retitle. `PaneTitleBarView` has the same shape today, so this is consistent rather than a new defect — but note it in the PR body so it isn't discovered as a surprise.
9. Sidebar context-menu "Rename" still opens `WorkspaceEditSheet` (that path is unchanged).
10. VoiceOver: the "Rename Workspace" rotor action still enters edit mode.

- [ ] **Step 11: Lint the touched files**

Run: `script/format.sh --lint Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarHostedTestHarness.swift Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift`

Expected: no findings. `ContentView.swift` is a large file — do **not** run `script/format.sh` on it without `--lint`; whole-file formatting explodes diffs in this repo.

- [ ] **Step 12: Commit**

```bash
git add Sources/awesoMux/Views/ContentView.swift Tests/awesoMuxTests/SidebarHostedTestHarness.swift Tests/awesoMuxTests/AppTitlebarInlineRenameTests.swift
git commit -m "feat(titlebar): rename a workspace inline instead of in a sheet"
```

Include the Step 10 results in the commit body, especially the focus-behavior outcome.

---

## Preflight before opening PRs

- [ ] Run `./script/preflight.sh` (required before any non-docs PR).
- [ ] Run `./script/swift-test.sh` once more on the final tree.
- [ ] Split into two PRs per the spec's sequencing: Tasks 1–3 (sidebar) and Tasks 4–5 (titlebar). Task 5 carries the focus-behavior risk and deserves its own revert boundary.
- [ ] AI assistance level for both PR templates: **substantial**.
- [ ] Both PRs link issue #220. The sidebar PR must carry the coverage-honesty sentence from Task 2.
- [ ] Use neutral review wording in all public text. No internal reviewer persona names.
