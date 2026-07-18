# Group header close badge — design

- **Issue:** [INT-739](https://linear.app/interactive-buffoonery/issue/INT-739/group-header-count-badge-morphs-into-close-group-x-on-hover)
- **Status:** Approved
- **Date:** 2026-07-06

## Summary

Hovering a sidebar group header swaps the workspace-count badge for an X button that closes every workspace in the group. Clicking it routes through the existing group-close path, so the existing confirmation policy applies unchanged: groups whose live sessions are all amx-bridged (restorable) close silently; groups with live non-restorable work get the existing "Close group?" alert.

## What already exists (and is reused unchanged)

- **Close path:** context-menu "Close Group" (`SidebarGroupHeaderView.swift`) → `onCloseGroup()` → `closeWorkspaceGroup(_:)` → `SessionStore.closeGroup(id:limitedTo:now:)` (`AwesoMuxApp.swift`).
- **Confirmation policy:** `confirmCloseGroupIfNeeded(_:)` prompts only when the group has risky sessions per `QuitRiskPolicy`, which classifies amx-bridged panes as `.safe(.daemonBacked)`. This is exactly the desired behavior; no new logic.
- **Close-button styling:** `SidebarCloseButton` in `SidebarSessionTile.swift` is the visual reference for the X glyph.

## View change

The close-badge code lives in `SidebarGroupHeaderView.swift`, expanded-mode header only (the collapsed rail renders no count badge and is untouched).

- The header's existing `.onHover` (currently clears the keyboard focus ring) also drives a new `isHeaderHovered` state.
- The X is a sibling overlay on the header (trailing-aligned, attached after the header's gesture/drag modifiers); the count text stays in layout and hides via opacity while the X shows. Overlays don't participate in layout, so swapping never shifts the header:
  - **Not hovered:** the count text, exactly as today.
  - **Hovered:** an X close button styled to match `SidebarCloseButton`, calling `onCloseGroup()`.
- Hover scope is the whole header row (matches "hover over a group title"), not just the badge.
- The X carries the same guards as the context menu's Close Group: it's suppressed while filtering, for an unresolved/stale row (nil `currentGroupIndex`), and for the sole empty group (`removeGroup` refuses the last group, so the control would be dead). INT-770 relaxed the original "any empty group" suppression: an empty group among others now shows the X like any other count, matching the context menu's disable clause; the empty-group drop target's always-visible X remains as a second path. Both controls use the shared **Close Group** label and route through the same close flow. The shared gate lives in `SidebarGroupClosePolicy`.
- The X glyph and its hit frame scale with the in-app text-size setting (INT-237), tracking the count badge it replaces so it doesn't shrink into a tiny mark under Larger Text.
- Accepted tradeoff: while the X is visible, the trailing ~20pt of the header is close-only — a group drag can't start from that slot. This matches the session tile, whose close button occupies the same position in its row.

## Accessibility

Per the INT-8 precedent, close affordances must not be discoverable only via pointer hover. This X is a **redundant pointer shortcut**, not the only close path:

- The context menu "Close Group" remains the keyboard/VoiceOver route.
- **Keyboard activation of the header is unchanged and can never trigger the close.** Today a keyboard-focused header has no Enter/Space handler at all — activation only exists via mouse tap and VoiceOver's default action, both of which toggle collapse/reveal (`onToggle()`). That stays exactly as is. The X is triggerable only by a pointer click while hovered; it is not keyboard-activatable and adds no new tab stop.
- The header is one combined accessibility element (existing behavior); its label already announces the group name and workspace count, and the X overlay is `accessibilityHidden` so hover never changes what VoiceOver sees. The VoiceOver close path is the header's existing gated "Close Group" accessibility action (in `.accessibilityActions`, chosen deliberately from the VO actions menu — the header's *default* VO activation remains collapse-toggle, so the close can't be triggered accidentally). That action is suppressed while filtering, for an unresolved/stale row, and for the sole empty group — the same guards the hover X carries.
- The empty-group body X exposes the same "Close Group" accessibility label and help text as the header action and hover X, satisfying consistent identification for the shared operation.

## Error handling

None new. Misclick recovery relies on the existing safety net: bridged sessions are restorable via amx, and closed sessions land in `recentlyClosed`. The confirmation alert continues to guard the genuinely lossy case (live non-restorable sessions). INT-770 added one more lossy case to that list: an empty **remote** group's declared SSH target is not restorable after removal, so removing an empty remote group confirms even though it has no sessions — empty local groups still remove instantly.

## Testing

- The confirmation policy is already covered by existing tests; it is not modified.
- `SidebarGroupClosePolicyTests` pins the shared action label used by the empty-group body X, context menu, header VoiceOver action, and hover help.
- Primary verification is a live smoke: build, hover a group header, confirm the morph, click, confirm silent close for an all-bridged group and the alert for a risky one.

## Out of scope

- No settings toggle, no new confirmation UI, no changes to rail mode or the pinned-workspaces synthetic header (INT-737, separate branch).
