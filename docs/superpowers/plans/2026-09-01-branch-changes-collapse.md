# Branch Changes Collapse, Counts, Sticky Header, Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Show Branch Changes tab, each file section folds to its heading, headings carry `+n −m` counts, the current file's heading pins to the top while scrolling, hunk headers read as dividers, and the footer refreshes the diff for the tab's own terminal.

**Architecture:** A pure section index is built from the rendered runs (view target). Folding derives a `RenderedDocument` with body runs removed (Core helper) and everything downstream renders that document unchanged. The attributed-string builder stamps a section-key attribute on file headings; the badge overlay reads it to draw chevrons and counts and to take clicks; a sticky header view in the scroll view mirrors the current section. Collapsed keys live in `DocumentTabMemory`. Refresh is the existing app command with an explicit pane id, reached from the send bar through an environment value.

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSTextView / TextKit 2), Swift Testing, `Color.aw.*` Catppuccin tokens, `./script/swift-test.sh --filter`, `./script/format.sh`, `./script/update_string_catalog.sh`, `./script/preflight.sh`.

**Spec:** `docs/superpowers/specs/2026-09-01-branch-changes-collapse-design.md`

## Execution order and review provenance

This plan passed an architecture review and a cross-model adversarial review on 2026-09-01; their findings are folded in below. Execute in this order, not by task number: **Task 9 (VoiceOver spike) first**, because its result decides an attribute Task 4 stamps; then Tasks 1, 2, 3, 4, 5, 6, 8; **Task 7 (sticky header) last**, after its Step 0 falsification experiment. Tasks 1–6 and 8 are a complete, shippable feature on their own; if Task 7's Step 0 comes back messy, split it into its own PR rather than let it eat the review budget. Task 10 closes.

## Global Constraints

- macOS 15+, SwiftPM; new tests use Swift Testing (`@Suite`, `@Test`, `#expect`). Overlay/TextKit tests are `@MainActor` and use a headless `NSTextView(usingTextLayoutManager: true)` (pattern in `Tests/awesoMuxTests/MarkdownDiffLineStylingTests.swift`).
- Localized strings: literal-as-key `String(localized: "…", comment: "…")`, never `defaultValue:`. After adding strings run `./script/update_string_catalog.sh` and commit `Resources/Localizable.xcstrings`.
- Colors from `Color.aw.*` only. Counts: `Color.aw.terminalHue(.green/.red, terminalBackground:)` (same as `MarkdownAttributedStringBuilder.DiffPalette`). Hunk band: `DiffPalette.hunk` at `CommentBadgeOverlay.diffTintAlpha` (0.14). Hairlines: `Color.aw.border2`.
- The 1:1 invariant `attr.string == doc.runs.map(\.text).joined()` must hold for the document handed to `MarkdownAttributedStringBuilder`; folding therefore happens on `RenderedDocument` before building, never on the attributed string.
- Only `generatedDocumentKind == .branchChanges` tabs build a section index. Plain Markdown with a diff fence is unchanged.
- Format only files you changed: `./script/format.sh path/To/File.swift` (it reflows whole files; check `git diff --stat` for churn). Run `./script/swift-test.sh --filter <TypeName>` and confirm a non-zero test count (a filter matches type names, not `@Suite` display names).
- Never `git add -A`. `Package.resolved` and `.awesomux/` are untracked and stay untracked. Subagents do NOT commit; the orchestrator commits after review.
- No em dashes in code comments or UI copy is required; keep comments to the non-obvious reason.

---

### Task 1: `RenderedDocument.folding(removingRunRanges:)` (Core)

**Files:**
- Modify: `Sources/AwesoMuxCore/Markdown/RenderedDocument.swift` (after the `RenderedDocument` init, ~line 205)
- Test: `Tests/AwesoMuxCoreTests/Markdown/RenderedDocumentFoldingTests.swift` (create)

**Interfaces:**
- Produces: `public func folding(removingRunRanges ranges: [Range<Int>]) -> RenderedDocument` on `RenderedDocument`. Ranges are half-open run indices into `self.runs`; overlapping or out-of-bounds ranges are clamped and unioned; the result keeps `source`, `annotations`, `taskProgress` and the surviving runs unmodified (same `sourceRange`, `enclosingRange`, `preciseMapping`).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AwesoMuxCore

@Suite("RenderedDocument folding")
struct RenderedDocumentFoldingTests {
    private func run(_ text: String, _ style: RunStyle = .body, source: Range<Int>? = nil) -> RenderedRun {
        RenderedRun(text: text, style: style, sourceRange: source, enclosingRange: source, preciseMapping: source != nil)
    }
    private func doc(_ runs: [RenderedRun]) -> RenderedDocument {
        RenderedDocument(source: "src", runs: runs, annotations: [], taskProgress: TaskProgress(done: 0, total: 0))
    }

    @Test("removed ranges drop those runs and keep the others byte-identical")
    func removesRanges() {
        let d = doc([run("h", .heading(level: 2), source: 0..<1), run("\n", .blockSeparator), run("+a", .diffLine(.added), source: 5..<7), run("\n", .blockSeparator), run("tail", source: 9..<13)])
        let folded = d.folding(removingRunRanges: [2..<4])
        #expect(folded.runs.map(\.text) == ["h", "\n", "tail"])
        #expect(folded.runs[2].sourceRange == 9..<13)
        #expect(folded.runs[2].preciseMapping == true)
        #expect(folded.source == d.source)
    }

    @Test("an empty range list is the identity")
    func identity() {
        let d = doc([run("a"), run("b")])
        #expect(d.folding(removingRunRanges: []).runs == d.runs)
    }

    @Test("out-of-bounds and overlapping ranges are clamped and unioned")
    func clampsAndUnions() {
        let d = doc([run("a"), run("b"), run("c"), run("d")])
        let folded = d.folding(removingRunRanges: [1..<3, 2..<10, (-4)..<0])
        #expect(folded.runs.map(\.text) == ["a"])
    }

