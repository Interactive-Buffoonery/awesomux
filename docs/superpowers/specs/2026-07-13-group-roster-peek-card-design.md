# Collapsed sidebar: group roster peek card

## Scope

Collapsed sidebar only. The expanded sidebar already shows the group name and
every workspace inline — this feature does not touch it, trigger on it, or
render on it.

## Problem

The collapsed rail represents a workspace group as a thin colored tint-bar +
chevron header, with numbered session tiles below. There is no way to see
which workspaces live in a group, or jump to one, without expanding the group
(losing the compact rail) or guessing from position/color alone.

An earlier attempt (2026-07-12) tried to make the header's native `.help()`
tooltip show the group's name, and to speed up its ~2.5s delay. Neither fix
took effect in testing — `UserDefaults.standard.register(defaults:
["NSInitialToolTipDelay": 1500])` did not change the observed delay, and
`.contentShape(Rectangle())` did not visibly widen the hover hit area. Root
cause unconfirmed; suspected that SwiftUI's `.help()` on macOS 15+ does not
route through classic AppKit `NSToolTipManager` timing at all. That code was
reverted. This spec replaces the tooltip approach entirely rather than
continuing to chase it.

## Existing infrastructure this builds on

`SidebarSessionPeekCard.swift` + `SidebarPeekModel` (`SidebarSplitSupport.swift`)
already solve almost this exact problem one level down: hovering a
multi-pane workspace tile shows a floating card listing every pane, each row
clickable to jump to it, with:

- A single shared `SidebarPeekModel` (`@Observable`) owning exactly one
  floating card at a time — anchored to the hovered element's frame, floating
  to the right of the rail, clamped to screen edges.
- A hover-handoff grace (`isPointerOverCard` + a cancellable grace task) so
  moving the cursor from the trigger element into the card itself doesn't
  dismiss it before a row can be clicked.
- A single overlay in `ContentView.swift`, rendered via `GeometryReader`,
  positioned with `.position(...)` relative to the anchor.

The group roster is the same shape of problem (a list of clickable rows,
floating near the trigger, with hover handoff) at the group level instead of
the pane level. This spec extends the existing system rather than building a
parallel one.

## Design

### Architecture: one shared peek model, two content kinds

`SidebarPeekModel` gains a `PeekContent` enum:

```swift
enum PeekContent {
    case session(session: TerminalSession, location: SidebarSessionLocation, tint: ProjectTint, paneItems: [PanePeekItem])
    case group(group: SessionGroup, tint: ProjectTint, sessions: [TerminalSession])
}
```

The model still owns exactly one `PeekContent?`, plus the same anchor
geometry (`anchorX`, `anchorY`, `tileHeight`) and the same hide-grace/pointer
tracking — those mechanics don't change per content kind. Showing one kind
dismisses the other; there is never more than one floating card. This reuses
the existing race-condition handling (documented in `SidebarPeekModel`
around stale hover events and takeover-before-hide races) instead of
duplicating it in a second model.

`ContentView`'s single peek overlay switches on `model.content` to render
either `SidebarSessionPeekCard` (unchanged) or the new `SidebarGroupPeekCard`.

Rejected alternatives:
- A second, fully separate `SidebarGroupPeekModel` + second overlay: copies
  the anchor/grace/race-condition logic instead of reusing it, and makes "two
  cards visible at once" possible when it should be impossible.
- Local `@State` in the group header view (a plain popover): loses the
  existing "float right of rail, clamp to screen edges" positioning system
  for no benefit.

### Trigger

Only the collapsed group header (the tint-bar + chevron row) triggers the
roster card. Hovering an individual workspace tile continues to show the
existing single-session peek exactly as today — the two triggers are
mutually exclusive by construction (hovering a tile calls `peekModel.show`
with `.session(...)`; hovering the header calls it with `.group(...)`).

Rationale (eD, 2026-07-13): if you want a specific workspace, click it
directly; if you want to look at everything in the group, the roster scrolls
rather than stacking a peek-of-a-peek.

### Hit area

The collapsed header row currently reserves `.frame(minHeight: 14)` for
content that only occupies ~2.5–8pt of it (the tint bar, optionally a
collapsed-attention badge, and the chevron) — this, not a missing
`.contentShape`, is the real reason hover felt like it only worked "right on
top of the colored bar." Raise the reserved height to roughly 24–28pt so the
row has a click target closer to a reasonable size, while leaving the
visible tint-bar/chevron glyphs their current small size, centered within
the taller invisible box. This does not touch `density.sessionStackSpacing`
(the spacing shared by every row in the list) — only this one row's own
frame.

### Card content

`SidebarGroupPeekCard` reuses the exact chrome from `SidebarSessionPeekCard`
(padding, corner radius, border, shadow) so the two card types read as the
same visual system. Rows mirror `PanePeekRow`'s shape — agent-state icon,
title, remote indicator when `location.kind == .remote`, unread pill when
count > 0 — one row per session instead of one row per pane.

Row order and membership match whatever the collapsed rail is *already
rendering* for that group — not the raw `SessionGroup.sessions` array, which
still includes sessions `SidebarPinnedProjection` has floated out to the
synthetic Pinned section. The trigger site (wherever the collapsed header is
rendered per group) already has this filtered, ordered list on hand for
drawing the numbered tiles; hand that same list to `peekModel.show(.group(...))`
rather than re-deriving it from `group.sessions`.

Rows beyond `SidebarSessionPeekCard.maxVisibleRows` (5) scroll rather than
growing the card past the window — same threshold and mechanism the existing
pane list already uses (`ScrollViewReader`, scroll-to-active on appear).

### Click behavior

Clicking a row calls `SidebarView.selectSession(_:)` — the exact function
already used for tile clicks and the command palette's jump (`sessionStore.selectedSessionID`
+ hand keyboard focus to the active pane). No new selection path.

### Background color

`SidebarGroupPeekCard`'s background is the same base fill as
`SidebarSessionPeekCard` (`Color.aw.surface.elevated`) with a wash of the
group's own tint layered over it — `tint.hue.opacity(0.08–0.12)` — rather
than staying plain gray (which would make the two card types visually
indistinguishable) or using a fully saturated group-color fill (which eD
judged, correctly, as likely to clash with the text/icon content inside).
Border, shadow, corner radius, and the existing left-edge tint-hue accent
stripe (see `SidebarSessionPeekCard`'s `.overlay(alignment: .leading)`) stay
identical between both card types.

Exact opacity value to be confirmed visually during implementation — 0.08 and
0.12 are a starting range, not a locked number.

## Out of scope

- Drag-and-drop between groups while the sidebar is collapsed (filed
  separately as a bug, not part of this feature).
- Any change to the expanded sidebar.
- Any change to the existing single-session/multi-pane peek card's own
  behavior, styling, or triggers.
