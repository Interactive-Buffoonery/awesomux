# New Workspace Split Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the sidebar's expanded-header `+` control from a `Menu` (every click opens a dropdown, "New Workspace" is just its first row) into a real split button — a plain-click primary segment that instant-creates a workspace, plus a chevron segment exposing the deliberate actions (new group, new workspace in a specific group). The collapsed rail's control is untouched.

**Architecture:** New, single-purpose component (`NewWorkspaceSplitButton`) used only by the expanded header call site. `NewWorkspaceMenuButton` — the existing single-`Menu` control — is not modified and keeps serving the collapsed rail exactly as it does today; there's no room at 60pt rail width for a second, honestly-sized hit target next to a 40pt primary, so the two call sites diverge rather than sharing one geometry.

**Tech Stack:** SwiftUI (macOS 15+ target — `UnevenRoundedRectangle` is safe to use), swift-testing, the existing `SidebarHostedTestHarness` AppKit click-simulation helper.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-19-new-workspace-split-button-design.md` (approved, revised after architecture review + cross-model adversarial pass).
- The three underlying actions (`onNewWorkspace`, `onNewWorkspaceInGroup`, `onNewWorkspaceGroup`) do not change behavior anywhere — this is an entry-point/layout change only.
- **Collapsed rail is untouched.** `Sources/awesoMux/Views/NewWorkspaceMenuButton.swift` and its call site (`SidebarView.swift:669-682`) are not modified by this plan at all.
- `otherGroups` stays unfiltered exactly as it is today (it already includes the current group — the property name is a slight misnomer, pre-existing, not this plan's problem to fix). Do not add current-group filtering.
- Chevron menu is **up to 2 rows** — 1 when the user has no other groups yet, 2 otherwise — in this order: **"New Workspace Group…" first, then "New Workspace in ▶" second** (order flipped from the spec's first draft per eD's explicit call — flagged low-confidence, may get flipped back later; wording is the established term, not a rename). The group list itself stays behind the nested submenu, never flattened to the top level.
- No naming prompt anywhere in this change — both instant-creation paths (primary click, "New Workspace in [Group]") stay unnamed, matching current behavior exactly.
- No changes to `WorkspaceGroupCreateSheet`, `RemoteWorkspaceGroupCreateSheet`, `WorktreeCreateForm`, or the `SessionGroup` model.
- New component's primary segment matches the search field chip's height (`AwSpacing.searchFieldHeight` = 30pt, `Sources/DesignSystem/Tokens/AwFont.swift:358`), not the old button's 34pt — the two chips on that row read as one size.
- Conventional Commits: `<type>(<scope>): <lowercase imperative>`, subject ≤72 chars, no period.
- `main` is protected — this work continues on the `docs/new-workspace-split-button-design` branch (already checked out, currently holds the spec and plan commits).
- Splitting one focusable control into two changes keyboard Tab order for this control (one stop → two). This control isn't wired into the sidebar's custom `SidebarVisibleRowTarget` focus system, so this is an accepted, low-severity, unremarkable side effect of the redesign.
- A native `Menu(primaryAction:)` split control was considered and not adopted (unverified whether it renders as a true split under `.menuStyle(.borderlessButton)`, and scoping to the expanded header alone already resolves the geometry pressure that motivated considering it). Documented here per the spec so it isn't silently reconsidered without this context.

---

### Task 1: Build `NewWorkspaceSplitButton` and wire it into the expanded header

**Files:**
- Create: `Sources/awesoMux/Views/NewWorkspaceSplitButton.swift`
- Modify: `Sources/awesoMux/Views/SidebarView.swift:743-752` (swap `NewWorkspaceMenuButton` for `NewWorkspaceSplitButton` at the expanded header call site, adjust size)

**Interfaces:**
- Consumes: `sessionStore.groups` (already mapped to `otherGroups` at the call site, unchanged), `addWorkspaceInCurrentContext`, `addWorkspace(inGroupID:)`, `onNewWorkspaceGroup` — all three already exist in `SidebarView.swift` and are reused verbatim.
- Produces: `NewWorkspaceSplitButton` with init `(restFill: Color, otherGroups: [(id: SessionGroup.ID, name: String)], onNewWorkspace: () -> Void, onNewWorkspaceInGroup: (SessionGroup.ID) -> Void, onNewWorkspaceGroup: () -> Void)` — no `size`/`cornerRadius` params, since this component has exactly one call site and hardcodes 30pt/7pt to match the search field chip. Task 2's test constructs this view directly using this signature.

There's no pre-existing pure-logic path to red/green here (it's new view composition, not new business logic). This task writes the implementation directly; Task 2 adds the regression test against the finished component and explains why test-first isn't used.

- [ ] **Step 1: Create the new component**

Write `Sources/awesoMux/Views/NewWorkspaceSplitButton.swift`:

```swift
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Split-button replacement for `NewWorkspaceMenuButton` at the expanded
/// sidebar header only — the collapsed rail keeps the original single-`Menu`
/// control unchanged, since 60pt of rail width has no room for a second,
/// honestly-sized hit target next to a 40pt primary segment.
struct NewWorkspaceSplitButton: View {
    /// Resting background fill. Matches the expanded header's treatment of
    /// the search field it sits beside — blends into the sidebar, not a
    /// separate boxed color.
    let restFill: Color
    /// Groups available for the "New Workspace in…" submenu, in the order
    /// they appear in the sidebar. Unfiltered — includes the current group,
    /// same as `NewWorkspaceMenuButton`'s existing behavior.
    let otherGroups: [(id: SessionGroup.ID, name: String)]
    /// Creates a workspace targeting the caller's chosen default group.
    /// Wired to the primary segment's plain click — no menu involved, no
    /// dropdown opens.
    let onNewWorkspace: () -> Void
    /// Creates a workspace inside a specific group identified by ID. The
    /// caller re-resolves the group at tap time so a rename / delete
    /// between menu render and tap doesn't recreate a phantom group via
    /// `addSession(groupName:)`'s create-if-missing fallback.
    let onNewWorkspaceInGroup: (SessionGroup.ID) -> Void
    let onNewWorkspaceGroup: () -> Void

