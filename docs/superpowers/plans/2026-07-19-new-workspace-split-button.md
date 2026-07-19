# New Workspace Split Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the sidebar's `+` control from a `Menu` (every click opens a dropdown, "New Workspace" is just its first row) into a real split button — a plain-click primary segment that instant-creates a workspace, plus a chevron segment exposing the deliberate actions (new workgroup, new workspace in a specific group).

**Architecture:** Single-file view restructuring. `NewWorkspaceMenuButton` becomes an `HStack` of two independently-hoverable segments sharing one rounded-rect pill background: a plain `Button` (primary) and a `Menu` (chevron). No other file needs to change — the component's public init signature (`size`, `cornerRadius`, `restFill`, `otherGroups`, `onNewWorkspace`, `onNewWorkspaceInGroup`, `onNewWorkspaceGroup`) is unchanged, so both call sites in `SidebarView.swift` (collapsed rail, expanded header) need zero edits.

**Tech Stack:** SwiftUI (macOS 15+ target — `UnevenRoundedRectangle` is safe to use), swift-testing, the existing `SidebarHostedTestHarness` AppKit click-simulation helper.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-19-new-workspace-split-button-design.md` (approved).
- The three underlying actions (`onNewWorkspace`, `onNewWorkspaceInGroup`, `onNewWorkspaceGroup`) do not change behavior — this is a layout/entry-point change only.
- `otherGroups` stays unfiltered exactly as it is today (it already includes the current group — the property name is a slight misnomer, pre-existing, not this plan's problem to fix). Do not add current-group filtering.
- Chevron menu is **up to 2 rows** — 1 when the user has no other groups yet, 2 otherwise — in this order: **"New Workgroup…" first, then "New Workspace in ▶" second** (order flipped from spec's first draft per eD's explicit call — flagged low-confidence, may get flipped back later). The group list itself stays behind the nested submenu, never flattened to the top level.
- No naming prompt anywhere in this change — both instant-creation paths (primary click, "New Workspace in [Group]") stay unnamed, matching current behavior exactly.
- No changes to `WorkspaceGroupCreateSheet`, `RemoteWorkspaceGroupCreateSheet`, `WorktreeCreateForm`, or the `SessionGroup` model.
- Conventional Commits: `<type>(<scope>): <lowercase imperative>`, subject ≤72 chars, no period.
- `main` is protected — this work continues on the `docs/new-workspace-split-button-design` branch (already checked out, currently holds the spec and plan commits).
- Splitting one focusable control into two changes keyboard Tab order for this control (one stop → two). This control isn't wired into the sidebar's custom `SidebarVisibleRowTarget` focus system, so this is an accepted, low-severity, unremarkable side effect of the redesign — noted here so it doesn't read as an oversight.

---

### Task 1: Rewrite `NewWorkspaceMenuButton` as a split button

**Files:**
- Modify: `Sources/awesoMux/Views/NewWorkspaceMenuButton.swift:1-74` (full body rewrite; the two call sites in `Sources/awesoMux/Views/SidebarView.swift:669-682` and `:743-752` are unchanged — same init signature)

**Interfaces:**
- Consumes: nothing new — same three callbacks and four config properties the component already receives from `SidebarView.swift`.
- Produces: `NewWorkspaceMenuButton` with unchanged public init signature `(size: CGFloat, cornerRadius: CGFloat, restFill: Color, otherGroups: [(id: SessionGroup.ID, name: String)], onNewWorkspace: () -> Void, onNewWorkspaceInGroup: (SessionGroup.ID) -> Void, onNewWorkspaceGroup: () -> Void)`. Task 2's tests construct this view directly using this signature.

There's no pre-existing pure-logic path to red/green here (it's a visual restructuring, not new business logic), and the old body wraps the *entire* control in a `Menu` — clicking anywhere on it opens a real `NSMenu` tracking loop, which would hang a headless test if driven synchronously. So this task writes the implementation directly; Task 2 adds the regression test against the finished component instead of test-first, and says why there again.

- [ ] **Step 1: Replace the file contents**

Replace all of `Sources/awesoMux/Views/NewWorkspaceMenuButton.swift` with:

```swift
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct NewWorkspaceMenuButton: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Resting background fill. The expanded header passes `surface.sidebar`
    /// (mantle) so the glyph blends into the sidebar next to the search field;
    /// the collapsed rail passes `surface.hover` to keep its boxed look,
    /// matching the disabled command-palette button stacked above it.
    let restFill: Color
    /// Groups available for the "New Workspace in…" submenu, in the order
    /// they appear in the sidebar. Unfiltered — includes the current group,
    /// same as before this split-button change.
    let otherGroups: [(id: SessionGroup.ID, name: String)]
    /// Creates a workspace targeting the caller's chosen default group
    /// (currently-selected workspace's group; see SidebarView.swift). Wired
    /// to the primary segment's plain click — no menu involved, no dropdown
    /// opens.
    let onNewWorkspace: () -> Void
    /// Creates a workspace inside a specific group identified by ID. The
    /// caller re-resolves the group at tap time so a rename / delete
    /// between menu render and tap doesn't recreate a phantom group via
    /// `addSession(groupName:)`'s create-if-missing fallback.
    let onNewWorkspaceInGroup: (SessionGroup.ID) -> Void
    let onNewWorkspaceGroup: () -> Void

    /// Chevron segment width. Fixed rather than derived from `size` so the
    /// secondary hit target stays a consistent thumb-friendly width across
    /// both call sites (34pt expanded header, 40pt collapsed rail).
    private let chevronWidth: CGFloat = 18

    @State private var isPrimaryHovering = false
    @State private var isChevronHovering = false
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        HStack(spacing: 0) {
            primaryButton
            Rectangle()
                .fill(Color.aw.border2)
                .frame(width: 0.5, height: size * 0.6)
                // Purely decorative — without this, VoiceOver announces an
                // unlabeled element between "New Workspace" and "New
                // Workspace Options", matching the pattern already used for
                // decorative glyphs elsewhere (e.g. the search icon in
                // SidebarView.swift).
                .accessibilityHidden(true)
            chevronButton
        }
        .foregroundStyle(Color.aw.accent(accentResolver.accent))
        .background(restFill, in: RoundedRectangle(cornerRadius: cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var primaryButton: some View {
        Button(action: onNewWorkspace) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPrimaryHovering ? Color.aw.surface.hover : Color.clear,
            in: UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .onHover { isPrimaryHovering = $0 }
        // `.onHover(false)` isn't guaranteed when the view is torn down
        // mid-hover (see TerminalPaneView / SidebarSessionTile) — reset so a
        // rebuild over the old frame doesn't keep a stale hover fill. Same
        // reasoning applies to the chevron segment below.
        .onDisappear { isPrimaryHovering = false }
        .accessibilityLabel("New Workspace")
        .accessibilityHint("Creates a new workspace in the current group.")
        .help("New Workspace")
    }

    private var chevronButton: some View {
        Menu {
            Button("New Workgroup…") {
                onNewWorkspaceGroup()
            }

            if !otherGroups.isEmpty {
                Menu("New Workspace in…") {
                    ForEach(otherGroups, id: \.id) { entry in
                        Button(entry.name) {
                            onNewWorkspaceInGroup(entry.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: chevronWidth, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(
            isChevronHovering ? Color.aw.surface.hover : Color.clear,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: cornerRadius
            )
        )
        .onHover { isChevronHovering = $0 }
        .onDisappear { isChevronHovering = false }
        .accessibilityLabel("New Workspace Options")
        .accessibilityHint("Opens a menu to create a new workgroup or a workspace in a specific group.")
        .help("New Workspace Options")
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: exit 0, no warnings about `NewWorkspaceMenuButton.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/awesoMux/Views/NewWorkspaceMenuButton.swift
git commit -m "feat(sidebar): split New Workspace button into instant + chevron"
```

---

### Task 2: Regression test for the split hit targets

**Files:**
- Create: `Tests/awesoMuxTests/NewWorkspaceMenuButtonHitTargetTests.swift`

**Interfaces:**
- Consumes: `NewWorkspaceMenuButton` (Task 1's finished init signature), `SidebarHostedTestHarness.makeWindow` / `.sendClick` / `.pumpMainRunLoop` / `.settleMainRunLoop` (`Tests/awesoMuxTests/SidebarHostedTestHarness.swift`).
- Produces: nothing consumed by later tasks — this is the terminal regression test for this feature.

As noted in Task 1: this test runs against the *already-implemented* component rather than test-first, because the pre-refactor control is a single `Menu` and clicking anywhere on it would open a real `NSMenu` tracking loop — unsafe to drive synchronously in a headless test. The test still needs to genuinely fail if the fix regresses, so run it once against Task 1's code (expect PASS) and then sanity-check by temporarily reverting `primaryButton` to a `Menu` wrapper locally and re-running (expect FAIL) before discarding that revert — this substitutes for true red/green given the ordering constraint.

- [ ] **Step 1: Write the test**

```swift
import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct NewWorkspaceMenuButtonHitTargetTests {
    @Test("primary segment click creates a workspace with a single plain click")
    func primarySegmentClickFiresNewWorkspaceOnce() {
        let counters = ActionCounters()
        let window = Self.makeWindow(
            onNewWorkspace: counters.incrementNewWorkspace,
            onNewWorkspaceInGroup: { _ in counters.incrementNewWorkspaceInGroup() },
            onNewWorkspaceGroup: counters.incrementNewWorkspaceGroup
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counters.newWorkspaceCount >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counters.newWorkspaceCount == 1)
        #expect(counters.newWorkspaceInGroupCount == 0)
        #expect(counters.newWorkspaceGroupCount == 0)
    }

    // The 34×34 primary segment sits at the leading edge of the control
    // (HStack(spacing: 0), primary first); (17, 17) is its center regardless
    // of the chevron segment's width. The harness frame height below is
    // exactly `size` (34), not a larger round number, so there's no vertical
    // slack for SwiftUI to center/align the content within — the primary
    // segment's on-screen origin is unambiguous.
    private static let primarySegmentPoint = CGPoint(x: 17, y: 17)

    private static func makeWindow(
        onNewWorkspace: @escaping () -> Void,
        onNewWorkspaceInGroup: @escaping (SessionGroup.ID) -> Void,
        onNewWorkspaceGroup: @escaping () -> Void
    ) -> NSWindow {
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: NewWorkspaceMenuButton(
                size: 34,
                cornerRadius: 7,
                restFill: Color.clear,
                otherGroups: [(id: UUID(), name: "Other group")],
                onNewWorkspace: onNewWorkspace,
                onNewWorkspaceInGroup: onNewWorkspaceInGroup,
                onNewWorkspaceGroup: onNewWorkspaceGroup
            ),
            frame: NSRect(x: 0, y: 0, width: 90, height: 34)
        )
        return hosted.window
    }
}

private final class ActionCounters {
    private(set) var newWorkspaceCount = 0
    private(set) var newWorkspaceInGroupCount = 0
    private(set) var newWorkspaceGroupCount = 0

    func incrementNewWorkspace() { newWorkspaceCount += 1 }
    func incrementNewWorkspaceInGroup() { newWorkspaceInGroupCount += 1 }
    func incrementNewWorkspaceGroup() { newWorkspaceGroupCount += 1 }
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `swift test --filter NewWorkspaceMenuButtonHitTargetTests`
Expected: PASS (1 test).

- [ ] **Step 3: Confirm the test actually catches a regression**

In `Sources/awesoMux/Views/NewWorkspaceMenuButton.swift`, temporarily change `primaryButton`'s `Button(action: onNewWorkspace)` to `Button(action: {})` (a no-op, so a click no longer calls `onNewWorkspace`), re-run `swift test --filter NewWorkspaceMenuButtonHitTargetTests`, confirm it now FAILS (the `pumpMainRunLoop` wait times out after 1s and `newWorkspaceCount == 1` fails), then revert the temporary change (`git checkout -- Sources/awesoMux/Views/NewWorkspaceMenuButton.swift`) before continuing.

- [ ] **Step 4: Commit**

```bash
git add Tests/awesoMuxTests/NewWorkspaceMenuButtonHitTargetTests.swift
git commit -m "test(sidebar): cover New Workspace primary-segment single-click"
```

---

### Task 3: Manual smoke test and preflight

**Files:** none (verification only).

**Interfaces:** none — terminal task.

- [ ] **Step 1: Build and run the app**

Run: `./script/build_and_run.sh`

- [ ] **Step 2: Exercise the expanded sidebar header control**

In the running app, with the sidebar expanded:
- Click the `+` glyph directly (not the chevron) → confirm a new workspace appears instantly in the current group, with no menu ever opening.
- Click the chevron → confirm a menu opens with exactly two rows, in this order: "New Workgroup…", then "New Workspace in ▶" (hover it to confirm the nested submenu lists the existing groups).
- Choose "New Workgroup…" → confirm the existing naming sheet opens and behaves as it does today (creates the group + a starter workspace).
- Choose a group from "New Workspace in ▶" → confirm it instant-creates a workspace in that group, unnamed, same as today.

- [ ] **Step 3: Exercise the collapsed rail control**

Collapse the sidebar and repeat Step 2's three checks against the 40pt rail control — confirm no visual clipping/overflow at the smaller size.

- [ ] **Step 4: Spot-check accessibility labels**

Open Accessibility Inspector (or VoiceOver), target the sidebar's `+` control, and confirm it now reports two distinct elements — "New Workspace" and "New Workspace Options" — rather than the old single "New Workspace menu" label.

- [ ] **Step 5: Run the full test suite and preflight**

Run: `./script/swift-test.sh`
Expected: all tests pass, including the new `NewWorkspaceMenuButtonHitTargetTests`.

Run: `./script/preflight.sh`
Expected: exit 0.

- [ ] **Step 6: Final commit if preflight touched anything**

If `preflight.sh` or `format.sh` produced any diff:

```bash
git add -u
git commit -m "chore(sidebar): apply preflight formatting for split button"
```

Otherwise, no commit needed — Task 1 and Task 2's commits already cover the change.

---

## After this plan

Before opening a PR: ask the contributor the AI assistance level (`none` / `light` / `moderate` / `substantial`) per `AGENTS.md`, and check whether a GitHub Issue should exist/be linked — this plan didn't create one, since none was requested. `main` is protected; push the `docs/new-workspace-split-button-design` branch and open a PR rather than merging directly.