    @Test("the joined text of the folded document equals the joined text of the kept runs")
    func joinedTextInvariant() {
        let d = doc([run("x"), run("y"), run("z")])
        let folded = d.folding(removingRunRanges: [1..<2])
        #expect(folded.runs.map(\.text).joined() == "xz")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter RenderedDocumentFoldingTests`
Expected: compile error, `folding(removingRunRanges:)` undefined.

- [ ] **Step 3: Implement**

Add to `RenderedDocument` in `RenderedDocument.swift`:

```swift
    /// A copy with the runs in `ranges` (half-open run indices) removed and
    /// every surviving run untouched. Source ranges are deliberately not
    /// renumbered: they index `source`, which is unchanged, so selection and
    /// scroll-anchor mapping keep working on the folded document.
    public func folding(removingRunRanges ranges: [Range<Int>]) -> RenderedDocument {
        guard !ranges.isEmpty else { return self }
        var removed = [Bool](repeating: false, count: runs.count)
        for range in ranges {
            let lower = max(0, range.lowerBound)
            let upper = min(runs.count, range.upperBound)
            guard lower < upper else { continue }
            for i in lower..<upper { removed[i] = true }
        }
        let kept = runs.indices.filter { !removed[$0] }.map { runs[$0] }
        return RenderedDocument(source: source, runs: kept, annotations: annotations, taskProgress: taskProgress)
    }
```

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter RenderedDocumentFoldingTests`
Expected: 4 tests pass.

- [ ] **Step 5: Format and hand off**

Run: `./script/format.sh Sources/AwesoMuxCore/Markdown/RenderedDocument.swift Tests/AwesoMuxCoreTests/Markdown/RenderedDocumentFoldingTests.swift` then `git diff --stat`. Report the paths; do not commit.

---

### Task 2: `BranchDiffSectionIndex` (pure, app target)

**Files:**
- Create: `Sources/awesoMux/Views/Markdown/BranchDiffSectionIndex.swift`
- Test: `Tests/awesoMuxTests/BranchDiffSectionIndexTests.swift` (create)

**Interfaces:**
- Produces:

```swift
struct BranchDiffSectionIndex: Equatable {
    struct HunkHeader: Equatable {   // a struct, not a tuple: Optional<tuple> has no `==`
        let oldStart: Int, oldLength: Int, newStart: Int, newLength: Int
    }
    struct Hunk: Equatable {
        let runIndex: Int              // the .diffLine(.hunk) run
        let header: HunkHeader?        // nil when the header does not parse
        // ponytail: no per-line numbering yet. A gutter (spec §6) can derive
        // every line's old/new number from `header` plus the same walk that
        // counts lines here; storing tens of thousands of pairs per tab for a
        // feature that does not exist is memory spent on nothing.
    }
    struct Section: Equatable {
        let key: String                // opaque identity, never displayed
        let title: String              // the full heading text, for the sticky header and VoiceOver
        let headingRuns: Range<Int>    // consecutive .heading(level: 2) runs
        /// Runs a fold removes: the heading's own trailing block separator,
        /// then the fence (diff lines, their "\n" separators, an overflow
        /// `.code` run). NOT the "\n\n" after the fence, so whatever follows
        /// the fence (the next heading, or the closing truncation notice)
        /// keeps exactly one separator from the heading. Empty for a heading
        /// with no fence (a pure rename or mode-only change).
        let bodyRuns: Range<Int>
        let added: Int
        let removed: Int
        let hunks: [Hunk]
        var isFoldable: Bool { !bodyRuns.isEmpty }
    }
    let sections: [Section]
    init(document: RenderedDocument)
    var keys: [String] { sections.map(\.key) }
    func section(key: String) -> Section?
    /// The identity text of a heading: its non-italic runs joined, with a
    /// trailing " — " trimmed. That is the path without the localized status
    /// suffix (`— _new file_`, `— _renamed from x_`), so a fold survives the
    /// file being committed (suffix disappears) or the language changing.
    static func keyText(headingRuns: ArraySlice<RenderedRun>) -> String
    static func key(keyText: String, occurrence: Int) -> String   // occurrence 0 => text; n>0 => text + "\n" + String(n+1). A newline can never appear in heading text (the renderer strips them), so a literal path like `foo#2` cannot collide with an ordinal.
    static func parseHunkHeader(_ line: String) -> HunkHeader?
}
```

A section is EVERY level-2 heading (the renderer emits one per file, including fence-less ones for pure renames); qualification is not "followed by a diff fence" any more. The H1 is level 1 and never matches. Ordinary Markdown never reaches this index because the view only builds it on branch-changes tabs.

Occurrence counting covers every level-2 heading in document order, keyed by `keyText`, and the attributed-string builder (Task 4) counts the same way on the folded document, so the two can never disagree on an ordinal.

Overflow: `AttributedMarkdownBuilder.maximumDiffFenceLines` (20 000) turns the rest of a longer fence into ONE `.code` run. The index counts added/removed lines inside that run too, by splitting its text on newlines and classifying each with `DiffLineKind(line:)`, so the badge stays right on a huge file. Hunks stop at the overflow boundary; say so in a comment.

- [ ] **Step 1: Write the failing tests**

```swift
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Branch diff section index")
struct BranchDiffSectionIndexTests {
    private func build(_ md: String) -> (RenderedDocument, BranchDiffSectionIndex) {
        let doc = AttributedMarkdownBuilder.build(md)
        return (doc, BranchDiffSectionIndex(document: doc))
    }

    @Test("one section per H2 heading; the H1 is skipped; a fence-less heading is a section with no body")
    func sectionsFollowHeadings() {
        let (doc, index) = build("""
        # branch

        Compared with main.

        ## a.swift

        ```diff
        @@ -1,2 +1,3 @@
         ctx
        +new
        -old
        ```

        ## notes

        Just prose.

        ## b.swift — _new file_

        ```diff
        @@ -0,0 +1,2 @@
        +x
        +y
        ```
        """)
        #expect(index.keys == ["a.swift", "notes", "b.swift"])
        #expect(index.sections.map(\.title) == ["a.swift", "notes", "b.swift — new file"])
        let a = index.sections[0]
        #expect(a.added == 1 && a.removed == 1)
        #expect(doc.runs[a.headingRuns].allSatisfy { $0.style == .heading(level: 2) })
        #expect(doc.runs[a.bodyRuns].contains { $0.style == .diffLine(.added) })
        #expect(!doc.runs[a.bodyRuns].contains { $0.style == .heading(level: 2) })
        // The fold starts at the heading's own separator and stops before the "\n\n" after the fence.
        #expect(a.bodyRuns.lowerBound == a.headingRuns.upperBound)
        #expect(doc.runs[a.bodyRuns.upperBound].style == .blockSeparator)
        let notes = index.sections[1]
        #expect(!notes.isFoldable && notes.added == 0)
        let b = index.sections[2]
        #expect(b.added == 2 && b.removed == 0)
        #expect(b.bodyRuns.upperBound == doc.runs.count)
    }

    @Test("a pure rename renders a heading with no fence and is a section with no body, from the real renderer")
    func renameOnlySection() throws {
        let diff = "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\ndiff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let markdown = BranchChangesRenderer.render(diff: diff, identity: <the fixture identity BranchChangesRendererTests uses>, chrome: <its chrome fixture>, budgetBytes: 100_000)
        let (_, index) = build(markdown)
        #expect(index.sections.count == 2)
        #expect(index.sections[0].title.hasPrefix("new.txt"))
        #expect(!index.sections[0].isFoldable)
        #expect(index.sections[1].isFoldable && index.sections[1].added == 1)
    }

    @Test("the closing truncation notice is outside the last section's body, so folding the last file keeps it visible")
    func truncationNoticeSurvivesFold() throws {
        let diff = (0..<2).map { "diff --git a/f\($0).txt b/f\($0).txt\n--- a/f\($0).txt\n+++ b/f\($0).txt\n@@ -1 +1 @@\n-old\n+" + String(repeating: "x", count: 300) + "\n" }.joined()
        let markdown = BranchChangesRenderer.render(diff: diff, identity: <fixture>, chrome: <fixture>, budgetBytes: 450)
        #expect(markdown.contains("This diff is incomplete."))
        let (doc, index) = build(markdown)
        let last = try #require(index.sections.last)
        #expect(last.bodyRuns.upperBound < doc.runs.count)
        let folded = doc.folding(removingRunRanges: [last.bodyRuns])
        #expect(folded.runs.map(\.text).joined().contains("This diff is incomplete."))
    }

    @Test("the key is the path without the status suffix, so it survives the suffix disappearing")
    func keyIgnoresStatusSuffix() {
        let (_, before) = build("## a.swift — _new file_\n\n```diff\n+x\n```\n")
        let (_, after) = build("## a.swift\n\n```diff\n+x\n```\n")
        #expect(before.keys == ["a.swift"] && after.keys == ["a.swift"])
        #expect(before.sections[0].title == "a.swift — new file")
    }

    @Test("duplicate heading text gets an ordinal key so one fold never toggles two sections; titles stay plain")
    func duplicateKeys() {
        let (_, index) = build("## same\n\n```diff\n+a\n```\n\n## same\n\n```diff\n+b\n```\n")
        #expect(index.keys == ["same", "same\n2"])
        #expect(index.sections.map(\.title) == ["same", "same"])
        #expect(BranchDiffSectionIndex.key(keyText: "same", occurrence: 1) == "same\n2")
    }

    @Test("a literal #2 in a path is not an ordinal")
    func literalHashIsSafe() {
        let (_, index) = build("## x\n\n```diff\n+a\n```\n\n## x\n\n```diff\n+a\n```\n\n## x#2\n\n```diff\n+b\n```\n")
        #expect(index.keys == ["x", "x\n2", "x#2"])
    }

    @Test("added and removed lines past the 20 000-line fence cap are still counted")
    func overflowLinesAreCounted() {
        let cap = AttributedMarkdownBuilder.maximumDiffFenceLines
        let body = (0..<(cap + 5)).map { "+\($0)" }.joined(separator: "\n")
        let (doc, index) = build("## big\n\n```diff\n\(body)\n```\n")
        #expect(doc.runs.contains { $0.style == .code })          // the overflow run exists
        #expect(index.sections[0].added == cap + 5)
        #expect(index.sections[0].removed == 0)
    }

    @Test("hunk headers parse, including -0,0 and a missing length")
    func hunkHeaderParsing() {
        typealias H = BranchDiffSectionIndex.HunkHeader
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -344,10 +345,29 @@ func x") == H(oldStart: 344, oldLength: 10, newStart: 345, newLength: 29))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -0,0 +1,5 @@") == H(oldStart: 0, oldLength: 0, newStart: 1, newLength: 5))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -7 +7 @@") == H(oldStart: 7, oldLength: 1, newStart: 7, newLength: 1))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ garbage @@") == nil)
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@@ -1,2 -3,4 +5,6 @@@") == nil)
    }

    @Test("an unparsable hunk header yields a nil header and still counts its lines; hunks are recorded in order")
    func unparsableHunkStillCounts() {
        let (_, index) = build("## f\n\n```diff\n@@ nope @@\n+a\n-b\n@@ -50,1 +60,1 @@\n b\n```\n")
        let section = index.sections[0]
        #expect(section.added == 1 && section.removed == 1)
        #expect(section.hunks.count == 2)
        #expect(section.hunks[0].header == nil)
        #expect(section.hunks[1].header?.oldStart == 50 && section.hunks[1].header?.newStart == 60)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter BranchDiffSectionIndexTests`
Expected: compile error, type undefined.

- [ ] **Step 3: Implement**

`Sources/awesoMux/Views/Markdown/BranchDiffSectionIndex.swift`:

```swift
import AwesoMuxCore
import Foundation

/// Per-file sections of a rendered branch-changes document, derived from the
/// runs the Markdown builder already emits. Pure and AppKit-free so it can be
/// tested without a text view. Built once per render on branch-changes tabs.
struct BranchDiffSectionIndex: Equatable {
    struct HunkHeader: Equatable {
        let oldStart: Int
        let oldLength: Int
        let newStart: Int
        let newLength: Int
    }

    struct Hunk: Equatable {
        let runIndex: Int
        let header: HunkHeader?
    }

    struct Section: Equatable {
        let key: String
        let title: String
        let headingRuns: Range<Int>
        let bodyRuns: Range<Int>
        let added: Int
        let removed: Int
        let hunks: [Hunk]
        var isFoldable: Bool { !bodyRuns.isEmpty }
    }

    let sections: [Section]

    var keys: [String] { sections.map(\.key) }

    func section(key: String) -> Section? { sections.first { $0.key == key } }

    /// The path half of `path — _status_`: non-italic runs joined, trailing
    /// " — " trimmed. Stable across the status suffix changing or vanishing.
    static func keyText(headingRuns: ArraySlice<RenderedRun>) -> String {
        var text = headingRuns.filter { !$0.italic }.map(\.text).joined()
        if text.hasSuffix(" — ") { text.removeLast(3) }
        return text
    }

    /// The second and later headings with identical key text get an ordinal.
    /// "\n" separates it because the renderer strips newlines from headings,
    /// so no real path can collide with an ordinal-bearing key.
    static func key(keyText: String, occurrence: Int) -> String {
        occurrence == 0 ? keyText : keyText + "\n" + String(occurrence + 1)
    }

    init(document: RenderedDocument) {
        let runs = document.runs
        var headings: [(start: Int, end: Int)] = []
        var i = 0
        while i < runs.count {
            guard case .heading(level: 2) = runs[i].style else { i += 1; continue }
            var end = i
            while end < runs.count, case .heading(level: 2) = runs[end].style { end += 1 }
            headings.append((i, end))
            i = end
        }
        var sections: [Section] = []
        var occurrences: [String: Int] = [:]
        for heading in headings {
            let slice = runs[heading.start..<heading.end]
            let keyText = Self.keyText(headingRuns: slice)
            let occurrence = occurrences[keyText, default: 0]
            occurrences[keyText] = occurrence + 1
            let title = slice.map(\.text).joined()
            // The fence, if any, starts after the heading's own block separator.
            var fenceStart = heading.end
            if fenceStart < runs.count, runs[fenceStart].style == .blockSeparator { fenceStart += 1 }
            var fenceEnd = fenceStart
            var added = 0, removed = 0
            var hunks: [Hunk] = []
            if fenceStart < runs.count, case .diffLine = runs[fenceStart].style {
                scan: while fenceEnd < runs.count {
                    let run = runs[fenceEnd]
                    switch run.style {
                    case .diffLine(let kind):
                        switch kind {
                        case .added: added += 1
                        case .removed: removed += 1
                        case .hunk: hunks.append(Hunk(runIndex: fenceEnd, header: Self.parseHunkHeader(run.text)))
                        case .meta, .context: break
                        }
                    case .code:
                        // Past AttributedMarkdownBuilder.maximumDiffFenceLines the
                        // fence tail is one run; count it so the badge stays honest.
                        // No hunks here: the run has no per-line geometry.
                        for line in run.text.split(separator: "\n", omittingEmptySubsequences: false) {
                            switch DiffLineKind(line: line) {
                            case .added: added += 1
                            case .removed: removed += 1
                            default: break
                            }
                        }
                    case .blockSeparator where run.text == "\n":
                        break   // a line break inside the fence
                    default:
                        break scan   // the "\n\n" after the fence, or the next block
                    }
                    fenceEnd += 1
                }
            }
            // A fold removes the heading's separator plus the fence, and keeps
            // the "\n\n" after the fence for whatever follows. A fence-less
            // heading has an empty range and is not foldable.
            let bodyRuns = fenceEnd > fenceStart ? heading.end..<fenceEnd : heading.end..<heading.end
            sections.append(Section(
                key: Self.key(keyText: keyText, occurrence: occurrence),
                title: title,
                headingRuns: heading.start..<heading.end,
                bodyRuns: bodyRuns,
                added: added, removed: removed, hunks: hunks))
        }
        self.sections = sections
    }

    /// `@@ -a[,b] +c[,d] @@…`; a missing length means 1. Combined-diff
    /// headers (`@@@`) and anything else return nil.
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        guard line.hasPrefix("@@ "), !line.hasPrefix("@@@") else { return nil }
        let parts = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
            let old = range(parts[0].dropFirst()), let new = range(parts[1].dropFirst())
        else { return nil }
        return HunkHeader(oldStart: old.start, oldLength: old.length, newStart: new.start, newLength: new.length)
    }

    private static func range(_ text: Substring) -> (start: Int, length: Int)? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2, let start = Int(pieces[0]) else { return nil }
        if pieces.count == 1 { return (start, 1) }
        guard let length = Int(pieces[1]) else { return nil }
        return (start, length)
    }
}
```

Check `RenderedRun.italic` is what the heading's status run carries (the Core builder forwards `Emphasis` inside a heading as `.heading(level: 2)` with `italic: true`; confirm at `AttributedMarkdownBuilder.swift` ~line 327 and in the `## path — _status_` fixture). For the two tests that call `BranchChangesRenderer.render`, take the `identity`/`chrome` fixtures from `Tests/AwesoMuxCoreTests/BranchChangesRendererTests.swift` (copy the two helpers; do not invent new ones).

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter BranchDiffSectionIndexTests`
Expected: 10 tests pass (`HunkHeader` is an `Equatable` struct; an optional tuple would not compare with `==`).

- [ ] **Step 5: Format and hand off**

Run: `./script/format.sh Sources/awesoMux/Views/Markdown/BranchDiffSectionIndex.swift Tests/awesoMuxTests/BranchDiffSectionIndexTests.swift`. Do not commit.

---

### Task 3: Collapsed keys and section index in `DocumentTabMemory`

**Files:**
- Modify: `Sources/awesoMux/Views/DocumentTabMemory.swift`
- Modify: `Sources/awesoMux/Views/DocumentPaneView.swift:1342` (the `DocumentTabMemory.Render(...)` construction)
- Test: `Tests/awesoMuxTests/DocumentTabMemoryTests.swift`

**Interfaces:**
- Consumes: `BranchDiffSectionIndex(document:)` (Task 2).
- Produces:
  - `DocumentTabMemory.Render.init(loadResult:renderedDoc:sectionIndex: BranchDiffSectionIndex? = nil)` and `var sectionIndex: BranchDiffSectionIndex?`.
  - `func collapsedSections(for tab: DocumentPane) -> Set<String>`
  - `mutating func setCollapsedSections(_ keys: Set<String>, for tab: DocumentPane)`
  - `mutating func toggleSection(_ key: String, for tab: DocumentPane)`
  - `func sectionIndex(for tab: DocumentPane) -> BranchDiffSectionIndex?` (reads the stored render's index)

- [ ] **Step 1: Write the failing tests** (append to `DocumentTabMemoryTests`)

```swift
    @Test func collapsedSectionsToggleAndReadBackForTheSamePath() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/c.md")
        #expect(memory.collapsedSections(for: tab).isEmpty)
        memory.toggleSection("a.swift", for: tab)
        memory.toggleSection("b.swift", for: tab)
        memory.toggleSection("a.swift", for: tab)
        #expect(memory.collapsedSections(for: tab) == ["b.swift"])
        memory.setCollapsedSections(["x", "y"], for: tab)
        #expect(memory.collapsedSections(for: tab) == ["x", "y"])
    }

    @Test func collapsedSectionsDropWhenTheTabShowsAnotherFile() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/d.md")
        memory.toggleSection("a.swift", for: tab)
        var moved = tab
        moved.fileURL = URL(fileURLWithPath: "/tmp/other.md")
        #expect(memory.collapsedSections(for: moved).isEmpty)
        memory.prune(keeping: [moved])
        #expect(memory.collapsedSections(for: tab).isEmpty)
    }

    @Test func collapsedSectionsSurviveARenderStoreForTheSamePath() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/e.md")
        memory.toggleSection("a.swift", for: tab)
        memory.storeRender(makeRender(source: "refreshed"), for: tab)
        #expect(memory.collapsedSections(for: tab) == ["a.swift"])
    }

    @Test func collapsedKeysKeyedByPathSurviveAStatusSuffixChange() {
        // Keyed on the path only (BranchDiffSectionIndex.keyText), so the fold set
        // stored while the file was `— new file` still applies after a commit.
        let before = BranchDiffSectionIndex(document: AttributedMarkdownBuilder.build("## a.swift — _new file_\n\n```diff\n+x\n```\n"))
        let after = BranchDiffSectionIndex(document: AttributedMarkdownBuilder.build("## a.swift\n\n```diff\n+x\n```\n"))
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/g.md")
        memory.toggleSection(before.keys[0], for: tab)
        #expect(memory.collapsedSections(for: tab).contains(after.keys[0]))
    }

    @Test func renderCarriesTheSectionIndexItWasGiven() {
        let doc = AttributedMarkdownBuilder.build("## f\n\n```diff\n+a\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        let render = DocumentTabMemory.Render(loadResult: .loaded(source: doc.source, snapshot: nil), renderedDoc: doc, sectionIndex: index)
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/f.md")
        memory.storeRender(render, for: tab)
        #expect(memory.sectionIndex(for: tab)?.keys == ["f"])
    }
```

If `DocumentPane.fileURL` is not settable from the test, construct a second `DocumentPane` with the same `id` instead (check the initializer at `Sources/AwesoMuxCore/Models/DocumentPane.swift:70-95`; it accepts `id:`).

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter DocumentTabMemoryTests`
Expected: compile errors for the new API.

- [ ] **Step 3: Implement**

In `DocumentTabMemory.swift`:
- Add `let sectionIndex: BranchDiffSectionIndex?` to `Render`; extend its init with `sectionIndex: BranchDiffSectionIndex? = nil` and store it.
- Add `var collapsedSections: Set<String> = []` to `Entry`.
- Add:

```swift
    func collapsedSections(for tab: DocumentPane) -> Set<String> {
        entry(for: tab)?.collapsedSections ?? []
    }

    func sectionIndex(for tab: DocumentPane) -> BranchDiffSectionIndex? {
        entry(for: tab)?.render?.sectionIndex
    }

    mutating func setCollapsedSections(_ keys: Set<String>, for tab: DocumentPane) {
        var entry = matchingOrFresh(for: tab)
        entry.collapsedSections = keys
        entries[tab.id] = entry
    }

    mutating func toggleSection(_ key: String, for tab: DocumentPane) {
        var keys = collapsedSections(for: tab)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        setCollapsedSections(keys, for: tab)
    }
```

Update the doc comment at the top of the file: the memory now also holds the fold state per tab (session-only, never persisted, same path pin).

In `DocumentPaneView.swift` at the `Render(...)` construction (line 1342), compute the index only for branch-changes tabs and hand it over:

```swift
// `doc` is `RenderedDocument?` here (a rejected or unreadable file has none).
let sectionIndex = pane.generatedDocumentKind == .branchChanges ? doc.map(BranchDiffSectionIndex.init(document:)) : nil
localSectionIndex = sectionIndex     // @State, declared in Task 6; nil on failures so a stale index never outlives its document
onRenderCompleted?(DocumentTabMemory.Render(loadResult: result, renderedDoc: doc, sectionIndex: sectionIndex))
```

Declare `@State private var localSectionIndex: BranchDiffSectionIndex?` on `DocumentPaneView` in this task (Task 6 wires it), seeded in `init` from `cachedRender?.sectionIndex` the same way the cached render seeds `renderedDoc`.

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter DocumentTabMemoryTests`
Expected: all existing plus 4 new tests pass.

- [ ] **Step 5: Format and hand off**

Run `./script/format.sh` on the two Swift files changed. Do not commit.

---

### Task 4: Builder attributes: section-key on headings, hunk band tint and rule

**Files:**
- Modify: `Sources/awesoMux/Views/Markdown/MarkdownAttributedStringBuilder.swift` (`attributedString(for:…)` ~line 91-135, `DiffPalette.tint` ~line 491, statics ~line 525)
- Test: `Tests/awesoMuxTests/MarkdownDiffLineStylingTests.swift`

**Interfaces:**
- Consumes: `BranchDiffSectionIndex` (Task 2), `.keyText(headingRuns:)` and `.key(keyText:occurrence:)`.
- Produces:
  - `NSAttributedString.Key.diffSectionKey` (`"awesomux.diffSectionKey"`, value `NSString`), stamped on every run of a section heading.
  - `NSAttributedString.Key.diffHunkRule` (`"awesomux.diffHunkRule"`, value `NSNumber(true)`), stamped on `.diffLine(.hunk)` runs.
  - `.diffLineTint` is now also stamped on hunk runs with `DiffPalette.hunk`.
  - `attributedString(for:textColor:terminalBackground:relativeLinkBaseURL:allowsDocumentLinks:sectionIndex: BranchDiffSectionIndex? = nil)`.
  - `static let sectionHeadingGutter: CGFloat = 18` (points reserved at the leading edge of section headings for the chevron) and `static func sectionHeadingFont() -> NSFont` (the H2 font, for the sticky header).

- [ ] **Step 1: Write the failing tests** (append to `MarkdownDiffLineStylingTests`)

```swift
    @Test("hunk rows carry the blue tint and a rule marker; context rows carry neither")
    func hunkRowsAreBanded() throws {
        let doc = AttributedMarkdownBuilder.build("```diff\n@@ -1,2 +1,2 @@\n ctx\n```\n")
        let hunk = attributes(ofLine: "@@ -1,2", in: doc)
        #expect(hunk[.diffLineTint] is NSColor)
        #expect((hunk[.diffHunkRule] as? NSNumber)?.boolValue == true)
        #expect(attributes(ofLine: " ctx", in: doc)[.diffHunkRule] == nil)
        // The hunk tint is distinct from added/removed.
        let doc2 = AttributedMarkdownBuilder.build("```diff\n@@ -1 +1 @@\n+a\n-b\n```\n")
        let h = try #require(attributes(ofLine: "@@", in: doc2)[.diffLineTint] as? NSColor)
        let a = try #require(attributes(ofLine: "+a", in: doc2)[.diffLineTint] as? NSColor)
        let r = try #require(attributes(ofLine: "-b", in: doc2)[.diffLineTint] as? NSColor)
        #expect(h != a && h != r)
    }

    @Test("section headings are keyed and indented when an index is supplied; without one they are untouched")
    func sectionHeadingsAreKeyed() throws {
        let doc = AttributedMarkdownBuilder.build("## a.swift — _new file_\n\n```diff\n+x\n```\n\n## a.swift — _new file_\n\n```diff\n+y\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        let attributed = MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: .white, sectionIndex: index)
        let ns = attributed.string as NSString
        let first = ns.range(of: "a.swift")
        let second = ns.range(of: "a.swift", options: [], range: NSRange(location: first.location + 1, length: ns.length - first.location - 1))
        #expect(attributed.attribute(.diffSectionKey, at: first.location, effectiveRange: nil) as? String == "a.swift")
        #expect(attributed.attribute(.diffSectionKey, at: second.location, effectiveRange: nil) as? String == "a.swift\n2")
        // The italic status run is part of the same heading and carries the same key.
        let status = ns.range(of: "new file")
        #expect(attributed.attribute(.diffSectionKey, at: status.location, effectiveRange: nil) as? String == "a.swift")
        let style = try #require(attributed.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == MarkdownAttributedStringBuilder.sectionHeadingGutter)
        #expect(style.headIndent == MarkdownAttributedStringBuilder.sectionHeadingGutter)
        let plain = MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: .white)
        #expect(plain.attribute(.diffSectionKey, at: first.location, effectiveRange: nil) == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter MarkdownDiffLineStylingTests`
Expected: compile errors for `.diffHunkRule`, `sectionIndex:`, `sectionHeadingGutter`.

- [ ] **Step 3: Implement**

In `MarkdownAttributedStringBuilder.swift`:

Add the keys next to `diffLineTint` (line 21):
```swift
    /// Present on every run of a branch-changes file heading; value is the
    /// section key from `BranchDiffSectionIndex`. The overlay draws the chevron
    /// and counts at this range and toggles the fold on click.
    static let diffSectionKey = NSAttributedString.Key("awesomux.diffSectionKey")
    /// Present on hunk-header runs; the overlay draws a hairline above the row.
    static let diffHunkRule = NSAttributedString.Key("awesomux.diffHunkRule")
    /// Leading space reserved on section headings for the fold chevron.
    static let sectionHeadingGutter: CGFloat = 18
    /// Trailing space reserved on section headings so a long path wraps before
    /// the counts badge instead of running under it. Wide enough for
    /// "+99999 −99999" in the badge font plus padding.
    static let sectionHeadingTrailingReserve: CGFloat = 104
```

Add `sectionIndex: BranchDiffSectionIndex? = nil` as the last parameter of `attributedString(for:…)`. The index was built on the UNFOLDED document while `doc` may be folded (Task 6), so its run indices cannot be used here. Derive keys by walking `doc.runs` the same way the index does: group consecutive `.heading(level: 2)` runs, take `BranchDiffSectionIndex.keyText(headingRuns:)`, count occurrences of that key text over every H2, and form `BranchDiffSectionIndex.key(keyText:occurrence:)`; stamp it only when `sectionIndex.section(key:) != nil` (which is every H2 on a branch-changes document). Folding never removes headings, so occurrence ordinals match the index. Implement as:

```swift
    /// Heading run index → section key, for the runs of `doc` (which may be a
    /// folded copy of the document the index was built on).
    private static func sectionKeysByRun(in doc: RenderedDocument, index: BranchDiffSectionIndex) -> [Int: String] {
        var out: [Int: String] = [:]
        var occurrences: [String: Int] = [:]
        var i = 0
        while i < doc.runs.count {
            guard case .heading(level: 2) = doc.runs[i].style else { i += 1; continue }
            var end = i
            while end < doc.runs.count, case .heading(level: 2) = doc.runs[end].style { end += 1 }
            let text = BranchDiffSectionIndex.keyText(headingRuns: doc.runs[i..<end])
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            let key = BranchDiffSectionIndex.key(keyText: text, occurrence: occurrence)
            if index.section(key: key) != nil {
                for r in i..<end { out[r] = key }
            }
            i = end
        }
        return out
    }
```

Before the run loop: `let keyForRun = sectionIndex.map { sectionKeysByRun(in: doc, index: $0) } ?? [:]`.

Inside the run loop, after the `.font` attribute:
```swift
            if let key = keyForRun[runIndex] {
                result.addAttribute(.diffSectionKey, value: key as NSString, range: range)
                result.addAttribute(.paragraphStyle, value: sectionHeadingParagraphStyle, range: range)
            }
            if case .diffLine(.hunk) = run.style {
                result.addAttribute(.diffHunkRule, value: NSNumber(value: true), range: range)
            }
```
(The loop is `for run in doc.runs`; change it to `for (runIndex, run) in doc.runs.enumerated()`.)

In `DiffPalette.tint(_:)` return `hunk` for `.hunk` (keep `nil` for `.meta`/`.context`). Check `diffTintRows` merging still splits hunk from added rows (different colors), which it does.

Add the statics:
```swift
    nonisolated(unsafe) private static let sectionHeadingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = sectionHeadingGutter
        style.headIndent = sectionHeadingGutter
        return style.copy() as! NSParagraphStyle
    }()

    static func sectionHeadingFont() -> NSFont { headingFont(level: 2, italic: false) }
```

Check whether headings already receive a paragraph style elsewhere in this builder (grep `paragraphStyle` in the file: line 358 is tables only). If `applyProseWrapWidth` in `MarkdownTextView` rewrites paragraph styles for tailIndent, it must preserve `firstLineHeadIndent`/`headIndent` (read `MarkdownTextViewCoordinator.updateDocumentGeometry` ~line 635-740 and confirm it mutates a copy of the existing style rather than replacing it; if it replaces, copy the two indents across).

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter MarkdownDiffLineStylingTests`
Expected: all previous tests plus 2 new pass.

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on both files. Do not commit.

---

### Task 5: Overlay chrome: hunk hairline, chevrons, counts, heading-row hit test, accessibility

**Files:**
- Modify: `Sources/awesoMux/Views/Markdown/CommentBadgeOverlay.swift`
- Test: `Tests/awesoMuxTests/MarkdownDiffLineStylingTests.swift` (overlay section) or a new `Tests/awesoMuxTests/BranchDiffOverlayChromeTests.swift`

**Interfaces:**
- Consumes: `.diffSectionKey`, `.diffHunkRule`, `.diffLineTint` (Task 4); `BranchDiffSectionIndex.Section` counts (Task 2).
- Produces on `CommentBadgeOverlay`:

```swift
    struct SectionChrome: Equatable {
        let key: String
        let title: String            // display text; from `sectionTitles[key]`
        let headingRect: NSRect      // overlay space, full heading line fragment(s)
        let rowRect: NSRect          // full-width click target for the heading's first line
        let collapsed: Bool
        let added: Int
        let removed: Int
    }
    /// Inputs for the section chrome. Set before `updateBadges`; nil disables it.
    var sectionCounts: [String: (added: Int, removed: Int)]? = nil
    var sectionTitles: [String: String] = [:]
    var collapsedSections: Set<String> = []
    var onSectionToggled: ((String) -> Void)? = nil
    /// Tint hues for the counts; set from the builder's DiffPalette by MarkdownTextView.
    var addedCountColor: NSColor = .systemGreen
    var removedCountColor: NSColor = .systemRed
    var hunkRuleColor: NSColor? = nil
    private(set) var sectionChrome: [SectionChrome] = []
    static func sectionAccessibilityLabel(key: String, added: Int, removed: Int) -> String
    static func countsBadgeText(added: Int, removed: Int) -> String   // "+38 −2" (U+2212 minus)
```

- [ ] **Step 0: Falsify the cost model before writing geometry code**

`CommentBadgeOverlay.swift` ~line 717 says, for row tints, that resolving every row's geometry on every relayout "would force full-document layout on every frame of a pane drag". Section chrome resolves one rect per heading and the plan calls it from `layout()`. Measure before building on it: in the test file below, add a test that builds a document with 200 sections (`(0..<200).map { "## f\($0).swift\n\n```diff\n+a\n-b\n```\n" }.joined()`), runs `overlay.updateBadges(attr:textView:)` once to warm layout, then measures a second call with `ContinuousClock().measure { … }` and asserts it is under 16 ms (`#expect(elapsed < .milliseconds(16))`). If it fails: do NOT call `updateSectionChrome` from `layout()`; instead resolve heading Ys once inside `MarkdownTextViewCoordinator.updateDocumentGeometry` (which already forces full layout when the wrap width moves) behind a layout-generation counter and have the overlay read that cache. Record the measured number in the task's hand-off either way.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Branch diff overlay chrome")
struct BranchDiffOverlayChromeTests {
    @MainActor
    private func makeOverlay(_ source: String, collapsed: Set<String> = []) -> (CommentBadgeOverlay, NSTextView, NSAttributedString, BranchDiffSectionIndex) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let doc = AttributedMarkdownBuilder.build(source)
        let index = BranchDiffSectionIndex(document: doc)
        let attr = MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: .white, sectionIndex: index)
        textView.textStorage?.setAttributedString(attr)
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.sectionCounts = Dictionary(uniqueKeysWithValues: index.sections.map { ($0.key, ($0.added, $0.removed)) })
        overlay.sectionTitles = Dictionary(uniqueKeysWithValues: index.sections.map { ($0.key, $0.title) })
        overlay.collapsedSections = collapsed
        // Cached remounts render with annotations non-interactive (no snapshot);
        // folding must not depend on that gate.
        overlay.annotationsInteractive = false
        overlay.updateBadges(attr: attr, textView: textView)
        return (overlay, textView, attr, index)
    }

    private let twoFiles = "## a.swift\n\n```diff\n@@ -1 +1 @@\n+x\n-y\n```\n\n## b.swift\n\n```diff\n+z\n```\n"

    @Test("one chrome entry per section, in document order, with counts and fold state") @MainActor
    func chromePerSection() {
        let (overlay, _, _, _) = makeOverlay(twoFiles, collapsed: ["b.swift"])
        #expect(overlay.sectionChrome.map(\.key) == ["a.swift", "b.swift"])
        #expect(overlay.sectionChrome[0].added == 1 && overlay.sectionChrome[0].removed == 1)
        #expect(overlay.sectionChrome[0].collapsed == false)
        #expect(overlay.sectionChrome[1].collapsed == true)
        #expect(overlay.sectionChrome[0].rowRect.minY < overlay.sectionChrome[1].rowRect.minY)
        #expect(overlay.sectionChrome.allSatisfy { $0.rowRect.minX == 0 && $0.rowRect.width == 400 })
    }

    @Test("the heading row hit-tests to the overlay and a click toggles that key; body rows pass through") @MainActor
    func headingRowClickToggles() {
        let (overlay, textView, _, _) = makeOverlay(twoFiles)
        var toggled: [String] = []
        overlay.onSectionToggled = { toggled.append($0) }
        let row = overlay.sectionChrome[1].rowRect
        let inside = NSPoint(x: row.midX, y: row.midY)
        #expect(overlay.hitTest(textView.convert(inside, from: overlay)) === overlay)
        overlay.simulateClick(at: inside)
        #expect(toggled == ["b.swift"])
        let between = NSPoint(x: 10, y: overlay.sectionChrome[0].rowRect.maxY + 30)
        #expect(overlay.hitTest(textView.convert(between, from: overlay)) == nil)
    }

    @Test("counts badge text uses a real minus and always shows both numbers")
    func badgeText() {
        #expect(CommentBadgeOverlay.countsBadgeText(added: 38, removed: 2) == "+38 \u{2212}2")
        #expect(CommentBadgeOverlay.countsBadgeText(added: 0, removed: 0) == "+0 \u{2212}0")
    }

    @Test("accessibility children include one enabled button per section with label and value, even with annotations off") @MainActor
    func accessibilityButtons() throws {
        let (overlay, _, _, _) = makeOverlay(twoFiles, collapsed: ["a.swift"])
        let elements = overlay.sectionAccessibilityChildrenForTesting()
        #expect(elements.count == 2)
        #expect(elements[0].accessibilityLabel() == "a.swift, 1 added, 1 removed")
        #expect(elements[0].accessibilityValue() as? String == "collapsed")
        #expect(elements[1].accessibilityValue() as? String == "expanded")
        #expect(elements[0].accessibilityRole() == .button)
        #expect(elements[0].isAccessibilityEnabled())
        var pressed: String?
        overlay.onSectionToggled = { pressed = $0 }
        _ = elements[1].accessibilityPerformPress()
        #expect(pressed == "b.swift")
    }

    @Test("hunk rows report a rule rect at the row top") @MainActor
    func hunkRule() {
        let (overlay, textView, _, _) = makeOverlay(twoFiles)
        let rules = CommentBadgeOverlay.diffHunkRuleRows(intersecting: NSRect(x: 0, y: 0, width: 400, height: 4000), in: textView, width: 400)
        #expect(rules.count == 1)
        #expect(rules[0].height == 1 && rules[0].width == 400)
        let tints = CommentBadgeOverlay.diffTintRows(intersecting: NSRect(x: 0, y: 0, width: 400, height: 4000), in: textView, width: 400)
        #expect(tints.contains { abs($0.rect.minY - rules[0].minY) < 0.5 })
    }
}
```

Add to the overlay, `#if DEBUG`-free (tests link `@testable`), two test seams: `func simulateClick(at point: NSPoint)` that runs the same dispatch as `mouseDown` for a point in overlay space, and `func sectionAccessibilityChildrenForTesting() -> [NSAccessibilityElement]` returning `sectionAccessibilityChildren()`.

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter BranchDiffOverlayChromeTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