    /// Matches the search field chip's height (`AwSpacing.searchFieldHeight`)
    /// so the two chips on the expanded header's row read as one size.
    private let primarySize: CGFloat = 30
    private let cornerRadius: CGFloat = 7
    /// The 296pt-wide expanded row has room for a comfortable hit target —
    /// this doesn't also need to fit the 60pt collapsed rail.
    private let chevronWidth: CGFloat = 22
    /// Rapid double-clicks used to be impossible: the old `Menu`-gated
    /// control consumed the first click opening the menu. A plain `Button`
    /// doesn't have that natural debounce, so this guards it explicitly.
    private let doubleClickGuardInterval: TimeInterval = 0.4

    @State private var isPrimaryHovering = false
    @State private var isChevronHovering = false
    @State private var lastCreateAt: Date?
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        HStack(spacing: 0) {
            primaryButton
            Rectangle()
                .fill(Color.aw.border2)
                .frame(width: 0.5, height: primarySize * 0.6)
                // Purely decorative — without this, VoiceOver announces an
                // unlabeled element between "New Workspace" and "New
                // Workspace Options".
                .accessibilityHidden(true)
            chevronButton
        }
        .foregroundStyle(Color.aw.accent(accentResolver.accent))
        .background(restFill, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var primaryButton: some View {
        Button(action: guardedNewWorkspace) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: primarySize, height: primarySize)
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
            Button("New Workspace Group…") {
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
                .frame(width: chevronWidth, height: primarySize)
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
        .accessibilityHint("Opens a menu to create a new workspace group or a workspace in a specific group.")
        .help("New Workspace Options")
    }

    private func guardedNewWorkspace() {
        let now = Date()
        if let lastCreateAt, now.timeIntervalSince(lastCreateAt) < doubleClickGuardInterval {
            return
        }
        lastCreateAt = now
        onNewWorkspace()
    }
}
```

- [ ] **Step 2: Wire it into the expanded header call site**

In `Sources/awesoMux/Views/SidebarView.swift`, replace the `NewWorkspaceMenuButton` call at lines 743-752:

```swift
            NewWorkspaceMenuButton(
                size: 34,
                cornerRadius: 7,
                // Blend into the sidebar so it pairs cleanly with the search field.
                restFill: Color.aw.surface.sidebar,
                otherGroups: sessionStore.groups.map { ($0.id, $0.name) },
                onNewWorkspace: addWorkspaceInCurrentContext,
                onNewWorkspaceInGroup: addWorkspace(inGroupID:),
                onNewWorkspaceGroup: onNewWorkspaceGroup
            )
```

with:

```swift
            NewWorkspaceSplitButton(
                // Blend into the sidebar so it pairs cleanly with the search field.
                restFill: Color.aw.surface.sidebar,
                otherGroups: sessionStore.groups.map { ($0.id, $0.name) },
                onNewWorkspace: addWorkspaceInCurrentContext,
                onNewWorkspaceInGroup: addWorkspace(inGroupID:),
                onNewWorkspaceGroup: onNewWorkspaceGroup
            )
```

The collapsed rail call site (lines 669-682) is untouched — it keeps constructing `NewWorkspaceMenuButton` exactly as it does today.

- [ ] **Step 3: Build to confirm it compiles**

Run: `swift build`
Expected: exit 0, no warnings.

- [ ] **Step 4: Build and run the app for an early visual check**

Run: `./script/build_and_run.sh`

In the running app, with the sidebar expanded, confirm:
- The `+` control now visually reads as two segments (primary square + narrower chevron) at the same height as the search field beside it — not a "weird li'l guy" mismatched against it.
- Clicking the `+` glyph directly creates a workspace instantly, no menu opens.
- Clicking the chevron opens a menu.

If the chevron does **not** render as a genuinely separate, cleanly-hittable segment from the primary button (i.e. the `Menu`'s hit-testing bleeds into the primary segment, or vice versa), stop and re-read the "native `Menu(primaryAction:)`" note in Global Constraints before continuing — that's the fallback to reconsider. Otherwise, continue.

- [ ] **Step 5: Commit**

```bash
git add Sources/awesoMux/Views/NewWorkspaceSplitButton.swift Sources/awesoMux/Views/SidebarView.swift
git commit -m "feat(sidebar): split expanded-header New Workspace button"
```

---

### Task 2: Regression test for the primary segment's click behavior

**Files:**
- Create: `Tests/awesoMuxTests/NewWorkspaceSplitButtonHitTargetTests.swift`

**Interfaces:**
- Consumes: `NewWorkspaceSplitButton` (Task 1's finished init signature), `SidebarHostedTestHarness.makeWindow` / `.sendClick` / `.pumpMainRunLoop` / `.settleMainRunLoop` (`Tests/awesoMuxTests/SidebarHostedTestHarness.swift`).
- Produces: nothing consumed by later tasks — this is the terminal regression test for this feature.

This test runs against the *already-implemented* component rather than test-first: there's no safe way to click-test the *old* `NewWorkspaceMenuButton` control this replaces (its entire body is a `Menu` — clicking anywhere on it opens a real `NSMenu` tracking loop, unsafe to drive synchronously in a headless test), and `NewWorkspaceSplitButton` doesn't exist until Task 1 writes it. The test still needs to genuinely fail if the fix regresses — Step 3 below proves that by temporarily breaking the implementation and re-running.

The harness window frame below is sized to the component's exact known dimensions (`30 primary + 0.5 divider + 22 chevron = 52.5`, height `30`) with no slack in either axis, so there's no ambiguity about where SwiftUI positions the content within the hosting frame.

- [ ] **Step 1: Write the test**

```swift
import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct NewWorkspaceSplitButtonHitTargetTests {
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

    // The 30×30 primary segment sits at the leading edge of the control
    // (HStack(spacing: 0), primary first); (15, 15) is its center. The
    // harness frame below is exactly `30 + 0.5 + 22 = 52.5` wide and `30`
    // tall — the component's own known dimensions, no slack in either axis
    // for SwiftUI to center/align the content within.
    private static let primarySegmentPoint = CGPoint(x: 15, y: 15)

    private static func makeWindow(
        onNewWorkspace: @escaping () -> Void,
        onNewWorkspaceInGroup: @escaping (SessionGroup.ID) -> Void,
        onNewWorkspaceGroup: @escaping () -> Void
    ) -> NSWindow {
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: NewWorkspaceSplitButton(
                restFill: Color.clear,
                otherGroups: [(id: UUID(), name: "Other group")],
                onNewWorkspace: onNewWorkspace,
                onNewWorkspaceInGroup: onNewWorkspaceInGroup,
                onNewWorkspaceGroup: onNewWorkspaceGroup
            ),
            frame: NSRect(x: 0, y: 0, width: 52.5, height: 30)
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

Run: `swift test --filter NewWorkspaceSplitButtonHitTargetTests`
Expected: PASS (1 test).

- [ ] **Step 3: Confirm the test actually catches a regression**

In `Sources/awesoMux/Views/NewWorkspaceSplitButton.swift`, temporarily change `primaryButton`'s `Button(action: guardedNewWorkspace)` to `Button(action: {})` (a no-op), re-run `swift test --filter NewWorkspaceSplitButtonHitTargetTests`, confirm it now FAILS (the `pumpMainRunLoop` wait times out after 1s and `newWorkspaceCount == 1` fails), then revert the temporary change (`git checkout -- Sources/awesoMux/Views/NewWorkspaceSplitButton.swift`) before continuing.

- [ ] **Step 4: Commit**

```bash
git add Tests/awesoMuxTests/NewWorkspaceSplitButtonHitTargetTests.swift
git commit -m "test(sidebar): cover New Workspace split button single-click"
```

---

### Task 3: Manual smoke test and preflight

**Files:** none (verification only).

**Interfaces:** none — terminal task.

- [ ] **Step 1: Build and run the app**

Run: `./script/build_and_run.sh`

- [ ] **Step 2: Exercise the expanded header split button**

With the sidebar expanded:
- Click the `+` glyph directly (not the chevron) → confirm a new workspace appears instantly in the current group, no menu opens.
- Double-click the `+` glyph rapidly → confirm exactly one workspace is created, not two (the debounce guard from Task 1).
- Click the chevron → confirm a menu opens with up to two rows, in this order: "New Workspace Group…", then "New Workspace in ▶" (hover it to confirm the nested submenu lists the existing groups).
- Choose "New Workspace Group…" → confirm the existing naming sheet opens and behaves as it does today (creates the group + a starter workspace).
- Choose a group from "New Workspace in ▶" → confirm it instant-creates a workspace in that group, unnamed, same as today.
- Tab to the control with the keyboard → confirm it now takes two Tab stops (primary, then chevron) and both are visibly focused with Space/Return activating them.

- [ ] **Step 3: Confirm the collapsed rail is unaffected**

Collapse the sidebar and exercise its `+` control — confirm it behaves exactly as it did before this change (single control, tap opens the full 3-row menu: New Workspace / New Workspace in… / New Workspace Group…). This should require no investigation if Task 1 didn't touch `NewWorkspaceMenuButton.swift`; this step is a sanity check that it didn't regress by accident.

- [ ] **Step 4: RTL check**

Temporarily add a right-to-left language (e.g. Hebrew or Arabic) in System Settings → General → Language & Region, make it primary, then relaunch the dev build via `./script/build_and_run.sh`. Confirm the split button's chevron mirrors to the leading edge along with the rest of the row, with corner radii mirroring correctly. Revert the language setting afterward.

- [ ] **Step 5: Spot-check accessibility labels**

Open Accessibility Inspector (or VoiceOver), target the expanded header's `+` control, and confirm it reports two distinct elements — "New Workspace" and "New Workspace Options" — with no unlabeled element announced for the divider between them.

- [ ] **Step 6: Run the full test suite and preflight**

Run: `./script/swift-test.sh`
Expected: all tests pass, including the new `NewWorkspaceSplitButtonHitTargetTests`.

Run: `./script/preflight.sh`
Expected: exit 0.

- [ ] **Step 7: Final commit if preflight touched anything**

If `preflight.sh` or `format.sh` produced any diff:

```bash
git add -u
git commit -m "chore(sidebar): apply preflight formatting for split button"
```

Otherwise, no commit needed — Task 1 and Task 2's commits already cover the change.

---

## After this plan

Before opening a PR: ask the contributor the AI assistance level (`none` / `light` / `moderate` / `substantial`) per `AGENTS.md`, and check whether a GitHub Issue should exist/be linked — this plan didn't create one, since none was requested. `main` is protected; push the `docs/new-workspace-split-button-design` branch and open a PR rather than merging directly.
