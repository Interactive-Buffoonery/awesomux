# Branch changes tab: collapsible files, counts, and refresh

Issue: #570. Builds on #495 / #541 (Show Branch Changes renders `git diff` into a read-only Markdown document tab) and the per-file restyle in `3385c51`.

## Goal

Make a long branch diff scannable: each file section can be folded to its heading, the heading always shows the file's added and removed line counts, hunk headers read as dividers, and the tab can refresh itself for the terminal it came from.

## Decisions already made

- Counts live in the heading permanently (`+38 −2`), collapsed or expanded, so a row never changes height when toggled.
- Collapsed state is session memory only: it survives tab switches and in-place refresh, and resets to all-expanded on relaunch.
- Counts are computed and drawn by the view layer. The renderer, the Markdown on disk, and the cache slot are untouched.
- Line numbers are not drawn in this pass. The section index keeps each hunk's parsed `@@` header (old/new start and length); a gutter later derives every line's number from that in the same walk that counts lines today. Storing per-line numbers now was rejected in review as memory spent on a feature that does not exist.
- The hunk header keeps its `@@ -a,b +c,d @@` text. The row reads as a divider through a neutral band and a hairline, with no text substitution.

## Constraints

- Everything is view-layer (`Sources/awesoMux`) except one pure helper on `RenderedDocument` for folding, which is Core because the selection and scroll-anchor mapping consume `RenderedDocument.runs` directly.
- The 1:1 text-storage invariant (`attr.string == doc.runs.map(\.text).joined()`) holds against the *folded* document. Surviving runs keep their original `sourceRange` / `enclosingRange` / `preciseMapping`, so INT-567's scroll anchor and `SelectionSourceMapping` need no changes.
- Only tabs with `generatedDocumentKind == .branchChanges` build a section index. Ordinary Markdown with a `diff` fence renders as it does today.
- Catppuccin palette throughout: counts use `Color.aw.terminalHue(.green/.red, terminalBackground:)` like the sign glyphs; the hunk band uses the existing `Color.aw.blue` hue at row-tint alpha; the hairline uses the separator token.
- The overlay draws above text at the same alpha discipline as the row tints (0.14), never opaque boxes over glyphs.

## Design

### 1. Section index (view layer, pure)

`BranchDiffSectionIndex` is built from `RenderedDocument.runs` once per render on a branch-changes tab.

Every level-2 heading is a section. The renderer emits one per file, including fence-less headings for pure renames and copies; those are sections with no body, not foldable, with zero counts, and they still get a sticky-header row so scrolling through a renamed file never leaves the previous file's name pinned. Mode-only changes keep their `old mode`/`new mode` lines inside the fence, so they render a fence with no added or removed lines and fold like any other file. It records:

- `key`: the path half of the heading (its non-italic runs, with the trailing separator before the italic status trimmed), so a fold keyed while the file read `— new file` still applies after the file is committed or the language changes. A newline-separated ordinal disambiguates repeated paths; newlines cannot occur in heading text, so no real path can collide. `title` keeps the full heading text for display.
- `headingRange`: the heading's character range in the joined text, and its run index.
- `bodyRuns`: the half-open run-index range a fold removes: the heading's own trailing block separator, then the fence (diff lines, their line separators, an overflow code run). Not the separator after the fence, so whatever follows (the next heading, or the closing truncation notice, which the renderer appends after the last file) keeps exactly one separator from the heading. Folding the last file therefore never hides the notice.
- `added`, `removed`: counts of `.diffLine(.added)` / `.diffLine(.removed)` runs in the body.
- `hunks`: for each `.diffLine(.hunk)` run, its run index and its parsed header. Parsing is tolerant: `-0,0`, a missing `,len` (length 1), and an unparsable header (nil), never a crash. Lines past the builder's 20 000-line fence cap live in one code run; the index still counts them so the badge stays honest.

The index is a value type with no AppKit imports and is unit-tested directly.

### 2. Folding (Core helper + view input)

`RenderedDocument.folding(sections: [Range<Int>])` returns a derived `RenderedDocument` with the given run-index ranges removed and the remaining runs otherwise identical. It does not renumber source ranges. The view computes the ranges from the index and the collapsed key set.