In `CommentBadgeOverlay.swift`:

1. Model + properties (after `tableCellInfos`): the `SectionChrome` struct, `sectionCounts`, `collapsedSections`, `onSectionToggled`, `addedCountColor`, `removedCountColor`, `hunkRuleColor`, `private(set) var sectionChrome: [SectionChrome] = []`, plus `private var sectionAttr: NSAttributedString?` / `private weak var sectionTextView: NSTextView?` mirroring the border cache.

2. Geometry: `private func updateSectionChrome(attr: NSAttributedString, textView: NSTextView)`:
```swift
        var out: [SectionChrome] = []
        guard let counts = sectionCounts else { sectionChrome = []; sectionAttr = nil; sectionTextView = nil; return }
        attr.enumerateAttribute(.diffSectionKey, in: NSRange(location: 0, length: attr.length), options: []) { value, nsRange, _ in
            guard let key = value as? String, nsRange.length > 0,
                let cell = Self.cellRectInTextView(range: nsRange, in: textView) else { return }
            // Consecutive runs of one heading (path + italic status) enumerate
            // as separate ranges when their other attributes differ; merge by key.
            if let last = out.last, last.key == key {
                out[out.count - 1] = SectionChrome(key: key, title: last.title, headingRect: last.headingRect.union(cell.rect), rowRect: last.rowRect, collapsed: last.collapsed, added: last.added, removed: last.removed)
                return
            }
            let count = counts[key] ?? (0, 0)
            let row = NSRect(x: 0, y: cell.rect.minY, width: bounds.width, height: cell.rect.height)
            out.append(SectionChrome(key: key, title: sectionTitles[key] ?? key, headingRect: cell.rect, rowRect: row, collapsed: collapsedSections.contains(key), added: count.added, removed: count.removed))
        }
        sectionChrome = out
        sectionAttr = out.isEmpty ? nil : attr
        sectionTextView = out.isEmpty ? nil : textView
```
Call it from both `updateTableBorders` call sites (line 131 in `layout()` and line 633 in `updateBadges`) right after `updateTableBorders`, and extend the `layout()` fast-path condition so a section-only document (no tables, no pills) still recomputes on resize: add an `else if let attr = sectionAttr, let textView = sectionTextView { updateSectionChrome(attr: attr, textView: textView); needsDisplay = true }` branch. Clear `sectionChrome` on the no-layout-manager guard path in `updateBadges` (where table state is cleared).

