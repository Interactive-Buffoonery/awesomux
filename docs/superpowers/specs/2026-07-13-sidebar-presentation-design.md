# Sidebar Presentation and Markdown Toggle Alignment

## Summary

Add a persistent hide/show mode for the workspace sidebar, temporarily reveal a hidden sidebar from its configured window edge, let the user place the sidebar on the left or right, and correct the vertical alignment of the Markdown viewer's Files/Document toggle.

The existing collapsed rail remains a distinct width mode. The current customizable `Command-Backslash` shortcut continues to collapse or expand the sidebar, while a new customizable `Command-Shift-Backslash` shortcut hides or shows it.

## Goals

- Persist whether the sidebar is hidden across launches.
- Temporarily reveal a hidden sidebar when the pointer enters a narrow trigger at its configured window edge.
- Preserve the user's expanded or collapsed sidebar width while hiding and revealing.
- Add a left/right sidebar position control to the Sidebar section of Appearance settings, defaulting to left.
- Keep menu, keyboard, command-palette, focus, pointer, and accessibility paths coherent.
- Vertically center the Markdown viewer's Files/Document toggle in its combined titlebar chrome.

## Non-goals

- Replacing the existing 60-point collapsed sidebar rail.
- Turning the hidden state into a third persisted sidebar width.
- Floating the temporarily revealed sidebar over terminal content.
- Changing the layout or behavior of unrelated Markdown controls.
- Adding Ghostty app-action keybindings for awesoMux commands.

## Interaction Design

### Hide and show

`Command-Shift-Backslash` toggles the user's persistent hidden preference:

- When visible, the sidebar hides completely and the detail area uses the freed width.
- When hidden, the sidebar returns at the exact width it had before hiding.
- Hiding never overwrites the stored expanded width or the current collapsed-rail width.
- The command remains available through the Window menu, command palette, keyboard cheatsheet, and shortcut customization using the existing awesoMux command-routing system.

The Window menu and command palette describe the next persistent action: **Hide Sidebar** while persistently visible and **Show Sidebar** while persistently hidden. Temporary hover reveal does not change either title. The stable shortcut-catalog/customization label remains the generic Hide/Show Sidebar action.

`Command-Backslash` retains its current collapse/expand behavior. The related modifier pattern matches the Floating Panel and Terminal Companion shortcut family.

The existing Focus Sidebar action reveals a persistently hidden sidebar before moving keyboard focus into it. A direct show or focus action clears any temporary hover state and leaves the sidebar persistently visible.

### Edge reveal

When the sidebar is persistently hidden, a narrow invisible pointer trigger occupies its configured window edge. Entering that trigger temporarily reveals the normal split sidebar at its remembered width, shifting the detail content rather than covering it.

The trigger and revealed sidebar form one hover region. Leaving both begins a short grace period before hiding, allowing the pointer to cross their boundary without flicker. Re-entering cancels the pending hide. Delayed work carries a generation/token so an obsolete delay cannot hide a newer reveal.

Temporary reveal does not change the persistent hidden preference. Clicking or using the explicit Hide/Show command is the only way to change that preference.

### Sidebar position

The Sidebar section of Appearance settings gains a Left/Right segmented control. The value is stored as `appearance.sidebar_position`, defaults to `left`, and applies immediately.

Position affects:

- split-view child ordering and divider calculations;
- the edge used for hidden-sidebar hover reveal;
- titlebar column ordering while keeping traffic-light clearance on the physical left;
- divider and resize behavior;
- sidebar peek-card direction and transition anchor.

Peek cards open inward toward the detail area: rightward from a left sidebar and leftward from a right sidebar.

## Architecture

### Persistent configuration

Add a `SidebarPosition` enum to `AppearanceConfig` with `left` and `right` cases and a TOML default of `left`. Wire it through the existing Appearance section slice and Sidebar settings section. Update known-key ownership, defaults, reset copy, and TOML round-trip coverage.

Persist the user's hidden preference independently from width, using a focused sidebar-presentation preference store beside `SidebarWidthPreferenceStore`. This state is UI presentation state rather than a visible Appearance option: the menu/shortcut action controls it. Keeping it outside width storage prevents `0` from entering `SidebarWidthPolicy` and preserves the existing expanded/collapsed model.

### Presentation model

Introduce a small main-actor sidebar-presentation model that separates:

- `userWantsSidebarHidden`, persisted;
- `isTemporarilyRevealed`, runtime only;
- pointer presence in the edge trigger and sidebar;
- cancellable delayed-hide state.

Its public decisions cover explicit toggle, focus-request reveal, trigger enter/exit, sidebar enter/exit, and position changes. The delay dependency is injectable for deterministic tests, following the existing `SidebarPeekModel` stale-task pattern.

