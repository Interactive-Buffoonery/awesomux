# New Workspace split button — design

- **Status:** Approved
- **Date:** 2026-07-19

## Summary

The sidebar's `+` control is a `Menu` today — clicking it always opens a dropdown, and "New Workspace" is just the first row inside it, not a true single-click action. This makes the common case (make me a workspace in the group I'm looking at) take a menu-open-then-click, same as the deliberate cases (pick a different group, make a new group).

This becomes a split button: the `+` glyph itself is a real button that instant-creates a workspace in the current group with zero menu interaction. A small chevron beside it opens a 2-row menu for the deliberate paths. Both existing creation behaviors (instant workspace, named group creation) are reused completely unchanged — only the entry-point layout changes.

**This applies to the expanded sidebar header only.** The collapsed rail's control stays exactly as it is today (a single `NewWorkspaceMenuButton`, unchanged, tap opens the whole menu) — see "Call-site divergence" below for why.

## What already exists (and is reused unchanged)

- **Instant creation:** `onNewWorkspace()` (`SidebarView.swift:759-773`, `addWorkspaceInCurrentContext`) → `sessionStore.addSession(groupName:)` (`SessionStore.swift:417-438`). Mints an untitled `TerminalSession` in the current-context group (or `appSettingsStore.workspaces.value.defaultGroup` on cold start) and selects it. No name prompt today; stays that way.
- **Group-targeted creation:** `onNewWorkspaceInGroup(groupID)`, wired from the existing "New Workspace in…" submenu rows — one per other group. Instant, unnamed, same as above but targets a specific `SessionGroup.id`.
- **New group creation:** `onNewWorkspaceGroup()` → `requestNewWorkspaceGroup()` (`AwesoMuxApp.swift:2533`) → `WorkspaceGroupCreateSheet` (`.sheet(item:)`, `AwesoMuxApp.swift:357-371`) → `sessionStore.addWorkspaceGroup(named:)` (`SessionStore.swift:503-518`). Name field, validation/dedup feedback, Cancel/Create. Creates the group **and** a starter workspace inside it. Unchanged.

None of the three underlying actions change behavior. This is an entry-point/layout change only — no model, sheet, or callback logic moves.

## Call-site divergence

`NewWorkspaceMenuButton` is used in two places today: the expanded sidebar header (296pt of row width, sharing a line with the search field) and the 60pt collapsed rail (where it's the sole control on its own 40pt-wide row). A split button needs two independently-hittable segments; at 60pt total rail width with a 40pt primary segment, there's no room left for a second, honestly-sized hit target next to it.

Rather than force one geometry to fit both, the two call sites diverge:

- **Expanded header:** gets the new split-button treatment (below).
- **Collapsed rail:** keeps today's `NewWorkspaceMenuButton` completely unchanged — single control, tap opens the whole `Menu` (New Workspace / New Workspace in… / New Workspace Group…), exactly as it behaves right now. No chevron, no split.

Different sidebar states already have different affordances throughout this app; this isn't a new pattern.

**Styling exception:** the rail's `NewWorkspaceMenuButton` call currently passes `restFill: Color.aw.surface.sidebar` (blends into the background at rest), while the search icon button above it on the same rail uses `Color.aw.surface.elevated.opacity(0.6)` (a visible boxed background) — eD flagged this mismatch from a reference screenshot. Fix: change the rail call site's `restFill` argument to match the search button's, so both controls read as the same style. This is a call-site argument change only — `NewWorkspaceMenuButton.swift` itself still doesn't change.

## Control layout (expanded header only)

A new component, used only by the expanded header call site, replaces `NewWorkspaceMenuButton` there:

- **Primary hit area** (the `+` glyph): a plain `Button`, not a `Menu`. Single click calls `onNewWorkspace()` directly — no dropdown opens. This is the only behavior change that matters: the fast path becomes an actual single click instead of open-menu-then-click-first-row.
- **Chevron hit area** (small disclosure triangle, trailing edge of the control): opens a `Menu` with up to two rows — 1 when there are no other groups yet, 2 otherwise — in this order:
  1. **"New Workspace Group…"** → `onNewWorkspaceGroup()`, unchanged sheet. (Kept as the established product term — not renamed to "New Workgroup…" — to match the menu, sheets, and accessibility text everywhere else this action appears.)
  2. **"New Workspace in ▶"** → nested submenu, one row per group (unfiltered — see "Explicitly out of scope") → `onNewWorkspaceInGroup(groupID)`, unchanged instant creation.

The chevron menu never flattens the group list to the top level — the potentially-long group list stays behind the submenu hover (as it already is today). `NSMenu` submenus scroll and support type-ahead natively at any length.

Row order ("New Workspace Group…" before "New Workspace in") is a deliberate, low-confidence call — flag for revisiting if it feels wrong in practice.

**Sizing:** the primary segment matches the height of the search field chip it sits beside (`AwSpacing.searchFieldHeight`, 30pt) rather than the button's previous 34pt — the two chips on that row should read as the same size. Corner radius stays 7pt, matching the search field's pill. The chevron segment gets a comfortably-sized 22pt hit target (not the cramped 18pt an earlier draft used) — the 296pt-wide expanded row has ample room now that this treatment doesn't need to also fit the 60pt rail.

## Explicitly out of scope

- No naming prompt for any instant-creation path (primary click or "New Workspace in [Group]"). Both stay unnamed, matching current behavior exactly.
- No filtering of the group list by sidebar collapse/expand state — the submenu lists all groups, matching current behavior.
- No changes to `WorkspaceGroupCreateSheet`, `RemoteWorkspaceGroupCreateSheet`, or `WorktreeCreateForm` — those flows are untouched.
- No change to how group membership is modeled (`SessionGroup.sessions` array, no `groupID` FK) — out of scope, unaffected by this change.

## Visual/interaction notes for implementation

- No existing `DesignSystem` split-button token/pattern to reuse — hand-composed from a `Button` + `Menu` pair sharing one background pill, per the sizing above.
- Keyboard/accessibility: the primary `+` and the chevron need distinct accessibility labels/actions (e.g. "New Workspace" vs "New Workspace Options") since they're now two separate controls, not one menu button. This also means the control now claims two keyboard Tab stops instead of one — an accepted, low-severity side effect, not wired into any custom focus-order system elsewhere in the sidebar.
- A native `Menu(primaryAction:)` split control was considered instead of hand-composing one, since it would get hit-testing/focus/RTL mirroring for free. Not adopted: unverified whether it renders as a true two-segment split under `.menuStyle(.borderlessButton)` (this codebase's established borderless look), and scoping the change to the expanded header alone already resolves the geometry pressure that motivated considering it. Revisit if manual QA finds the hand-composed version's hover/focus/accessibility behavior lacking.
- RTL: the corner-radius and stacking use layout-direction-aware `leading`/`trailing` terms throughout (not `left`/`right`), which SwiftUI mirrors automatically — verify this manually in a RTL locale rather than adding a dedicated automated test, consistent with the rest of this codebase's RTL test coverage (none, presently).
- Rapid double-clicks on the primary segment are a real regression risk: the old `Menu`-gated interaction couldn't fire `onNewWorkspace` twice from one double-click (the first click consumed itself opening the menu), but a plain `Button` can. Add a short debounce guard.