`enumerateAttribute` reports the widest effective range for that key regardless of other attributes, so the merge branch is a safety net; keep it.

3. Hit testing: in BOTH `hitTest` and `mouseDown`, check `sectionChrome` `rowRect`s BEFORE the existing `guard annotationsInteractive` line. That guard returns early, and cached remounts (no snapshot) run with annotations non-interactive, so a check placed after the pill loop would be unreachable exactly when a tab is reopened from memory. Folding is not an annotation action and never consults that flag. In `mouseDown`, call `onSectionToggled?(chrome.key)`. Add `override func resetCursorRects()` adding `addCursorRect(chrome.rowRect, cursor: .pointingHand)` for each section, and call `window?.invalidateCursorRects(for: self)` at the end of `updateSectionChrome`.

`simulateClick(at:)` shares the dispatch with `mouseDown` via a private `func dispatchClick(at point: NSPoint)`.

4. Drawing, in `draw(_:)` after the tint loop and before table borders:
```swift
        if let textView = superview as? NSTextView, let ruleColor = hunkRuleColor {
            ruleColor.setFill()
            for rule in Self.diffHunkRuleRows(intersecting: dirtyRect, in: textView, width: bounds.width) { rule.fill() }
        }
        for chrome in sectionChrome where chrome.rowRect.intersects(dirtyRect) {
            drawChevron(for: chrome)
            drawCounts(for: chrome)
        }
```
- `diffHunkRuleRows(intersecting:in:width:) -> [NSRect]`: the same fragment walk as `diffTintRows`, reading `.diffHunkRule`, returning a 1pt-high rect at each hunk row's `minY`. Decision made here, not by the implementer: refactor the walk into ONE private static `diffAttributeRows(_ key: NSAttributedString.Key, intersecting:in:width:) -> [(rect: NSRect, value: Any)]` and have both public functions map over it (tints merge consecutive same-color rows; rules take `minY` with height 1). No generics, no duplication.
- `drawChevron`: `NSImage(systemSymbolName: chrome.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)` with `NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)`, tinted with `tableBorderColor ?? .labelColor` at full alpha, drawn centred vertically in the heading's first line and horizontally in the gutter: x from `textView.textContainerInset.width` to `+ MarkdownAttributedStringBuilder.sectionHeadingGutter`.
- `drawCounts`: `countsBadgeText` split into two runs, `+n` in `addedCountColor`, `−m` in `removedCountColor`, font `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)`, right-aligned so the text ends at `visibleWidth - textView.textContainerInset.width` where `visibleWidth = textView.enclosingScrollView?.contentView.bounds.width ?? bounds.width`. The text view is `max(clip width, widest line)` wide since INT-687, so a document with an unwrapped wide line would otherwise push the badge off the right edge of the pane; diff lines wrap and diff documents have no tables, so the two widths normally agree, but pin to the clip regardless. Row rects (`rowRect`) keep `bounds.width` since they are hit targets, not drawings. vertically centred on `chrome.headingRect`'s first line (use `chrome.headingRect.minY + lineHeight/2` where lineHeight is the heading font's line height, so a wrapped heading keeps the badge on its first line). Draw a rounded rect behind both at `Color.aw`-independent `(tableBorderColor ?? .labelColor).withAlphaComponent(0.08)` with 4pt corner radius and 4pt horizontal padding.