### Split layout

Extend the sidebar split bridge/controller with explicit sidebar position and hidden state instead of sending a zero width through the existing width API.

The controller identifies the sidebar and detail views by role rather than assuming the sidebar is always `subviews[0]`. Position-aware helpers convert between divider coordinates and sidebar width:

- left sidebar width is measured from the leading edge to the divider;
- right sidebar width is measured from the divider to the trailing edge.

Normal visible widths continue through `SidebarWidthPolicy`. Hidden layout collapses the sidebar role without committing a width preference. Temporary reveal restores the remembered visible width. Reclamping, live resize, drag completion, and narrow-window recovery operate on sidebar width regardless of physical side.

`ContentView` owns the edge trigger and presentation orchestration so pointer changes do not rebuild or re-host terminal surfaces. The existing observable proxy/live-width pattern remains the bridge to AppKit.

### Titlebar and peek geometry

`AppTitlebarView` arranges sidebar and content columns using the configured position, but traffic-light padding remains attached to the physical leading window edge. Content gutters and divider chrome follow the actual divider.

Sidebar row geometry exposes the inward edge appropriate to the position. Peek overlays use that edge, the matching alignment, and the matching transition anchor so cards never open off-window merely because the sidebar moved right.

### Command routing

Add a stable shortcut-catalog entry for Hide/Show Sidebar with default `Command-Shift-Backslash`. Route it through the same layers as the existing width toggle:

- shortcut catalog and customization;
- `NSApplication.sendEvent` interception for terminal-first-responder reliability;
- notification/request routing into `ContentView`;
- Window menu;
- command palette;
- keyboard cheatsheet and shortcut documentation.

The existing Collapse/Expand Sidebar identifier and `Command-Backslash` behavior remain unchanged.

### Markdown alignment

The Files/Document toggle is centered within the lower 24-point tab strip while a separate 4-point focus-accent band sits above it. Its visual center is therefore 2 points below the combined 28-point titlebar center.

Apply a 2-point upward offset to the outer Files/Document toggle while preserving its 20-point visible pill, 24-point hit target, VoiceOver label, and both Files and Document states. Do not change the neighboring revision indicator unless visual verification shows the same user-facing defect and it is explicitly added to scope.

## Accessibility and Failure Behavior

- Hide/Show Sidebar remains discoverable through menu, palette, cheatsheet, and customizable shortcut UI even though the edge trigger is visually absent.
- The invisible edge trigger is pointer-only and does not enter the keyboard focus order.
- Focus Sidebar always produces a visible focus destination.
- Position changes preserve current selection, focus where possible, and stored width.
- Invalid or missing `sidebar_position` values follow the config layer's existing validation/default behavior and never leave the split controller without a valid side.
- If the window is too narrow for the remembered visible width, existing clamp behavior chooses a valid rail/visible width without overwriting the remembered expanded width.

## Test Plan

Follow test-driven development for each behavior:

1. Appearance config tests for default-left, right-side round trips, reset behavior, and invalid/missing input.
2. Presentation-model tests for persistent toggle, hover reveal, grace-period hiding, cancellation, stale-delay protection, focus reveal, and position changes.
3. Preference-store tests proving hidden state persists without overwriting sidebar widths.
4. Split-controller tests for leading/trailing width conversion, clamping, divider movement, hiding/revealing, window resize, and drag commits.
5. Shortcut/catalog/routing tests for the new stable action and `Command-Shift-Backslash` default while retaining `Command-Backslash` collapse/expand.
6. Menu and command-palette title tests proving persistent hidden intent selects Show Sidebar, persistent visible intent selects Hide Sidebar, and temporary hover state does not affect the title.
7. Targeted source or view-policy tests for titlebar ordering, traffic-light ownership, edge selection, and inward peek geometry where practical.
8. Full `./script/swift-test.sh` and `./script/preflight.sh` verification.
9. Run the worktree app and visually verify:
   - visible, collapsed, hidden, and hover-revealed states;
   - left and right sidebar positions;
   - resize and relaunch persistence;
   - keyboard focus and both sidebar shortcuts;
   - peek cards opening inward;
   - Files and Document toggle alignment and hit targets.

## Integration Risk

Open PR #22 currently changes `AwesoMuxApp.swift`, `PaletteCommand.swift`, `ContentView.swift`, and `SidebarView.swift`, overlapping this feature's likely command and layout surfaces. Implementation will stay based on current `origin/main`; before publishing, refresh the live PR state and rebase or reconcile those changes deliberately rather than merging overlapping assumptions blindly.
