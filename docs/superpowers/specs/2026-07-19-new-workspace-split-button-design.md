# New Workspace split button — design

- **Status:** Approved
- **Date:** 2026-07-19

## Summary

The sidebar's `+` control is a `Menu` today — clicking it always opens a dropdown, and "New Workspace" is just the first row inside it, not a true single-click action. This makes the common case (make me a workspace in the group I'm looking at) take a menu-open-then-click, same as the deliberate cases (pick a different group, make a new group).

This becomes a split button: the `+` glyph itself is a real button that instant-creates a workspace in the current group with zero menu interaction. A small chevron beside it opens a 2-row menu for the deliberate paths. Both existing creation behaviors (instant workspace, named group creation) are reused completely unchanged — only the entry-point layout changes.

## What already exists (and is reused unchanged)

- **Instant creation:** `onNewWorkspace()` (`SidebarView.swift:759-773`, `addWorkspaceInCurrentContext`) → `sessionStore.addSession(groupName:)` (`SessionStore.swift:417-438`). Mints an untitled `TerminalSession` in the current-context group (or `appSettingsStore.workspaces.value.defaultGroup` on cold start) and selects it. No name prompt today; stays that way.
- **Group-targeted creation:** `onNewWorkspaceInGroup(groupID)`, wired from the existing "New Workspace in…" submenu rows — one per other group. Instant, unnamed, same as above but targets a specific `SessionGroup.id`.
- **New group creation:** `onNewWorkspaceGroup()` → `requestNewWorkspaceGroup()` (`AwesoMuxApp.swift:2533`) → `WorkspaceGroupCreateSheet` (`.sheet(item:)`, `AwesoMuxApp.swift:357-371`) → `sessionStore.addWorkspaceGroup(named:)` (`SessionStore.swift:503-518`). Name field, validation/dedup feedback, Cancel/Create. Creates the group **and** a starter workspace inside it. Unchanged.

None of the three underlying actions change behavior. This is a layout/entry-point change to `NewWorkspaceMenuButton.swift` only.

## Control layout

Replace the single `Menu`-wrapped button with a two-part split control:

- **Primary hit area** (the `+` glyph): a plain `Button`, not a `Menu`. Single click calls `onNewWorkspace()` directly — no dropdown opens. This is the only behavior change that matters: the fast path becomes an actual single click instead of open-menu-then-click-first-row.
- **Chevron hit area** (small disclosure triangle, trailing edge of the control): opens a `Menu` with exactly two rows, in this order:
  1. **"New Workgroup…"** → `onNewWorkspaceGroup()`, unchanged sheet.
  2. **"New Workspace in ▶"** → nested submenu, one row per group other than the current one → `onNewWorkspaceInGroup(groupID)`, unchanged instant creation.

The chevron menu is a fixed 2 rows regardless of how many groups exist — the potentially-long group list stays behind the submenu hover (as it already is today), so it never turns into an unbounded flat list. `NSMenu` submenus scroll and support type-ahead natively at any length.

Row order (Workgroup before "New Workspace in") is a deliberate, low-confidence call — flag for revisiting if it feels wrong in practice.

## Explicitly out of scope

- No naming prompt for any instant-creation path (primary click or "New Workspace in [Group]"). Both stay unnamed, matching current behavior exactly.
- No filtering of the group list by sidebar collapse/expand state — the submenu lists all groups, matching current behavior.
- No changes to `WorkspaceGroupCreateSheet`, `RemoteWorkspaceGroupCreateSheet`, or `WorktreeCreateForm` — those flows are untouched.
- No change to how group membership is modeled (`SessionGroup.sessions` array, no `groupID` FK) — out of scope, unaffected by this change.

## Visual/interaction notes for implementation

- Split-button chevron affordance should follow existing `DesignSystem` tokens/patterns for split buttons if one exists in the codebase; otherwise match the visual weight of the current `+` button so the control doesn't grow the sidebar toolbar's footprint.
- Keyboard/accessibility: the primary `+` and the chevron need distinct accessibility labels/actions (e.g. "New Workspace" vs "New Workspace Options") since they're now two separate controls, not one menu button.