5. Accessibility: `sectionAccessibilityChildren()` builds a `PillAccessibilityElement` per chrome (same class as pills; set role `.button`, `setAccessibilityEnabled(true)` unconditionally (not `annotationsInteractive`), label from `sectionAccessibilityLabel(key: chrome.title, …)` (the title, never the key), `setAccessibilityValue(chrome.collapsed ? "collapsed" : "expanded")`, live `frameProvider` from `rowRect`, `onPress = { onSectionToggled?(key) }`). Append it in `accessibilityChildren()`: `pillAccessibilityChildren() + sectionAccessibilityChildren() + materializedTableElements()`. Localize: the label and values go through `String(localized:)` with `comment:` (three strings: `"\(key), \(added) added, \(removed) removed"`, `"collapsed"`, `"expanded"`). Count-dependent copy: "added"/"removed" here are labels after a number, not pluralized nouns, so no stringsdict is needed; note that in a comment.

6. `countsBadgeText(added:removed:)`: `"+\(added) \u{2212}\(removed)"`.

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter BranchDiffOverlayChromeTests` and `./script/swift-test.sh --filter MarkdownDiffLineStylingTests`
Expected: all pass. If the `hitTest` conversion in the test is off by the inset, convert from `textView` explicitly as written (the overlay's frame equals the text view's bounds, so the conversion is identity; keep it for correctness).

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on the overlay and test file. Do not commit.

---

### Task 6: Fold plumbing through `MarkdownTextView`, `DocumentPaneView`, `DocumentGroupView`

**Files:**
- Modify: `Sources/awesoMux/Views/Markdown/MarkdownTextView.swift` (properties ~104-166, `attributedString(for:)` 174, `updateNSView` 284-480, coordinator ~520-560, scroll helpers ~840-957)
- Modify: `Sources/awesoMux/Views/DocumentPaneView.swift` (`DocumentPaneView` props ~940-1000, `MarkdownTextView(` at ~1404)
- Modify: `Sources/awesoMux/Views/DocumentGroupView.swift` (~205-300)
- Test: `Tests/awesoMuxTests/MarkdownDiffLineStylingTests.swift` (one folded-document builder test) and a GUI smoke in Task 10

**Interfaces:**
- Consumes: `folding(removingRunRanges:)` (Task 1), `BranchDiffSectionIndex` (Task 2), memory API (Task 3), builder `sectionIndex:` (Task 4), overlay properties (Task 5).
- Produces:
  - `MarkdownTextView` new inputs: `var sectionIndex: BranchDiffSectionIndex? = nil`, `var collapsedSections: Set<String> = []`, `var onSectionToggled: ((String) -> Void)? = nil`.
  - `DocumentPaneView` new inputs: `var sectionIndex: BranchDiffSectionIndex? = nil` (from memory, may be nil until the first render completes; the view falls back to computing it from its own `renderedDoc` when `pane.generatedDocumentKind == .branchChanges`), `var collapsedSections: Set<String> = []`, `var onSectionToggled: ((String) -> Void)? = nil`.
  - Coordinator: `var lastCollapsedSections: Set<String> = []`, `var pendingSectionReanchor: (key: String, offsetFromTop: CGFloat)?`, `func handleSectionToggle(_ key: String)`, `func reanchorAfterFold()`.

- [ ] **Step 1: Write the failing test** (append to `MarkdownDiffLineStylingTests`)

```swift
    @Test("folding removes exactly the body and keeps one block separator between surviving headings")
    func foldedDocumentOmitsCollapsedBody() {
        let doc = AttributedMarkdownBuilder.build("## a\n\n```diff\n+only-in-a\n```\n\n## b\n\n```diff\n+only-in-b\n```\n\n## c\n\n```diff\n+only-in-c\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        func text(_ collapsed: Set<String>) -> String {
            MarkdownAttributedStringBuilder.attributedString(
                for: MarkdownTextView.foldedDocument(doc, index: index, collapsed: collapsed), textColor: .white, sectionIndex: index).string
        }
        // Exact strings, so a fold that eats the heading's separator ("ab") or leaves a double gap fails.
        #expect(text(["a"]) == "a\n\nb\n\n+only-in-b\n\nc\n\n+only-in-c")
        #expect(text(["b"]) == "a\n\n+only-in-a\n\nb\n\nc\n\n+only-in-c")
        #expect(text(["c"]) == "a\n\n+only-in-a\n\nb\n\n+only-in-b\n\nc")
        #expect(text(["a", "b"]) == "a\n\nb\n\nc\n\n+only-in-c")
        #expect(text(["a", "b", "c"]) == "a\n\nb\n\nc")
        #expect(text([]) == MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: .white, sectionIndex: index).string)
    }

    @Test("bodyRuns of the last section stop before the document's trailing separator so the joined text has no dangling newline")
    func lastSectionKeepsNoTrailingSeparator() {
        // If the exact strings above fail only on the last section, adjust
        // `bodyRuns.upperBound` for the final section in `BranchDiffSectionIndex`
        // to exclude a trailing `.blockSeparator` run rather than loosening this test.
        let doc = AttributedMarkdownBuilder.build("## a\n\n```diff\n+x\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        let folded = MarkdownTextView.foldedDocument(doc, index: index, collapsed: ["a"])
        #expect(folded.runs.map(\.text).joined() == "a")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter MarkdownDiffLineStylingTests`
Expected: compile error, `foldedDocument` undefined.

- [ ] **Step 3: Implement**

`MarkdownTextView.swift`:

a. Add the three inputs next to `hiddenAnnotationIDs`.

b. Add:
```swift
    /// The document with every collapsed section's body removed. The index was
    /// built on the unfolded document, and its run ranges address that
    /// document, which is the one this always folds from.
    nonisolated static func foldedDocument(_ doc: RenderedDocument, index: BranchDiffSectionIndex?, collapsed: Set<String>) -> RenderedDocument {
        // `nonisolated`: MarkdownTextView is @MainActor and the test suite is not.
        guard let index, !collapsed.isEmpty else { return doc }
        let ranges = index.sections.filter { collapsed.contains($0.key) && $0.isFoldable }.map(\.bodyRuns)
        return doc.folding(removingRunRanges: ranges)
    }
```

c. `attributedString(for:)` passes `sectionIndex: sectionIndex` to the builder.

d. In `updateNSView`: compute `let displayDoc = Self.foldedDocument(doc, index: sectionIndex, collapsed: collapsedSections)` at the top. `doc` is used in six places with three meanings; replace exactly these: `attributedString(for: doc)` → `displayDoc` (build), `context.coordinator.lastDoc = doc` → `displayDoc` (run geometry for selection and anchors). Keep `doc.source` (identity, `docSourceChanged`) and both `doc.resolvedAnnotationIDs` uses (annotation data is document-level and unaffected by folding). `Self.spanDisplayNumbers(in: context.coordinator.lastDoc)` stays as is: it reads runs by mark id, and a diff has none.

Fold cost: a click rebuilds the attributed string and lays the whole document out twice. Measure it once on a max-budget diff during the Task 6 smoke and write the number into a `// ponytail: whole-document rebuild per fold (~N ms at the 1.5 MiB budget); incremental re-layout of the folded range if it ever shows up` comment above the `foldChanged` line. Keep `docSourceChanged` on `doc.source`. Add `let foldChanged = context.coordinator.lastCollapsedSections != collapsedSections || context.coordinator.lastSectionIndex != sectionIndex` into `sourceChanged` (not into `docSourceChanged`, so the scroll anchor does not re-fire). The index term matters on refresh: the source can be identical while the index (and therefore the heading attributes) changed, and without it the rebuild is skipped and `lastDoc` goes stale. Store `lastCollapsedSections` and `lastSectionIndex` alongside `lastTextColor`.

e. Selection on `foldChanged`: the spec keeps a selection outside the folded body and clears one inside it. Passing `preserving: nil` does NOT clear anything: `replaceTextStorage` only calls `setSelectedRange` for a non-nil range, and AppKit keeps the old UTF-16 indices, which after a fold select unrelated text further down. So compute the preserved range from the SOURCE span, which folding does not change: if `selectedSourceSpan` is non-nil, map `lowerBound` and `upperBound` through `SelectionSourceMapping.renderedUTF16Offset(forSourceOffset:in: displayDoc)`; if both map and the mapped text equals the previously selected text, preserve that range; otherwise preserve `NSRange(location: 0, length: 0)`. Then `publishSelectionState(in:)` as the existing path does. Add to `MarkdownDiffLineStylingTests`: a selection inside section b survives folding section a (same text, new offsets); a selection inside a survives nothing (zero-length).

Tab-switch anchor: `scrollAnchorSourceOffset()` captures against `lastDoc`, which is now the folded document, and the restore on remount runs against the same collapsed set from `DocumentTabMemory`, so the captured offset always lands on a visible run. State this in a comment next to `lastDoc = displayDoc`; no code change.

e2. Viewport for fold changes without a heading anchor (Collapse All / Expand All from the footer, or a tab restored with a different collapsed set): before `replaceTextStorage`, if `foldChanged && pendingSectionReanchor == nil`, capture `let anchor = context.coordinator.scrollAnchorSourceOffset()`; after the synchronous `updateBadges`, `scrollToSourceOffset(anchor)` when non-nil. Both helpers already exist (~line 840 and ~892) and map through `lastDoc`, which is the folded document by then; a captured offset inside a now-hidden body falls back to the preceding visible run, which is the heading.

e3. `applyProseWrapWidth` (coordinator, ~line 680) stamps `tailIndent = width` on every non-table paragraph. For a paragraph carrying `.diffSectionKey`, use `width - MarkdownAttributedStringBuilder.sectionHeadingTrailingReserve` instead (check the attribute at `paragraph.location`, the same way `.tableCellGrid` is checked), so a long path wraps before the counts badge instead of running under it. Add one assertion to `BranchDiffOverlayChromeTests`: a 300pt-wide view with a 120-character path heading has `headingRect.maxX <= 300 - inset - reserve + 1`.

f. Overlay wiring in the `if let overlay` block: set `overlay.sectionCounts` (from `sectionIndex`, nil when no index), `overlay.collapsedSections`, `overlay.onSectionToggled = { [weak coordinator] key in coordinator?.handleSectionToggle(key) }`, `overlay.addedCountColor/removedCountColor/hunkRuleColor` from `MarkdownAttributedStringBuilder.DiffPalette(terminalBackground:)` (`added`, `removed`) and `NSColor(Color.aw.border2)` (needs `import struct SwiftUI.Color` at the top if not already imported; check the file's imports, it already imports SwiftUI for `NSViewRepresentable`).

g. Coordinator:
```swift
    var lastCollapsedSections: Set<String> = []
    var onSectionToggled: ((String) -> Void)? = nil
    var pendingSectionReanchor: (key: String, offsetFromTop: CGFloat)? = nil

    func handleSectionToggle(_ key: String) {
        if let textView, let overlay = badgeOverlay,
            let chrome = overlay.sectionChrome.first(where: { $0.key == key }),
            let clip = textView.enclosingScrollView?.contentView {
            pendingSectionReanchor = (key, chrome.rowRect.minY - clip.bounds.minY)
        }
        onSectionToggled?(key)
    }

    /// After a fold rebuild, keep the toggled heading where it was on screen.
    func reanchorAfterFold() {
        guard let pending = pendingSectionReanchor, let textView, let overlay = badgeOverlay,
            let chrome = overlay.sectionChrome.first(where: { $0.key == pending.key }),
            let scrollView = textView.enclosingScrollView else { pendingSectionReanchor = nil; return }
        pendingSectionReanchor = nil
        let x = scrollView.contentView.bounds.origin.x
        textView.scroll(NSPoint(x: x, y: max(0, chrome.rowRect.minY - pending.offsetFromTop)))
    }
```
In `updateNSView`, set `context.coordinator.onSectionToggled = onSectionToggled` each pass, and after the synchronous `overlay.updateBadges(...)` call inside `if didReplaceTextStorage`, call `context.coordinator.reanchorAfterFold()` when `foldChanged`.

`DocumentPaneView.swift`: add `collapsedSections` and `onSectionToggled` as inputs (NOT `sectionIndex`: the view owns the index, computed from the document it actually renders and seeded from `cachedRender?.sectionIndex` on remount, so a stale index from the group can never shadow the current one). At the `MarkdownTextView(` call pass `sectionIndex: localSectionIndex`, `collapsedSections: collapsedSections`, `onSectionToggled: onSectionToggled`.

`DocumentGroupView.swift`: at the `DocumentPaneView(` call (line ~210) pass `collapsedSections: tabMemory.collapsedSections(for: document)`, `onSectionToggled: { key in tabMemory.toggleSection(key, for: document) }`. The group reads `tabMemory.sectionIndex(for:)` only for the footer's Collapse All keys (Task 8); those may lag one render behind after a refresh, which only affects which keys the toggle writes and is corrected by the next render.

- [ ] **Step 4: Build and run the focused tests**

Run: `./script/swift-test.sh --filter MarkdownDiffLineStylingTests` and `./script/swift-test.sh --filter BranchDiffOverlayChromeTests`. Then `./script/build_and_run.sh`, invoke Workspace → Show Branch Changes on a repo with changes, click a heading: the body folds, chevron flips, counts stay; click again: unfolds; switch tabs and back: folds persist. Record what was observed.

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on the three Swift files. Do not commit.

---

### Task 7: Sticky section header

**Files:**
- Create: `Sources/awesoMux/Views/Markdown/BranchDiffStickyHeaderView.swift`
- Modify: `Sources/awesoMux/Views/Markdown/MarkdownTextView.swift` (`makeNSView` ~184-283, coordinator)
- Test: `Tests/awesoMuxTests/BranchDiffStickyHeaderTests.swift` (create)

**Interfaces:**
- Consumes: `CommentBadgeOverlay.sectionChrome` (Task 5), `MarkdownAttributedStringBuilder.sectionHeadingFont()` (Task 4), `countsBadgeText`, `sectionAccessibilityLabel`.
- Produces:

```swift
final class BranchDiffStickyHeaderView: NSView {
    struct Model: Equatable { let key: String; let title: String; let added: Int; let removed: Int; let collapsed: Bool }
    var model: Model? { didSet }                 // nil hides the view
    var backgroundColor: NSColor
    var titleColor: NSColor, addedColor: NSColor, removedColor: NSColor, ruleColor: NSColor
    var onActivate: ((String) -> Void)?          // click / AX press → key
    static let height: CGFloat = 30
    /// Pure placement: given the visible top (document y), the section rows in
    /// document order, returns (index of the pinned section, y offset ≤ 0 by which
    /// the header is pushed up by the next heading), or nil when no heading is
    /// above the top edge.
    struct Placement: Equatable { let index: Int; let pushOffset: CGFloat }   // a struct: Optional<tuple> has no `==`
    static func placement(visibleTop: CGFloat, rows: [(minY: CGFloat, maxY: CGFloat)], headerHeight: CGFloat) -> Placement?
}
```

The bar is NOT an accessibility element (`setAccessibilityElement(false)`): the overlay already exposes one button per heading with the same label and value, and the document text itself carries the heading; a third identity per file is noise, not access (see the panels-have-three-identities note in the repo memory).

- [ ] **Step 0: Falsify the coordinate model before any frame math**

In `makeNSView`, temporarily `print(scrollView.isFlipped, scrollView.contentView.isFlipped, scrollView.clipsToBounds)`, then add the header with a magenta background and a hard-coded `pushOffset` of `-15` and take a screenshot from a dev build. Expected: scroll view not flipped, clip view flipped (its document is), header visible at the TOP of the pane, 15 pt cut off above the edge. If the header appears at the bottom, the sign in `updateStickyHeader` is inverted; if it is not clipped, the pushed header will draw over the annotation bar and needs `clipsToBounds = true` on the scroll view or a mask. Record the three printed values and the observation in the hand-off, remove the prints. If any of this fights back for more than 30 minutes, stop and report: Task 7 becomes its own PR.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
@testable import awesoMux

@Suite("Branch diff sticky header placement")
struct BranchDiffStickyHeaderTests {
    // rows: heading row rects in document space (minY, maxY), document order
    private let rows: [(minY: CGFloat, maxY: CGFloat)] = [(100, 124), (500, 524), (900, 924)]

    @Test("nothing pins while the first heading is still below the top edge")
    func nothingAboveTop() {
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 50, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the last heading above the top edge pins with no push")
    func pinsCurrentSection() throws {
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 300, rows: rows, headerHeight: 30) == .init(index: 0, pushOffset: 0))
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 700, rows: rows, headerHeight: 30) == .init(index: 1, pushOffset: 0))
    }

    @Test("the next heading pushes the pinned header up as it approaches, and takes over once it passes")
    func pushesOut() throws {
        // next heading at 500; visible top 480 → 20pt of room for a 30pt header → pushed up 10
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 480, rows: rows, headerHeight: 30) == .init(index: 0, pushOffset: -10))
        // heading exactly at the top edge → it is now the pinned one
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 500, rows: rows, headerHeight: 30) == .init(index: 1, pushOffset: 0))
    }

    @Test("a heading exactly at the top edge is not pinned (it is already visible in place)")
    func headingAtTopIsInPlace() {
        // Pinning a heading whose own row is fully visible would draw it twice.
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 100, rows: rows, headerHeight: 30)?.index == 0)
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 99, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the view starts hidden, shows with a model, and is not a separate accessibility element") @MainActor
    func viewModelAndAccessibility() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        #expect(view.isHidden)   // set in init, not only in model.didSet (didSet never fires for the initial nil)
        view.model = .init(key: "a.swift", title: "a.swift", added: 3, removed: 1, collapsed: false)
        #expect(!view.isHidden)
        #expect(view.isAccessibilityElement() == false)
        var activated: String?
        view.onActivate = { activated = $0 }
        view.simulateClick()
        #expect(activated == "a.swift")
    }
}
```

Decide the semantics precisely: pinned index = the last row with `row.minY <= visibleTop`; pushOffset = `min(0, nextRow.minY - visibleTop - headerHeight)` when a next row exists, else 0. With `visibleTop == row.minY` the row is at the edge and counts as pinned (test 4 expects index 0 at 100 and nil at 99); the drawn header covers the in-place heading exactly, so nothing shows twice.

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter BranchDiffStickyHeaderTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`BranchDiffStickyHeaderView.swift`: an `NSView` (not flipped) with an `NSTextField` label (`NSFont.systemFont(ofSize: 13, weight: .semibold)` so the bar stays 30pt), a chevron `NSImageView`, and two `NSTextField`s for counts right-aligned; `wantsLayer = true`, `layer.backgroundColor = backgroundColor.cgColor`, 1pt bottom rule drawn in `draw(_:)` with `ruleColor`. `isHidden = true` in `init`. `mouseDown` → `onActivate?(model.key)`; `func simulateClick()` calls the same private dispatch (test seam). `setAccessibilityElement(false)` in init and mark every subview `setAccessibilityElement(false)` too, so VoiceOver reads the document's own heading and the overlay's button, not a duplicate. `model` didSet: `guard oldValue != model`, `isHidden = model == nil`, refresh the subviews, `needsDisplay = true`. Implement `placement` exactly as specified, returning `Placement`.

`MarkdownTextView.makeNSView`: after `scrollView.documentView = textView`, create the header, `header.isHidden = true`, `scrollView.addSubview(header, positioned: .above, relativeTo: scrollView.contentView)`, keep it in `context.coordinator.stickyHeader`. Enable `scrollView.contentView.postsBoundsChangedNotifications = true` and observe `NSView.boundsDidChangeNotification` on the clip view with selector `clipViewBoundsDidChange(_:)` (same registration style as the existing frame observer). Wire `header.onActivate = { [weak coordinator] key in coordinator?.activateStickyHeader(key) }`.

Coordinator:
```swift
    weak var stickyHeader: BranchDiffStickyHeaderView?

    @objc func clipViewBoundsDidChange(_ notification: Notification) { updateStickyHeader() }

    func updateStickyHeader() {
        guard let header = stickyHeader, let textView, let overlay = badgeOverlay,
            let scrollView = textView.enclosingScrollView else { return }
        let chrome = overlay.sectionChrome
        guard !chrome.isEmpty else { header.model = nil; return }
        let clip = scrollView.contentView
        // `cachedRows` is rebuilt in the overlay's onSectionChromeChanged callback, not here: this runs per scroll frame.
        guard let placement = BranchDiffStickyHeaderView.placement(
            visibleTop: clip.bounds.minY, rows: cachedRows, headerHeight: BranchDiffStickyHeaderView.height)
        else { header.model = nil; return }
        let section = chrome[placement.index]
        let model = BranchDiffStickyHeaderView.Model(key: section.key, title: section.title, added: section.added, removed: section.removed, collapsed: section.collapsed)
        if header.model != model { header.model = model }
        // Scroll view space is unflipped: y grows upward, the clip's top edge is clip.frame.maxY.
        let width = clip.frame.width
        header.frame = NSRect(x: clip.frame.minX, y: clip.frame.maxY - BranchDiffStickyHeaderView.height - placement.pushOffset, width: width, height: BranchDiffStickyHeaderView.height)
    }

    func activateStickyHeader(_ key: String) {
        guard let textView, let overlay = badgeOverlay,
            let chrome = overlay.sectionChrome.first(where: { $0.key == key }),
            let scrollView = textView.enclosingScrollView else { return }
        let x = scrollView.contentView.bounds.origin.x
        textView.scroll(NSPoint(x: x, y: max(0, chrome.rowRect.minY - 4)))
        handleSectionToggle(key)
    }
