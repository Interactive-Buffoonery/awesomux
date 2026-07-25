# UI papercuts — footer wrap, drop targets, in-group new-workspace row, inline workspace rename — design

- **Status:** Approved
- **Date:** 2026-07-24
- **Issue:** [#220](https://github.com/Interactive-Buffoonery/awesomux/issues/220)

## Summary

Four independent UI papercuts, grouped because each is small and each is
irritating — not because they share a subsystem. Papercut 1 is a layout bug in
the sidebar footer. Papercuts 2 and 3 both touch sidebar group geometry and are
worth shipping together (3 supplies a drop target 2 needs). Papercut 4 is in the
titlebar and shares nothing with the others.

Nothing here introduces a new interaction pattern. Papercut 1 uses a stdlib
container (`ViewThatFits`), 2 is a pure geometry change with no logic touched, 3
mounts an already-shipped view in one more place, and 4 ports an inline-edit
pattern that already exists and is already hardened two files over.

---

## Papercut 1 — sidebar footer agent total wraps to two lines

### Current behavior

`SidebarStatusFooter.expandedFooter` (`SidebarStatusFooter.swift:40-116`) is a
single `HStack(spacing: 4)` holding, in order: the gear button (22pt), the help
menu (22pt), one chip per non-idle state, a `Spacer(minLength: 4)`, and the total
button. The total's label is:

```swift
HStack(spacing: 4) {
    Text(LocalizedPluralStrings.footerAgentsTotal(count: total))
        .monospacedDigit()
    Image(systemName: activityPanelOpen ? "chevron.down" : "chevron.up")
}
```

No `lineLimit`. With two chips visible at a typical sidebar width the row
overflows, `Text` wraps to two lines (`5` / `agents`), and the chevron —
vertically centered in its `HStack` — lands beside neither line cleanly.

### Change

Replace the label's `Text` with a two-candidate `ViewThatFits`:

```swift
ViewThatFits(in: .horizontal) {
    totalLabel(LocalizedPluralStrings.footerAgentsTotal(count: total))
    totalLabel("\(total)")
}
```

where `totalLabel(_:)` is a small `@ViewBuilder` producing today's
`HStack { Text(…).monospacedDigit().lineLimit(1); Image(chevron) }`, so both
candidates keep identical styling, spacing, and chevron direction.

`ViewThatFits` proposes each candidate its ideal size and selects the first that
fits the available width. A `Text`'s ideal width is its single-line width, so the
full plural is chosen wherever it fits and the bare count is chosen when it
doesn't.

`.lineLimit(1)` on both candidates is load-bearing, not decoration:
`ViewThatFits` falls back to its **last** candidate unconditionally when none
fit, so without it a sufficiently narrow rail would still wrap — just with `5`
instead of `5 agents`.

### Deliberately unchanged

- **The accessibility surface.** `accessibilityLabel`, `accessibilityValue`,
  `accessibilityHint`, and `.help` are attached to the enclosing `Button`
  (`SidebarStatusFooter.swift:100-111`), not to the label. They already carry the
  full plural string and open/closed state, so VoiceOver output is identical at
  every width and no `.stringsdict` entry changes.
- **The total itself stays.** Removing it was considered and rejected. The chips
  render only `.thinking`, `.output`, `.needs` (`visibleStates`, line 24), so a
  total of 5 against chips summing to 3 is the only indication that two agents
  are idle. It is also the activity panel's sole entry point once every chip is
  hidden — the reason line 76 renders it even at `total == 0`.
- **The collapsed rail footer.** `collapsedFooter` renders no total at all.

### Verification

A hosted-view test (`SidebarHostedTestHarness` pattern, as used by
`SidebarGroupHeaderHitTargetTests`) that renders `SidebarStatusFooter` at a
narrow width with three non-zero chips and a two-digit total, then asserts the
rendered height equals `AwSpacing.footerChrome`. This fails on `main`.

---

## Papercut 2 — cross-group workspace drags are hard to land

### Root cause

The failure is **region geometry, not index resolution.**
`SidebarInsertionResolver.insertionIndex(forDropY:)`
(`SidebarInsertionIndicators.swift:45-72`) already handles out-of-row y values
correctly: a y above the first row's `midY` returns `0`, and a y below every
row's `midY` falls through the loop to `fallbackIndex == orderedIDs.count`
(append). It also returns `nil` rather than guessing when no frame has non-zero
height, so an unpopulated cache holds the drop instead of biasing it to the end.

The problem is that during a workspace drag two bands of the sidebar belong to no
workspace drop target at all:

| Band | Owner | Comfortable | Compact |
|---|---|---|---|
| Between two groups | `LazyVStack(spacing: density.groupStackSpacing)` (`SidebarView.swift:191`) | 14pt | 8pt |
| Header → first tile | group's outer `VStack(spacing: density.sessionStackSpacing)` (`SidebarGroupView.swift:122`) | 5pt | 3pt |

The inter-group band is owned by the `LazyVStack`, whose only drop delegate is
`SidebarGroupReorderDropDelegate` — and that delegate's `validateDrop` requires
`activeDragKind == .group`, so it rejects every workspace drag. The header→tile
band is plain `VStack` spacing owned by nobody.

Dragging a tile downward toward the next group therefore crosses dead space,
which fires `dropExited` on the delegate being left. That calls
`clearWorkspaceHoverState()`, nils `workspaceDropIndex`, and blinks the insertion
indicator out mid-traverse. The indicator flickering off at exactly the moment
the user is aiming is what reads as "the drop zone isn't there."

### Change

Extend both regions with **bottom-only** padding, reclaimed by matching negative
padding applied *after* the drop modifier, in `SidebarGroupView.body`:

```swift
// Header — closes the header→first-tile band.
SidebarGroupHeaderRow(...)
    // Indicator overlay MUST precede the padding — see "Modifier order" below.
    .overlay(alignment: .bottom) { /* header insertion indicator, unchanged */ }
    .padding(.bottom, density.sessionStackSpacing)
    .sidebarDrop(enabled: ..., delegate: SidebarWorkspaceHeaderDropDelegate(...))
    .padding(.bottom, -density.sessionStackSpacing)

// Tile stack — closes the inter-group gutter.
VStack(spacing: density.sessionStackSpacing) { tiles }
    .coordinateSpace(name: coordinateSpaceName)
    .animation(structuralAnimation, value: sessionIDs)
    .onPreferenceChange(SidebarRowFramePreferenceKey.self) { ... }
    .onChange(of: sessionIDs) { ... }
    .overlay(alignment: .topLeading) { /* insertion indicator, unchanged */ }
    .padding(.bottom, density.groupStackSpacing)
    .sidebarDrop(enabled: ..., delegate: SidebarWorkspaceListDropDelegate(...))
    .padding(.bottom, -density.groupStackSpacing)
```

### Modifier order

The padding pair must bracket **only** `.sidebarDrop`. Everything that anchors to
a bottom edge has to sit above the expansion.

The header's insertion indicator is
`.overlay(alignment: .bottom) { SidebarInsertionIndicator(...).offset(y: height / 2) }`
(`SidebarGroupView.swift:188-194`), and it is the **only** bottom-anchored
modifier in that chain — the tile stack's is explicitly `.topLeading`
(`SidebarGroupView.swift:332`). Today it anchors to the header's real bottom.
Placed *between* the two paddings it would anchor to the padded bottom and render
`sessionStackSpacing` too low — the trap being that `.sidebarDrop` currently sits
*before* the overlay at lines 165-194, so natural reading order reproduces exactly
that mistake.

Hoisting the overlay above the bracket is **sufficient and least ambiguous**
rather than strictly necessary: placing it after the negative reclaim would also
anchor to the restored frame and be correct. Hoisting is preferred because it
stops the indicator's position depending on the reclaim being present — so
temporarily deleting the reclaim line (which the plan asks for, to prove the
geometry guard is live) cannot silently move the indicator at the same time.

The tile stack's indicator is `.overlay(alignment: .topLeading)` with an explicit
`insertionY` offset, so it anchors to the top-left and is unaffected by bottom
padding regardless of order. It is placed above the padding anyway, for symmetry
with the header.

`.coordinateSpace` placement is genuinely immaterial here: bottom-only padding
leaves the top-left origin identical, so the named space has the same origin
whether it's applied to the padded or unpadded view. This is only true because
the padding is bottom-only — with `.padding(.top,)` the ordering would become
load-bearing and easy to get wrong, which is a third reason to keep it
bottom-only.

### Why this exact shape

Two constraints rule out the more obvious formulations.

**Bottom-only padding — never `.padding(.top,)`.** Row frames are measured
`proxy.frame(in: .named(coordinateSpaceName))` from inside each tile's
background, and `DropInfo.location` is expressed relative to the view carrying
the delegate. For the hit-test to be correct, those two must share an origin.
Padding only the bottom leaves the padded view's top-left origin exactly where it
was, so both stay in the same space and **no coordinate math changes anywhere.**
Padding the top moves the origin and silently offsets every hit-test by half a
gap — a 7pt error that produces occasional off-by-one insertions rather than an
obvious failure.

**Reclaim the space rather than zeroing the stack spacings.** The alternative —
`LazyVStack(spacing: 0)` plus real padding inside each group — has three
problems that reclaiming avoids:

1. *Collapsed groups lose their gutter.* The tile stack lives inside
   `if !isCollapsed` (`SidebarGroupView.swift:196`), so a collapsed group would
   contribute no bottom padding and would butt against the next group.
2. *Group reorder boundaries move.* `SidebarGroupFramePreferenceKey` is reported
   from a background on the whole group view (`SidebarView.swift:314-324`), so a
   group whose frame grew by 14pt has its `midY` — and therefore its
   `SidebarGroupReorderDropDelegate` flip point — shifted down 7pt.
3. *Visual regressions are possible.* Reclaiming keeps the reported frame
   byte-identical, so there is nothing to eyeball.

Because the negative padding restores the reported size, the change is invisible
to layout, to collapsed groups, to group frames, and to group reordering. The
only thing that changes is which view wins the hit test for points inside the
gutter.

### Effect

Between the first group header and the last tile of the last group, every point
now belongs to some workspace drop delegate. `dropExited` stops firing
mid-traverse, so the insertion indicator stays lit continuously as the pointer
crosses a group boundary. A point in the gutter below group A resolves via the
existing `fallbackIndex` path to "append to A"; group B's header remains a
separate target for "insert at top of B", as today.

### Scope boundaries

- **Pinned-section crossing stays out of scope.** `activeDragSourceIsPinned`
  gates group delegates off during a pinned drag, and
  `SidebarPinnedReorderDropDelegate` accepts only pinned-sourced drags. Both
  carry explicit "out of scope for v1" comments naming the context menu as the
  pin/unpin path. This design does not change that.
- **Group reordering is untouched**, by construction (see above).
- **Collapsed-group drops are untouched.** Only the header is a target there
  because the tile stack isn't rendered; that remains true.

### Verification

- A `SidebarInsertionResolverTests` case asserting that a y in the reclaimed
  gutter (`lastTileFrame.maxY + groupStackSpacing`) resolves to
  `orderedIDs.count`.
- A hosted drag test if `SidebarHostedTestHarness` supports synthetic drag
  sessions. **If it does not, the resolver test plus manual verification is the
  honest limit, and the PR body must say exactly that** rather than implying
  end-to-end coverage that doesn't exist.

---

## Papercut 3 — no `+ new workspace` affordance inside a populated group

### Current behavior

`EmptyGroupDropTarget` (`SidebarDropDelegates.swift:473-595`) renders precisely
the wanted row: a `+` glyph, the text `new workspace`, an elevated fill, a dashed
border that goes mauve while drag-targeted, and a trailing remove-group X. It is
mounted only under `if sessions.isEmpty && displayMode != .collapsed`
(`SidebarGroupView.swift:288`). Adding a workspace to a populated group therefore
always costs a trip through the header dropdown.

### Change

Mount the row for populated groups as well, reusing the same view rather than
writing a second one. Three differences by case:

| | empty group | populated group |
|---|---|---|
| `canRemoveGroup` | as today | `false` — the header's hover X owns removal |
| `onAcceptDrop` | `onMoveSession(id, group.id, 0)` | `onMoveSession(id, group.id, SessionStore.appendIndex)` |
| resting border | dashed | none — new `showsRestingBorder: Bool` parameter |

Rename `EmptyGroupDropTarget` → `NewWorkspaceInGroupRow`, since it stops being
empty-only. `SessionStore.appendIndex` already exists
(`SessionStore.swift:19`) and is already used for group-targeted moves
(`SidebarGroupView.swift:238`).

### Why the row keeps its own drop delegate

For a populated group the row sits inside the tile stack, which already carries
`SidebarWorkspaceListDropDelegate`. Nesting is correct rather than redundant:
SwiftUI routes a drop to the innermost accepting view, so hovering the row targets
`SidebarEmptyWorkspaceDropDelegate` (lighting the row's border) while the list
delegate receives `dropExited` and clears the insertion line. That handoff is the
already-shipped empty-group behavior, and `clearWorkspaceHoverState` is already
wired for it. `appendIndex` makes the landing position match where the row
visually sits — the existing index-`0` handler would contradict it.

Dropping a tile onto its own group's row moves it to the end of that group, which
is a legitimate reorder rather than a no-op to guard against.

### Interaction with papercut 2

The row is roughly 28pt tall and sits at the bottom of the tile stack, inside the
region papercut 2 extends by another 14pt. Together they turn
"append to this group" from a half-tile-tall sliver into a ~42pt target. This is
why the two are worth shipping in one PR.

### Clutter risk

Real, and dropping the dashed border at rest is the mitigation: one faint
`textFaint` row per group, matching the footer's resting weight, lighting up only
under an active drag. If it still reads as noisy in practice, the fallback is
gating visibility to group hover — deliberately **not** built now, because
hover-driven group height animation is a known flake source in this codebase and
should not be added speculatively.

### Verification

- A hosted test asserting the row is present and clickable for a populated group
  (mirroring `SidebarGroupHeaderHitTargetTests`' click-point approach) and that
  clicking it invokes `onNewSessionInGroup`.
- A test asserting the populated-group row omits the remove-group X, so group
  removal keeps exactly one pointer path per state.

---

## Papercut 4 — workspace rename is a modal sheet; pane rename is inline

### Current behavior

Double-clicking a pane title enters an inline `TextField` in place
(`PaneTitleBarView.swift:72-90`). Double-clicking the workspace title in the
titlebar calls `onRenameWorkspace(session)` (`ContentView.swift:743`), which
routes to `workspaceEditRequest` and presents `WorkspaceEditSheet`
(`AwesoMuxApp.swift:384-395`) — a modal with a Name field and Cancel/Save.

### Why the split exists

Not an architectural constraint. `AppTitlebarView` is a plain SwiftUI view at the
top of a `VStack(spacing: 0)` in `ContentView.swift:326` — the window hides its
real titlebar and awesoMux draws its own band inside the content hierarchy. It is
**not** an `NSTitlebarAccessoryViewController`, so it shares the content view's
responder chain and a `TextField` + `@FocusState` behaves exactly as it does in
the pane title bar.

The titlebar even already has the matching AppKit half.
`WindowDragRenameHandle.DragRegionView` (`ContentView.swift:789-830`) makes the
same `clickCount >= 2`-vs-press-drag disambiguation as `PaneDragSource`,
including the same deferred-`performDrag` handling and the same comment
explaining that entering the modal drag loop on the first click of a double-click
swallows the second.

The split exists because `onDoubleClick` was wired to `onRenameWorkspace`, an
app-level callback shared by four call sites — titlebar double-click
(`ContentView.swift:743`), titlebar a11y action (`ContentView.swift:756`),
sidebar tile (`SidebarView.swift:300` and `:947`), and `SessionDetailView` — all
landing on the same sheet. The one caller with a visible text label to inline
into never got specialized.

### Change

Port the `PaneTitleBarView` inline-edit pattern into `workspaceCluster`
(`ContentView.swift:721-758`). `AppTitlebarView` gains
`@State private var isEditing`, `@State private var draft`, and
`@FocusState private var isFieldFocused`, and the cluster renders a `TextField`
in place of `Text(session.title)` while editing.

Every behavior below already exists in `PaneTitleBarView` and is reused rather
than re-derived:

| Behavior | Source pattern |
|---|---|
| commit on ⏎ | `.onSubmit { commit() }` |
| cancel on esc | `.onExitCommand { isEditing = false }` |
| commit on click-away | `.onChange(of: isFieldFocused) { if !$1 { commit() } }` |
| no double-commit | `commit()` early-returns unless `isEditing` |
| blank input | commit resolver returns "no rename" rather than storing an empty title |
| unchanged input | commit resolver returns no-change, no store write |
| stale draft can't land on the wrong target | `onChange(of: session?.id) { isEditing = false }` |
| drag handle yields to the field | `WindowDragRenameHandle` wrapped in `if !isEditing` |

One semantic difference from panes: a pane has a live terminal-supplied title to
fall back to, so blank input means `.reset` and
`PaneTitleBarView.resolveCommit` has three cases. A workspace title has no live
source, so blank input is simply rejected (leave the title as-is and exit edit
mode) — two cases, and the resolver is a separate `nonisolated static` function
on `AppTitlebarView` rather than a reuse of `PaneTitleBarView.resolveCommit`.

### Scope

Only the titlebar double-click and its a11y action go inline. The sidebar
context-menu and `SessionDetailView` paths keep `WorkspaceEditSheet` unchanged.
This mirrors panes exactly — inline on double-click, `PaneEditSheet` from
elsewhere (`AwesoMuxApp.swift:396`) — so it follows the shipped pattern rather
than creating a new inconsistency. Making the sidebar tile rename inline as well
is a reasonable follow-up and explicitly out of scope here.

### Risks to verify in a running build

1. **First responder vs. the terminal surface.**
   `GhosttySurfaceContainerView` reclaims first responder only when the responder
   is vacant, and `PaneCloseButton` exists as an `NSButton` with
   `refusesFirstResponder` precisely because a SwiftUI `Button` stealing focus
   broke that reclaim path. The pane title bar's `TextField` demonstrates the
   mechanism works from inside the content area, and the titlebar is the same
   window and responder chain — but this must be confirmed running, not argued
   from the code.
2. **Field width.** `Text(session.title)` sizes to content, so a naive swap
   produces a field that jitters wider with each keystroke. The editing field
   needs a definite frame — greedy within the cluster but capped so it does not
   stretch toward the window edge — and the cluster sits inside
   `HStack { workspaceCluster; Spacer(minLength: 12) }`
   (`ContentView.swift:696-707`), so the cap belongs on the field.
3. **Titlebar background drag layer.** The band's background includes a
   `Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())` layer
   (`ContentView.swift:602-605`). It sits behind the cluster, so it does not
   compete with the field, and a click in the empty space beside the field starts
   a window drag and drops focus — which commits, matching the pane bar. Worth
   confirming rather than assuming.

### Pre-existing, explicitly out of scope

Menu key equivalents are not swallowed by a SwiftUI `TextField`, so ⌘W during a
rename acts on the workspace rather than the text field. This is already true of
the pane title bar's inline rename, so matching it is consistency rather than a
new regression. Fixing it belongs in a separate change covering both.

### Verification

- Unit test on the new commit resolver: blank → no rename, unchanged → no write,
  whitespace-only → no rename, changed → rename with the sanitized title.
- Hosted test asserting a double-click on the titlebar workspace name enters edit
  mode (rather than requesting the sheet) and that ⏎ commits through
  `sessionStore.renameSession`.
- Manual verification of the two focus risks above, since neither is expressible
  in a unit test.

---

## Sequencing

Papercuts 2 and 3 ship together — 3 supplies a drop target 2 wants, and both
touch `SidebarGroupView.body`. Papercuts 1 and 4 are independent of everything
and of each other.

Recommended split: one PR for 1 + 2 + 3 (all sidebar), a second PR for 4
(titlebar, and the only one carrying focus-behavior risk that deserves its own
review and its own revert boundary).