`MarkdownTextView` gains `collapsedSections: Set<String>` and `onSectionToggled: (String) -> Void`. Its coordinator treats a change to the collapsed set like a text-color change: it rebuilds the attributed string from the folded document through `MarkdownAttributedStringBuilder`, re-runs the overlay update, and restores scroll so the heading that was toggled keeps its viewport position (record the heading's y before the rebuild, scroll by the delta after).

A selection is remapped through its source span after a fold, so selecting text in one file and folding another keeps the selection; a selection inside the folded body is cleared.

### 3. Chrome, drawn by `CommentBadgeOverlay`

For each section in the index the overlay draws, in the text view's flipped coordinate space:

- A chevron (`chevron.down` expanded, `chevron.right` collapsed) at the heading's leading edge. Branch-changes headings get a head indent of one chevron width plus spacing so the glyph sits in the text's margin, not over its first letter.
- A counts badge right-aligned on the heading row (the trailing edge of the text container, the way VS Code and GitHub place it): `+n` in the green hue, `−m` in the red hue, in a small monospaced-digit font, vertically centred on the heading's first line fragment. A zero count is still shown (`+0`), so the badge shape is stable.
- On hunk rows: a full-width band in the blue hue at `diffTintAlpha`, and a 1pt hairline along the top edge. Rows are computed by the same fragment walk as the green/red tints, keyed off a new `.diffLineTint` value for `.hunk`.

Hit testing: the whole heading row (heading line fragment rect, full width) toggles the section; `hitTest` returns the overlay for those rects and `resetCursorRects` sets the pointing hand there. A click calls `onSectionToggled(key)`.

Accessibility: each section heading is exposed as a button child (like the comment pills), label `"<path>, <n> added, <m> removed"`, value `"expanded"` / `"collapsed"`, press toggles. The pill children and table elements remain.

Keyboard: a footer control (section 5) toggles Collapse All / Expand All. It is a real SwiftUI button, so Full Keyboard Access reaches it. Per-heading keyboard toggling is not in scope.

### 3b. Sticky section header

While a file's body is scrolled under the top edge, that file's heading pins to the top of the viewport as a 30pt bar: chevron, path, counts, on the terminal background with a hairline beneath. The next heading pushes it up as it approaches and takes over once it reaches the edge, so exactly one heading is ever pinned and a heading that is visible in place is never drawn twice. The bar is a plain AppKit view added to the scroll view above the clip view, repositioned from the clip view's bounds-change notification using the overlay's section geometry. Placement is a pure function (visible top, heading rows, header height) and is unit-tested. Clicking the bar scrolls to that heading and toggles the section. The bar is not an accessibility element: the document's own heading text and the overlay's per-heading button already carry that identity, and a third copy per file is noise.

### 4. State

`DocumentTabMemory.Entry` gains `collapsedSections: Set<String>`. Reads and writes go through the existing path-pinned accessors, so the inline Files browser replacing a tab's file drops the set with the rest of the entry, and closing the tab drops it via `prune(keeping:)`.

On refresh the cache file path is unchanged, so the entry survives. Keys that no longer match a section are ignored; they are not pruned until the entry is next written.

### 5. Refresh

`DocumentPaneView`'s footer for `generatedDocumentKind == .branchChanges`:

- A `Refresh` button (`arrow.clockwise`) styled like the transcript tab's Resume button, with the caption "Read-only generated document" beneath it.
- Beside it, a `Collapse All` / `Expand All` toggle that flips every section key in the index into or out of the memory set.
- Disabled, with the reason as caption, when the tab's associated terminal pane cannot be resolved ("This tab's terminal was closed") or a refresh for that pane is in flight. In-flight state comes from the coordinator, which becomes observable and exposes the set of panes with an active ticket, so a menu-started refresh disables the footer button too.

The opener currently reads the session's active pane for the working directory and the remote gate; it takes the pane explicitly instead. The app's `showBranchChangesForActivePane()` body moves into `showBranchChanges(forPane paneID:)`. The menu command resolves the active pane and calls it; the button resolves the tab's pane through the layout's document-to-terminal association (the same resolution `AgentTranscriptResumeStaging` uses) and calls it. Both routes hit the same coordinator ticket, remote-pane gate, and completion path, so a refresh from the button and a re-invoked menu command are indistinguishable downstream.

Transcript tabs and remote snapshots keep their current footers.

### 6. Not in this pass

- Line-number gutter (index carries the data).
- Persisting collapsed state across relaunch.
- Side-by-side view, syntax highlighting, editing.
- Per-heading keyboard toggling inside the text view (Collapse All / Expand All is the keyboard path).
- Per-line VoiceOver roles: a spike stamped `.accessibilityCustomText` (value must be a one-element `[String]`; a bare `String` crashes the accessibility bridge) on added and removed diff lines, and the attribute reached `NSTextView.accessibilityAttributedString(for:)` in a headless test, but a live VoiceOver session never spoke it, so it was removed; VoiceOver still reads the leading `+`/`-` of each line, which is the usable cue; per-line roles remain a follow-up on #570.

## Testing

- `BranchDiffSectionIndexTests` (app test target): section boundaries, counts, key collisions, hunk header parsing (`-0,0`, missing length, garbage), per-line numbering across context/added/removed lines, non-branch-changes documents produce no index.
- `RenderedDocumentFoldingTests` (Core): runs elided, text invariant holds, source ranges preserved, folding an empty set is identity, out-of-range ranges are ignored.
- `MarkdownDiffLineStylingTests` additions: hunk rows carry the blue tint; a folded document renders no body text for the collapsed key.
- Overlay tests against a headless TextKit 2 text view (the pattern from `3385c51`): chevron and badge rects land on the heading's line fragment, heading-row hit test returns the overlay, a click fires the toggle callback with the right key, accessibility children include one button per section with the expected label and value.
- `DocumentTabMemoryTests`: collapsed set survives a same-path write, drops on path change and on prune.
- Refresh routing tests: the shared entry point receives the associated pane for the button and the active pane for the menu; a closed associated pane disables the button with the caption.
- GUI smoke on a dev build with a GIF: fold and unfold, counts, hunk bands, refresh keeps folds, Collapse All.