```
The title shown is `section.title` (the heading text), never the key; keys are opaque and may carry a `\n` ordinal.

Scroll-path cost: the bounds notification fires per scroll frame. Keep the handler allocation-free on the common path: cache `rows` and the model when `sectionChrome` changes (the overlay exposes `var onSectionChromeChanged: (() -> Void)?`, invoked at the end of `updateSectionChrome`, and the coordinator rebuilds `cachedRows` there), and skip `header.model = …`/frame assignment when neither changed (`Model` is `Equatable`; compare before assigning). Do not coalesce the notification itself: a pinned header that lags the scroll by a runloop turn visibly jitters. With cached rows, `placement` is a linear scan over a few hundred entries at most; leave a `// ponytail: linear scan, binary search if a thousand-file diff makes this show up` comment.

Call `updateStickyHeader()` at the end of the `if didReplaceTextStorage` block in `updateNSView` (after `reanchorAfterFold()`), inside the async `Task` after the second `updateBadges`, and at the end of `updateDocumentGeometry()` (resize). Push header colors from `updateNSView`: `backgroundColor = terminalBackground ?? .windowBackgroundColor`, `titleColor = textColor ?? .labelColor`, counts from the `DiffPalette`, `ruleColor = NSColor(Color.aw.border2)`.

Note `pushOffset` is ≤ 0 in document (flipped) terms meaning "move up"; in the scroll view's unflipped space moving up is +y, hence `- placement.pushOffset` in the frame math. Verify direction in the running app; if inverted, flip the sign there only.

