# 0006 — Sidebar source-list a11y semantics

- **Status:** Accepted
- **Date:** 2026-05-10
- **Deciders:** eD

## Context

The sidebar in [`Sources/awesoMux/Views/SidebarView.swift`](../../Sources/awesoMux/Views/SidebarView.swift) was rewritten during the design-handoff polish work in PR #30 from a `NavigationSplitView` + `List(selection:)` shape into a custom `ScrollView` + `LazyVStack` of row buttons. The visual identity from the polish PR depends on that rebuild — chevron-collapse group headers with project-tint dots, glow-and-rail active-row chrome, custom inter-group spacing, hover and notification states, an empty-group drop target, and an empty-filter card — none of which `List` exposes by default.

A pre-merge a11y review on PR #30 flagged that going non-`List` quietly strips macOS-native source-list assistive-tech semantics. Reading the rebuild today shows the picture is more nuanced than a clean revert vs. rebuild call:

**Already plumbed manually**

- Per-row `accessibilityElement(children: .combine)` with a rich combined label (title, agent kind, state, working directory, pane count, notification count, backgrounded floating panel hint).
- Named `accessibilityAction`s on each row for **Rename Workspace**, **Close Workspace**, and **New Workspace Here** — discoverable through the VoiceOver actions rotor.
- Group headers: `accessibilityLabel`, `accessibilityValue` for `Collapsed` / `Expanded`, `.isHeader` trait, and named header actions (**New Workspace in Group**, **New Workspace Group…**, **Close Group**).
- Footer state-filter chips: `.isSelected` trait when the filter is active.
- Discrete `accessibilityLabel` and `help` on the search field's clear button and on each tile's close button.

**Gaps**

1. The active row tile drives `isActive` into the glow, border, and tint rail, but **does not add `.isSelected` to the row's accessibility traits**. Assistive tech sees a row that visually is selected but technically is not.
2. **No keyboard navigation across the row list.** ↑/↓ arrows do not move the selection cursor; users have to tab through every row button or click.
3. **No focus state or Full Keyboard Access focus ring.** The view does not declare `@FocusState`, the rows are not `.focusable()`, and there is no design-system focus-ring token plumbed in.
4. **No source-list rotor / "row N of M" announcement.** Without `List` semantics or an `accessibilityRotor`, VoiceOver does not announce row position within the source list.

The two paths offered by the issue are reframed by the actual current state:

- **Path 1 — revert to `List(selection:)` with custom row content.** Restores selection-trait, keyboard navigation, focus ring, and rotor for free. Preserves the row tile chrome verbatim (List rows accept arbitrary content). Forces rework of the group-header collapse model (no built-in collapsed-section semantic in List), inter-group spacing (now `.listSectionSpacing(.custom(14))`), sidebar background (`.scrollContentBackground(.hidden)`), and the empty-group / empty-filter placeholders. ~150–250 lines of churn with regression risk concentrated in the header chrome and the collapsed/filtered/empty states.
- **Path 2 — keep the custom rebuild and plug the four gaps.** Adds `.accessibilityAddTraits(.isSelected)` on the active row, a `@FocusState` selection cursor wired through `onMoveCommand` (or `.onKeyPress` for ↑/↓/Home/End), `.focusable()` per row with a design-system focus ring under `@AccessibilityFocusState` and `accessibilityIssues.fullKeyboardAccess`, and an `accessibilityRotor` exposing all sessions. ~80–150 lines focused on a11y plumbing; row chrome and section layout untouched.

**The "future features make List worth it" argument does not hold up.** The three nearby tickets the issue triages alongside this one — INT-211 drag-reorder, INT-281 fuzzy search, INT-282 recently-closed — do not get meaningful infrastructure from `List`:

- INT-211 reorders **across groups and within groups**; `List`'s `.onMove` handles only trivial single-section reorder. Both paths land on `.draggable` / `.dropDestination` with custom drop targets.
- INT-281 is a pure data-layer swap inside `matchesFilters` — view structure does not move.
- INT-282 fits as either an extra `Section` in `List` or an extra block in the custom `LazyVStack` — wash.

The single actual `List` win is the a11y stack itself, which is exactly the gap this ADR is closing.

## Decision

We commit to the **manual rebuild** and close the four a11y gaps in place. Concretely:

1. Add `.accessibilityAddTraits(.isSelected)` to `SidebarSessionTile` when `isActive`. Add the same trait to the active group entry where the active session lives, so the rotor reflects nesting.
2. Introduce a `@FocusState` selection cursor on `SidebarView`, expose ↑/↓/Home/End through `onMoveCommand` and `.onKeyPress`, and wire selection-cursor changes through to `sessionStore.selectedSessionID`. Tab order between the search field, the sidebar selection cursor, and the detail pane is explicit, not implicit-default.
3. Make rows `.focusable()` and render a visible focus ring under Full Keyboard Access using a new `DesignSystem` focus-ring token that respects increased-contrast and reduce-motion environments. The token lives next to `AwGlowModifier` and the `tileBorder` high-contrast logic so the contrast rules stay co-located.
4. Add an `accessibilityRotor("Workspaces")` over the flattened, post-filter session list so VoiceOver users can rotor-cycle through workspaces independent of group collapse state.

Path 1 is recorded here as the rejected alternative and remains defensible — if a future macOS revision either adds first-class collapsed-section semantics to `List` or breaks one of the manual focus/rotor implementations, that is the cue to revisit this ADR rather than patch the manual rebuild around the regression.

## Consequences

- INT-188 closes by plugging gaps rather than reverting. PR #30's visual identity is preserved verbatim — group headers, inter-group spacing, glow/border/rail row chrome, hover state, empty-group drop target, empty-filter card all stay byte-for-byte.
- Selection trait, keyboard nav, focus ring, and a workspaces rotor land as a focused, testable patch. Each gap gets unit or view-level test coverage; the rotor in particular is straightforward to assert against a fixture `SessionStore`.
- A new design-system focus-ring token enters `DesignSystem`. It has to coexist with `AwGlowModifier` (which already conditions on `colorSchemeContrast == .increased`) so the high-contrast path doesn't double-stroke. The token's contract is co-located with the existing increased-contrast logic in `tileBorder`.
- Tab-order plumbing between search field, sidebar selection cursor, and detail is now explicit. Previously it was whatever SwiftUI default traversal produced — works today, but undefined under macOS revisions.
- Maintenance burden lives at the AX-trait / FocusState / KeyPress API surface, which has been stable across macOS 13–15. `List` chrome (insets, separators, hover, section-spacing defaults) has shifted across the same span; we trade a stable surface for an unstable one.
- If future sidebar features outgrow the manual implementation — most likely candidate is a deep tree (groups inside groups) where rotor and kbd-nav semantics get expensive to maintain by hand — the revisit cost is one refactor PR, not a recurring tax.

## Alternatives considered

- **Revert to `List(selection:)` with custom rows** — rejected on regression-surface grounds. The a11y win is real but identical to what Path 2 produces; the cost is ~150–250 lines of churn concentrated in the header and empty-state code, plus a visual QA pass across collapsed/filtered/empty modes. The "future features benefit" argument did not survive scrutiny — the three tickets it would help with don't actually use the infrastructure `List` provides for free.
- **Hybrid — `List` for rows, custom group containers around it** — considered and rejected. Nesting `List`s or interleaving `List` with custom containers is exactly the SwiftUI shape that breaks across macOS revisions; we'd inherit `List`'s instability without the simplicity that motivates Path 1 in the first place.
