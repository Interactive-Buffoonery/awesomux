# 0018 - Markdown document pane stays on TextKit 2

## Status

Accepted (INT-566).

## Context

The markdown document pane renders through a TextKit 2 `NSTextView`
(`MarkdownTextView` / `SelectionAwareTextView`). Two shipped features depend on
TextKit-2-only APIs: source-anchored scroll capture/restore (INT-567) and the
comment-badge overlay, both of which walk `textView.textLayoutManager` via
`enumerateTextLayoutFragments` and `textLineFragments`.

INT-566 adds GFM table rendering. The issue's original wording called for
`NSTextTable` / `NSTextTableBlock`, the AppKit primitives for boxed table
layout. Those are laid out only by `NSLayoutManager` (TextKit 1);
`NSTextLayoutManager` (TextKit 2) ignores text blocks. Touching
`NSTextView.layoutManager` silently migrates the view to TextKit 1 and makes
`textView.textLayoutManager` return nil — which would break the INT-567 scroll
anchor and the badge overlay outright.

## Decision

- The markdown document pane stays on TextKit 2. Reverting to TextKit 1 to gain
  native `NSTextTable` layout is rejected, now and going forward.
- Tables are laid out with `NSTextTab` tab stops on an `NSMutableParagraphStyle`
  (native under TextKit 2, per-column alignment) for columns, and cell/grid
  **borders** are drawn by `CommentBadgeOverlay` (a transparent subview of the
  text view, whose `draw(_:)` reliably fires — an `NSTextView.draw(_:)` override
  is NOT invoked for the TextKit-2 content pass). It reads the `.tableCellGrid`
  attribute and computes cell rects via `NSTextLayoutManager.enumerateTextSegments`
  — container-space geometry with no window/on-screen dependency, the same
  reliable path the scroll-anchor code uses. `firstRect(forCharacterRange:)` was
  tried first and rejected: it returns a screen rect that is `.zero` until the
  window is materialized and layout settles, which made borders flake across
  launches.
- Per-column alignment is parsed from the source delimiter row in
  `AttributedMarkdownBuilder`, because swift-markdown 0.8.0 exposes
  `Table.columnAlignments` (and `head` / `body` / `cells`) only as module-internal
  members — they are unreachable from `AwesoMuxCore`. Table traversal therefore
  goes through the public `Markup.children`, not the typed accessors.

## Consequences

- Table cells remain first-class runs with real source ranges, so the PR2
  selection→comment flow works on a single cell unchanged; a `SelectionSourceMapping`
  guard rejects selections spanning more than one cell (can't `<mark>` across a `|`).
- No cell borders come "for free" from AppKit — the grid is drawn by us. The
  drawn approach yields the boxed look without the TextKit-1 regression, at the
  cost of maintaining the border pass alongside the layout geometry.
- Known layout ceilings of the tab-stop row model:
  - An `NSTextTab`'s alignment governs the text after that tab, so column 0 (no
    leading tab) always renders left-aligned regardless of its GFM alignment;
    columns 1+ honor alignment. Upgrade path: emit a leading tab per row and shift
    the stops by one.
  - A row is one paragraph, and `NSParagraphStyle` wrapping is per-paragraph, so
    cells cannot wrap at their column edge. **Amended (INT-687):** a table wider
    than the pane no longer wraps — the text container is effectively infinite in
    both axes, prose wraps via per-paragraph `tailIndent` (managed by
    `MarkdownTextViewCoordinator.updateDocumentGeometry()`), and wide tables
    overflow into a horizontal scroll. In-cell wrapping remains out of reach under
    this decision (it needs a per-cell layout primitive). The wrapped-cell border
    suppression (multi-segment detection) is retained as a safety net.
- Accessibility **(amended, INT-687)**: tables are exposed to VoiceOver as a full
  AXTable tree — table → rows/columns → cells with row/column counts, index
  ranges, and header association — built by `CommentBadgeOverlay` from the same
  cell geometry as the drawn grid. Cell labels keep the header-association text
  ("Status: Active") from the original slice.
- Any future need for true `NSTextTable` boxed layout would require re-opening
  this decision and rewriting the scroll-anchor + badge code against
  `NSLayoutManager` — a deliberate, tracked change, not a silent downgrade.