- [ ] **Step 4: Run tests and smoke**

Run: `./script/swift-test.sh --filter BranchDiffStickyHeaderTests`. Then `./script/build_and_run.sh`, open a branch-changes tab with at least three files, scroll: the current file's heading pins, is pushed out by the next heading, clicking it toggles that section and scrolls to its heading. Record what was observed.

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on the new file, `MarkdownTextView.swift`, the test. Do not commit.

---

### Task 8: Refresh for the tab's own pane, Collapse All / Expand All footer

**Files:**
- Modify: `Sources/awesoMux/Views/TerminalPathBarModel.swift:123-162` (add a pane-explicit `make`)
- Modify: `Sources/awesoMux/Services/BranchChangesOpener.swift:149-175` (`open` takes the pane)
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift:3910-3975` (`showBranchChanges(forPane:in:completion:)`), `:883` (environment injection)
- Create: `Sources/awesoMux/Services/BranchChangesRefreshAction.swift`
- Modify: `Sources/awesoMux/Views/DocumentPaneView.swift:15-32, 283-289` (`DocumentPaneSendBar`)
- Modify: `Sources/awesoMux/Views/DocumentGroupView.swift:301-307`
- Test: `Tests/awesoMuxTests/BranchChangesOpenerTests.swift` (pane-explicit path model), `Tests/awesoMuxTests/BranchChangesRefreshActionTests.swift` (create)

**Interfaces:**
- Produces:
  - `TerminalPathBarModel.make(pane: TerminalPane, session: TerminalSession, fileManager:homeDirectory:)`; `make(session:)` becomes `make(pane: session.activePane ?? fallback, session: session)`.
  - `BranchChangesOpener.open(session:pane:chrome:claimingSlot:)`; the remote gate and path model read `pane`, not `session.activePane`.
  - `struct BranchChangesRefreshAction { let run: @MainActor (_ paneID: TerminalPane.ID, _ completion: @escaping @MainActor () -> Void) -> Void }` and `extension EnvironmentValues { @Entry var branchChangesRefresh: BranchChangesRefreshAction? }`.
  - `BranchChangesCoordinator` becomes `@Observable` (it is already a `@MainActor final class` held as `@State` in the app) with `private(set) var refreshingPaneIDs: Set<TerminalPane.ID>`, inserted in `begin(paneID:)` and removed in `finish(_:paneID:)` when no other ticket for that pane is active. It is injected with `.environment(branchChangesCoordinator)` and read by the send bar with `@Environment(BranchChangesCoordinator.self)`, so a menu-started refresh disables the footer button too.
  - Environment reach: `ContentView.swift:131` documents that the split's `NSHostingController`s are fresh environment roots and re-injects `appSettingsStore`/`updateController` into each pane closure (~line 418). Both new values must be re-injected there the same way (`@Environment(\.branchChangesRefresh)` + `@Environment(BranchChangesCoordinator.self)` read in `ContentView`, then `.environment(\.branchChangesRefresh, branchChangesRefresh)` and `.environment(branchChangesCoordinator)` on the detail content). Without this the footer sees `nil`, looks enabled, and does nothing. Verify by grepping every `.environment(appSettingsStore)` site and mirroring each one.
  - `AwesoMuxApp.showBranchChanges(forPane paneID: TerminalPane.ID, completion: @escaping @MainActor () -> Void = {})`; `showBranchChangesForActivePane()` resolves the active pane and calls it.
  - `DocumentPaneSendBar` new inputs: `var sectionKeys: [String] = []`, `var collapsedSections: Set<String> = []`, `var onSetCollapsedSections: (Set<String>) -> Void = { _ in }`.
  - Pure helper for tests: `enum BranchChangesRefreshPolicy { static func verdict(target: DocumentNudgeTargetResolution, inFlight: Bool) -> Verdict }` with `enum Verdict: Equatable { case ready; case busy; case unavailable(String) }` (the string is the caption).

- [ ] **Step 0: Falsify environment reach before the split**

This is the repository's first `@Entry` (grep confirms none). Add a throwaway `@Entry var branchChangesProbe: Int = 0`, inject `.environment(\.branchChangesProbe, 7)` at `AwesoMuxApp.swift:883` AND in `ContentView`'s detail closure next to `.environment(appSettingsStore)`, print it from `DocumentPaneSendBar.body` in a dev build, and confirm `7` arrives on a branch-changes tab. Remove the probe. If it does not arrive even with the `ContentView` re-injection, fall back to passing the action down by value from `DocumentGroupView` (which already receives `sessionStore` and `runtime`) and say so in the hand-off.

Why not the `AgentTranscriptResumeStaging` pattern the spec cites for the pane resolution: that enum is stateless and takes its collaborators as parameters. The refresh command needs the app's `BranchChangesCoordinator` (`@State` in `AwesoMuxApp`, the ticket authority for latest-wins), `sessionStore`, and the failure-alert presenter, none of which the send bar holds. An environment-delivered closure is the smallest thing that carries all three without making the coordinator a global.

- [ ] **Step 1: Write the failing tests**

`BranchChangesRefreshActionTests.swift`:
```swift
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Branch changes refresh policy")
struct BranchChangesRefreshActionTests {
    private func pane() -> TerminalPane { TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local) }

    @Test("an available local target is ready; in flight is busy")
    func readyAndBusy() {
        #expect(BranchChangesRefreshPolicy.verdict(target: .available(pane()), inFlight: false) == .ready)
        #expect(BranchChangesRefreshPolicy.verdict(target: .available(pane()), inFlight: true) == .busy)
    }

    @Test("a closed or remote terminal is unavailable with a caption")
    func unavailable() {
        guard case .unavailable(let closed) = BranchChangesRefreshPolicy.verdict(target: .unavailable(.terminalUnavailable), inFlight: false) else { Issue.record("expected unavailable"); return }
        #expect(closed == "This tab's terminal was closed")
        guard case .unavailable(let remote) = BranchChangesRefreshPolicy.verdict(target: .unavailable(.requiresLocalTerminal), inFlight: false) else { Issue.record("expected unavailable"); return }
        #expect(remote == "Refresh needs a local terminal")
    }
}
```

In `BranchChangesOpenerTests.swift` add a test through the OPENER, not the path-model helper, using the file's existing `SpyGitRunner` and temporary-repository fixtures (see `opener(_:cacheDirectory:)` at line ~62 and the fixtures the other tests use):
```swift
    @Test("open(session:pane:) reads the explicit pane, not the session's active pane")
    func openUsesExplicitPane() async throws {
        // Active pane: remote plan (would fail with .remotePane if consulted).
        // Explicit pane: local, inside the fixture repository.
        let active = TerminalPane(title: "ssh", workingDirectory: "/tmp", executionPlan: <remote plan from the file's fixtures>)
        let explicit = TerminalPane(title: "zsh", workingDirectory: repository.rootURL.path, executionPlan: .local)
        let session = <session fixture with both panes, `active` selected>
        let runner = SpyGitRunner(outcomes: <the successful base-ref + diff outcomes the existing happy-path test uses>)
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session, pane: explicit, chrome: chrome, claimingSlot: { _ in true })
        #expect((try? result.get()) != nil)
        #expect(runner.invocations.allSatisfy { $0.directory == repository.rootURL })
    }
```
Fill the angle-bracket placeholders from the fixtures already in that file (read it first; do not invent new fixture types). The assertion that matters is the runner's working directory: it must be the explicit pane's repository, and the remote active pane must not short-circuit the call.

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter BranchChangesRefreshActionTests` and `--filter BranchChangesOpenerTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

a. `TerminalPathBarModel`: split `make(session:)` into `make(pane:session:fileManager:homeDirectory:)` containing the existing body from `if let remoteModel` down, and keep `make(session:)` as the active-pane wrapper.

b. `BranchChangesOpener.open`: add `pane: TerminalPane` after `session`; replace `session.activePane?.executionPlan ?? .local` with `pane.executionPlan` and `TerminalPathBarModel.make(session: session)` with `.make(pane: pane, session: session)`. Update the one caller.

c. `BranchChangesRefreshAction.swift`:
```swift
import AwesoMuxCore
import SwiftUI

/// The app's Show Branch Changes command, addressed by pane so a document tab
/// can refresh for the terminal it came from rather than the active one.
struct BranchChangesRefreshAction {
    let run: @MainActor (_ paneID: TerminalPane.ID, _ completion: @escaping @MainActor () -> Void) -> Void
}

extension EnvironmentValues {
    @Entry var branchChangesRefresh: BranchChangesRefreshAction? = nil
}

enum BranchChangesRefreshPolicy {
    enum Verdict: Equatable {
        case ready
        case busy
        case unavailable(String)
    }

    static func verdict(target: DocumentNudgeTargetResolution, inFlight: Bool) -> Verdict {
        switch target {
        case .available:
            return inFlight ? .busy : .ready
        case .unavailable(.requiresLocalTerminal):
            return .unavailable(String(localized: "Refresh needs a local terminal", comment: "Caption under a disabled Refresh button on a branch changes tab whose terminal is remote"))
        case .unavailable:
            return .unavailable(String(localized: "This tab's terminal was closed", comment: "Caption under a disabled Refresh button on a branch changes tab whose terminal no longer exists"))
        }
    }
}
```
Check `DocumentNudgeUnavailableReason`'s cases (`Sources/AwesoMuxCore/Models/TerminalPaneLayout+Siblings.swift`) and map `.readOnlyRemoteSnapshot` into the closed-terminal caption (it cannot occur for a generated document).

d. `AwesoMuxApp.swift`: rename the body of `showBranchChangesForActivePane()` into
```swift
    private func showBranchChanges(forPane paneID: TerminalPane.ID, completion: @escaping @MainActor () -> Void = {}) {
        guard let sessionID = sessionStore.sessionIDContainingPane(paneID),
            let session = sessionStore.session(id: sessionID),      // use the store's existing session lookup
            let pane = session.layout.pane(id: paneID)
        else { completion(); return }
        guard case .local = pane.executionPlan else { showBranchChangesFailureAlert(.remotePane); completion(); return }
        … existing ticket/Task body, with `opener.open(session: session, pane: pane, chrome: chrome, claimingSlot: …)`
        … and `defer { coordinator.finish(ticket, paneID: paneID); completion() }` inside the Task
    }

    private func showBranchChangesForActivePane() {
        healSheetWedgeBeforeGatedCommand()
        guard !isAnySheetPresented, let session = sessionStore.selectedSession,
            let pane = session.layout.pane(id: session.activePaneID) else { return }
        showBranchChanges(forPane: pane.id)
    }
```
Keep the sheet-wedge heal and `isAnySheetPresented` gate only on the menu path (the button is inside the window and cannot be reached while a sheet is up). At line 883 add `.environment(\.branchChangesRefresh, BranchChangesRefreshAction { paneID, completion in showBranchChanges(forPane: paneID, completion: completion) })`.

e. `DocumentPaneSendBar`: add `@Environment(\.branchChangesRefresh) private var branchChangesRefresh`, `@Environment(BranchChangesCoordinator.self) private var branchChangesCoordinator`, the three new inputs. Busy state comes from the coordinator, not a local flag: `inFlight = target.map { branchChangesCoordinator.refreshingPaneIDs.contains($0.id) } ?? false`. Keep a local `@State private var refreshRequested = false` only to debounce a double-click before the coordinator's set updates; clear it in the completion. Replace the `else if pane.generatedDocumentKind != nil` branch with:
```swift
            } else if pane.generatedDocumentKind == .branchChanges {
                branchChangesControls
            } else if pane.generatedDocumentKind != nil {
                Label("Read-only generated document", systemImage: "lock")   // unchanged
```
and:
```swift
    private var branchChangesControls: some View {
        let verdict = BranchChangesRefreshPolicy.verdict(
            target: session.layout.documentNudgeTarget(for: pane.id), inFlight: refreshRequested || isRefreshingTarget)
        let unavailable: String? = { if case .unavailable(let caption) = verdict { return caption }; return nil }()
        return HStack(spacing: 8) {
            VStack(spacing: 3) {
                SendToAgentButton(
                    purpose: .refreshBranchChanges,
                    title: String(localized: "Refresh", comment: "Send-bar button title on a branch changes tab that re-runs the comparison"),
                    failed: false,
                    isBusy: verdict == .busy,
                    unavailableDescription: unavailable,
                    action: refresh
                )
                .frame(height: 28)
                Text(unavailable ?? String(localized: "Read-only generated document", comment: "Caption under the Refresh button on a branch changes tab"))
                    .font(.system(size: 11)).foregroundStyle(Color.aw.text2).lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
            }
            if !sectionKeys.isEmpty {
                // After a refresh adds one file, this reads "Collapse All" again while
                // the rest stay folded. Cosmetic and self-correcting on the next press.
                let allCollapsed = Set(sectionKeys).isSubset(of: collapsedSections)
                Button(allCollapsed
                    ? String(localized: "Expand All", comment: "Send-bar button on a branch changes tab that unfolds every file section")
                    : String(localized: "Collapse All", comment: "Send-bar button on a branch changes tab that folds every file section")) {
                    onSetCollapsedSections(allCollapsed ? [] : Set(sectionKeys))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isRefreshingTarget: Bool {
        guard case .available(let target) = session.layout.documentNudgeTarget(for: pane.id) else { return false }
        return branchChangesCoordinator.refreshingPaneIDs.contains(target.id)
    }

    private func refresh() {
        guard !refreshRequested, !isRefreshingTarget, let branchChangesRefresh,
            case .available(let target) = session.layout.documentNudgeTarget(for: pane.id) else { return }
        refreshRequested = true
        branchChangesRefresh.run(target.id) { refreshRequested = false }
    }
```
`SendToAgentButton.Purpose` (line ~724) gains a `.refreshBranchChanges` case; give it the `arrow.clockwise` symbol wherever `Purpose` maps to an icon (read the enum's uses in that struct and mirror `.resumeSession`). If `Purpose` carries no icon, add `systemImage` handling only for this case.

f. `DocumentGroupView.swift` at `DocumentPaneSendBar(`: pass `sectionKeys: tabMemory.sectionIndex(for: document)?.keys ?? []`, `collapsedSections: tabMemory.collapsedSections(for: document)`, `onSetCollapsedSections: { tabMemory.setCollapsedSections($0, for: document) }`.

g. Run `./script/update_string_catalog.sh` and include `Resources/Localizable.xcstrings` in the handoff.

Add a coordinator test (new `Tests/awesoMuxTests/BranchChangesCoordinatorTests.swift` or the existing coordinator suite if one exists; grep first): `begin(paneID:)` inserts the pane into `refreshingPaneIDs`, `finish` of the last active ticket removes it, and `finish` of an older superseded ticket while a newer one is active leaves it in.

- [ ] **Step 4: Run tests and smoke**

Run: `./script/swift-test.sh --filter BranchChangesRefreshActionTests`, `--filter BranchChangesOpenerTests`, `--filter BranchChangesCompletionTests`, `--filter BranchChangesCoordinatorTests`. Then `./script/build_and_run.sh`: open branch changes from pane A, focus pane B (different repo or none), press Refresh on the tab: the tab re-renders for pane A's repo; snapshot time updates; folds persist. Close pane A: the button disables with "This tab's terminal was closed". Start a refresh from the Workspace menu and check the footer button is disabled while it runs. Collapse All while scrolled deep into a many-file diff keeps the viewport on the same heading. Collapse All / Expand All flip every section.

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on every changed Swift file. Do not commit.

---

### Task 9: Spike: per-line VoiceOver roles (bounded, 45 minutes) — RUNS FIRST

Runs before Task 1: the diff-line runs it stamps already exist on this branch, and a positive result adds an attribute to Task 4's stamping loop.

**Files:**
- Modify (only if it works): `Sources/awesoMux/Views/Markdown/MarkdownAttributedStringBuilder.swift` (diff-line branch)
- Report: append findings to `docs/superpowers/specs/2026-09-01-branch-changes-collapse-design.md` under "Not in this pass"

- [ ] **Step 1: Try the attribute**

On `.diffLine(.added)` / `.removed` runs add `NSAttributedString.Key.accessibilityCustomText` (`NSAccessibilityCustomTextAttribute` in AppKit; check the SDK for the exact key name with `grep -r "CustomText" $(xcrun --show-sdk-path)/System/Library/Frameworks/AppKit.framework/Headers/NSAccessibilityConstants.h`) with values "added line" / "removed line". Build, run, enable VoiceOver (⌘F5), navigate into the document with VO+arrow keys, listen to whether the value is spoken on an added line.

- [ ] **Step 2: Decide**

If spoken: keep the attribute, add one assertion in `MarkdownDiffLineStylingTests` that the attribute is present on `+new` and absent on ` context`, and note in the spec that per-line roles shipped. If not spoken within the time box: revert the builder change, write two sentences under "Not in this pass" naming the attribute tried and what VoiceOver read instead, and stop.

- [ ] **Step 3: Hand off**

Report the verdict and the exact attribute name tried. Do not commit.

---

### Task 10: Full verification

**Files:** none new.

- [ ] **Step 1: Format check**

Run: `./script/format.sh --lint` and fix anything it reports in files this plan touched.

- [ ] **Step 2: Focused suites**

Run each and confirm a non-zero test count:
`./script/swift-test.sh --filter RenderedDocumentFoldingTests`, `BranchDiffSectionIndexTests`, `DocumentTabMemoryTests`, `MarkdownDiffLineStylingTests`, `BranchDiffOverlayChromeTests`, `BranchDiffStickyHeaderTests`, `BranchChangesRefreshActionTests`, `BranchChangesOpenerTests`, `BranchChangesCompletionTests`, `BranchChangesRendererTests`.

- [ ] **Step 3: Preflight**

Run: `/opt/homebrew/bin/bash ./script/preflight.sh` directly, no pipe, and read its own exit code. If it exits non-zero on suites this plan did not touch, rerun those suites in isolation with `--filter` and report both results.

- [ ] **Step 4: GUI smoke**

Build with `./script/build_and_run.sh`, then the user records a GIF (Gifox) covering: fold/unfold by heading click, counts, hunk bands with hairline, sticky header pin and push, sticky header click, Refresh from a non-active pane, Collapse All / Expand All, tab switch keeping folds. Split with `ffmpeg -loglevel error -i "<gif>" -vf "fps=2" out/f%03d.png` and inspect frames. Check the header's "Snapshot taken at" time is after the build time before trusting any frame.

- [ ] **Step 5: Report**

List exactly which checks ran and their results, per AGENTS.md.
