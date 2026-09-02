# Branch Changes Collapse, Counts, Sticky Header, Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Show Branch Changes tab, each file section folds to its heading, headings carry `+n −m` counts, the current file's heading pins to the top while scrolling, hunk headers read as dividers, and the footer refreshes the diff for the tab's own terminal.

**Architecture:** A pure section index is built from the rendered runs (view target). Folding derives a `RenderedDocument` with body runs removed (Core helper) and everything downstream renders that document unchanged. The attributed-string builder stamps a section-key attribute on file headings; the badge overlay reads it to draw chevrons and counts and to take clicks; a sticky header view in the scroll view mirrors the current section. Collapsed keys live in `DocumentTabMemory`. Refresh is the existing app command with an explicit pane id, reached from the send bar through an environment value.

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSTextView / TextKit 2), Swift Testing, `Color.aw.*` Catppuccin tokens, `./script/swift-test.sh --filter`, `./script/format.sh`, `./script/update_string_catalog.sh`, `./script/preflight.sh`.

**Spec:** `docs/superpowers/specs/2026-09-01-branch-changes-collapse-design.md`

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
    struct Hunk: Equatable {
        let runIndex: Int              // the .diffLine(.hunk) run
        let oldStart: Int?             // nil when the header does not parse
        let newStart: Int?
        /// One entry per following diff line until the next hunk/heading:
        /// (old, new) line numbers; nil on the side the line is absent from.
        let lineNumbers: [(old: Int?, new: Int?)]   // implemented as a struct pair, see below
    }
    struct Section: Equatable {
        let key: String
        let headingRuns: Range<Int>    // consecutive .heading(level: 2) runs
        let bodyRuns: Range<Int>       // first run after the heading's separator ..< next heading (or runs.count)
        let added: Int
        let removed: Int
        let hunks: [Hunk]
    }
    let sections: [Section]
    init(document: RenderedDocument)
    var keys: [String] { sections.map(\.key) }
    func section(key: String) -> Section?
    static func key(headingText: String, occurrence: Int) -> String   // occurrence 0 => text; n>0 => "\(text)#\(n+1)"
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldLength: Int, newStart: Int, newLength: Int)?
}
```

`lineNumbers` element type is `struct LineNumber: Equatable { let old: Int?; let new: Int? }` (tuples are not `Equatable`).

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

    @Test("one section per H2 heading that is followed by a diff fence; the H1 and prose headings are skipped")
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
        #expect(index.keys == ["a.swift", "b.swift — new file"])
        let a = index.sections[0]
        #expect(a.added == 1 && a.removed == 1)
        #expect(doc.runs[a.headingRuns].allSatisfy { $0.style == .heading(level: 2) })
        #expect(doc.runs[a.bodyRuns].contains { $0.style == .diffLine(.added) })
        #expect(!doc.runs[a.bodyRuns].contains { $0.style == .heading(level: 2) })
        let b = index.sections[1]
        #expect(b.added == 2 && b.removed == 0)
        #expect(b.bodyRuns.upperBound == doc.runs.count)
    }

    @Test("a heading over a non-diff fence is not a section")
    func nonDiffFenceIsNotASection() {
        let (_, index) = build("## x\n\n```swift\nlet a = 1\n```\n")
        #expect(index.sections.isEmpty)
    }

    @Test("duplicate heading text gets an ordinal key so one fold never toggles two sections")
    func duplicateKeys() {
        let (_, index) = build("## same\n\n```diff\n+a\n```\n\n## same\n\n```diff\n+b\n```\n")
        #expect(index.keys == ["same", "same#2"])
        #expect(BranchDiffSectionIndex.key(headingText: "same", occurrence: 1) == "same#2")
    }

    @Test("hunk headers parse, including -0,0 and a missing length")
    func hunkHeaderParsing() {
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -344,10 +345,29 @@ func x") == (344, 10, 345, 29))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -0,0 +1,5 @@") == (0, 0, 1, 5))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -7 +7 @@") == (7, 1, 7, 1))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ garbage @@") == nil)
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@@ -1,2 -3,4 +5,6 @@@") == nil)
    }

    @Test("per-line numbering walks both sides: context advances both, added only new, removed only old")
    func lineNumbers() {
        let (_, index) = build("## f\n\n```diff\n@@ -10,3 +20,4 @@\n ctx\n-gone\n+one\n+two\n ctx2\n```\n")
        let hunk = index.sections[0].hunks[0]
        #expect(hunk.oldStart == 10 && hunk.newStart == 20)
        let pairs = hunk.lineNumbers.map { [$0.old, $0.new] }
        #expect(pairs == [[10, 20], [11, nil], [nil, 21], [nil, 22], [12, 23]])
    }

    @Test("an unparsable hunk header yields nil numbers and still counts its lines")
    func unparsableHunkStillCounts() {
        let (_, index) = build("## f\n\n```diff\n@@ nope @@\n+a\n-b\n```\n")
        let section = index.sections[0]
        #expect(section.added == 1 && section.removed == 1)
        #expect(section.hunks[0].oldStart == nil)
        #expect(section.hunks[0].lineNumbers.allSatisfy { $0.old == nil && $0.new == nil })
    }

    @Test("meta lines and a second hunk do not leak numbers across hunks")
    func secondHunkRestarts() {
        let (_, index) = build("## f\n\n```diff\n@@ -1,1 +1,1 @@\n a\n@@ -50,1 +60,1 @@\n b\n```\n")
        let hunks = index.sections[0].hunks
        #expect(hunks.count == 2)
        #expect(hunks[1].lineNumbers.first?.old == 50 && hunks[1].lineNumbers.first?.new == 60)
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
    struct LineNumber: Equatable {
        let old: Int?
        let new: Int?
    }

    struct Hunk: Equatable {
        let runIndex: Int
        let oldStart: Int?
        let newStart: Int?
        let lineNumbers: [LineNumber]
    }

    struct Section: Equatable {
        let key: String
        let headingRuns: Range<Int>
        let bodyRuns: Range<Int>
        let added: Int
        let removed: Int
        let hunks: [Hunk]
    }

    let sections: [Section]

    var keys: [String] { sections.map(\.key) }

    func section(key: String) -> Section? { sections.first { $0.key == key } }

    /// The second and later headings with identical text get an ordinal, so a
    /// fold keyed by heading text can never toggle two sections at once.
    static func key(headingText: String, occurrence: Int) -> String {
        occurrence == 0 ? headingText : "\(headingText)#\(occurrence + 1)"
    }

    init(document: RenderedDocument) {
        let runs = document.runs
        var sections: [Section] = []
        var occurrences: [String: Int] = [:]
        var i = 0
        // Heading starts: (first run index, last run index + 1, joined text)
        var headings: [(start: Int, end: Int, text: String)] = []
        while i < runs.count {
            guard case .heading(level: 2) = runs[i].style else { i += 1; continue }
            var end = i
            var text = ""
            while end < runs.count, case .heading(level: 2) = runs[end].style {
                text += runs[end].text
                end += 1
            }
            headings.append((i, end, text))
            i = end
        }
        for (n, heading) in headings.enumerated() {
            // Body starts after the heading's block separator, ends at the next heading.
            var bodyStart = heading.end
            if bodyStart < runs.count, runs[bodyStart].style == .blockSeparator { bodyStart += 1 }
            let bodyEnd = n + 1 < headings.count ? headings[n + 1].start : runs.count
            // Only a heading whose first content run is a diff line is a file section.
            guard bodyStart < bodyEnd, case .diffLine = runs[bodyStart].style else { continue }
            let occurrence = occurrences[heading.text, default: 0]
            occurrences[heading.text] = occurrence + 1
            var added = 0, removed = 0
            var hunks: [Hunk] = []
            var current: (index: Int, old: Int?, new: Int?, lines: [LineNumber])? = nil
            func flush() {
                if let c = current {
                    hunks.append(Hunk(runIndex: c.index, oldStart: c.old, newStart: c.new, lineNumbers: c.lines))
                }
                current = nil
            }
            for r in bodyStart..<bodyEnd {
                guard case .diffLine(let kind) = runs[r].style else { continue }
                switch kind {
                case .hunk:
                    flush()
                    let parsed = Self.parseHunkHeader(runs[r].text)
                    current = (r, parsed?.oldStart, parsed?.newStart, [])
                case .added:
                    added += 1
                    current?.lines.append(LineNumber(old: nil, new: current?.new))
                    if current?.new != nil { current?.new! += 1 }
                case .removed:
                    removed += 1
                    current?.lines.append(LineNumber(old: current?.old, new: nil))
                    if current?.old != nil { current?.old! += 1 }
                case .context:
                    current?.lines.append(LineNumber(old: current?.old, new: current?.new))
                    if current?.old != nil { current?.old! += 1 }
                    if current?.new != nil { current?.new! += 1 }
                case .meta:
                    break
                }
            }
            flush()
            sections.append(Section(
                key: Self.key(headingText: heading.text, occurrence: occurrence),
                headingRuns: heading.start..<heading.end,
                bodyRuns: bodyStart..<bodyEnd,
                added: added, removed: removed, hunks: hunks))
        }
        self.sections = sections
    }

    /// `@@ -a[,b] +c[,d] @@…` → (a, b, c, d); a missing length means 1.
    /// Combined-diff headers (`@@@`) and anything else return nil.
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldLength: Int, newStart: Int, newLength: Int)? {
        guard line.hasPrefix("@@ "), !line.hasPrefix("@@@") else { return nil }
        let parts = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
            let old = range(parts[0].dropFirst()), let new = range(parts[1].dropFirst())
        else { return nil }
        return (old.start, old.length, new.start, new.length)
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

Note for the implementer: inside the `for r in …` loop, `current?.new! += 1` on an optional tuple does not compile; hold `current` as a small `private struct HunkBuilder { var index: Int; var old: Int?; var new: Int?; var lines: [LineNumber] }` and mutate `current?.old`/`current?.new` with `if let o = current?.old { current?.old = o + 1 }`. Keep the numbering semantics exactly as the tests state.

- [ ] **Step 4: Run tests**

Run: `./script/swift-test.sh --filter BranchDiffSectionIndexTests`
Expected: 7 tests pass. Note: the `parseHunkHeader` tuple comparisons with `==` compile because both sides are 4-tuples of `Int`.

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
let sectionIndex = pane.generatedDocumentKind == .branchChanges ? BranchDiffSectionIndex(document: doc) : nil
onRenderCompleted?(DocumentTabMemory.Render(loadResult: result, renderedDoc: doc, sectionIndex: sectionIndex))
```

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
- Consumes: `BranchDiffSectionIndex` (Task 2), `.key(headingText:occurrence:)`.
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
        #expect(attributed.attribute(.diffSectionKey, at: first.location, effectiveRange: nil) as? String == "a.swift — new file")
        #expect(attributed.attribute(.diffSectionKey, at: second.location, effectiveRange: nil) as? String == "a.swift — new file#2")
        // The italic status run is part of the same heading and carries the same key.
        let status = ns.range(of: "new file")
        #expect(attributed.attribute(.diffSectionKey, at: status.location, effectiveRange: nil) as? String == "a.swift — new file")
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
```

Add `sectionIndex: BranchDiffSectionIndex? = nil` as the last parameter of `attributedString(for:…)`. The index was built on the UNFOLDED document while `doc` may be folded (Task 6), so its run indices cannot be used here. Derive keys by walking `doc.runs` the same way the index does: group consecutive `.heading(level: 2)` runs, join their text, count occurrences of that text, and form `BranchDiffSectionIndex.key(headingText:occurrence:)`; keep it only when `sectionIndex.section(key:) != nil`. Folding never removes headings, so occurrence ordinals match the index. Implement as:

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
            var text = ""
            while end < doc.runs.count, case .heading(level: 2) = doc.runs[end].style {
                text += doc.runs[end].text
                end += 1
            }
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            let key = BranchDiffSectionIndex.key(headingText: text, occurrence: occurrence)
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
        let headingRect: NSRect      // overlay space, full heading line fragment(s)
        let rowRect: NSRect          // full-width click target for the heading's first line
        let collapsed: Bool
        let added: Int
        let removed: Int
    }
    /// Inputs for the section chrome. Set before `updateBadges`; nil disables it.
    var sectionCounts: [String: (added: Int, removed: Int)]? = nil
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
        overlay.collapsedSections = collapsed
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

    @Test("accessibility children include one button per section with label and value") @MainActor
    func accessibilityButtons() throws {
        let (overlay, _, _, _) = makeOverlay(twoFiles, collapsed: ["a.swift"])
        let elements = overlay.sectionAccessibilityChildrenForTesting()
        #expect(elements.count == 2)
        #expect(elements[0].accessibilityLabel() == "a.swift, 1 added, 1 removed")
        #expect(elements[0].accessibilityValue() as? String == "collapsed")
        #expect(elements[1].accessibilityValue() as? String == "expanded")
        #expect(elements[0].accessibilityRole() == .button)
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
                out[out.count - 1] = SectionChrome(key: key, headingRect: last.headingRect.union(cell.rect), rowRect: last.rowRect, collapsed: last.collapsed, added: last.added, removed: last.removed)
                return
            }
            let count = counts[key] ?? (0, 0)
            let row = NSRect(x: 0, y: cell.rect.minY, width: bounds.width, height: cell.rect.height)
            out.append(SectionChrome(key: key, headingRect: cell.rect, rowRect: row, collapsed: collapsedSections.contains(key), added: count.added, removed: count.removed))
        }
        sectionChrome = out
        sectionAttr = out.isEmpty ? nil : attr
        sectionTextView = out.isEmpty ? nil : textView
```
Call it from both `updateTableBorders` call sites (line 131 in `layout()` and line 633 in `updateBadges`) right after `updateTableBorders`, and extend the `layout()` fast-path condition so a section-only document (no tables, no pills) still recomputes on resize: add an `else if let attr = sectionAttr, let textView = sectionTextView { updateSectionChrome(attr: attr, textView: textView); needsDisplay = true }` branch. Clear `sectionChrome` on the no-layout-manager guard path in `updateBadges` (where table state is cleared).

`enumerateAttribute` reports the widest effective range for that key regardless of other attributes, so the merge branch is a safety net; keep it.

3. Hit testing: in `hitTest` and `mouseDown`, after the pill loop, check `sectionChrome` `rowRect`s (independent of `annotationsInteractive`; folding is not an annotation action). In `mouseDown`, call `onSectionToggled?(chrome.key)`. Add `override func resetCursorRects()` adding `addCursorRect(chrome.rowRect, cursor: .pointingHand)` for each section, and call `window?.invalidateCursorRects(for: self)` at the end of `updateSectionChrome`.

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
- `diffHunkRuleRows(intersecting:in:width:) -> [NSRect]`: same fragment walk as `diffTintRows` but reading `.diffHunkRule`; returns a 1pt-high rect at each hunk row's `minY` (row rect computed the same way, height 1). Factor the shared walk into a private generic helper if it stays readable; otherwise duplicate the 20 lines and say why in a comment.
- `drawChevron`: `NSImage(systemSymbolName: chrome.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)` with `NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)`, tinted with `tableBorderColor ?? .labelColor` at full alpha, drawn centred vertically in the heading's first line and horizontally in the gutter: x from `textView.textContainerInset.width` to `+ MarkdownAttributedStringBuilder.sectionHeadingGutter`.
- `drawCounts`: `countsBadgeText` split into two runs, `+n` in `addedCountColor`, `−m` in `removedCountColor`, font `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)`, right-aligned so the text ends at `bounds.width - textView.textContainerInset.width`, vertically centred on `chrome.headingRect`'s first line (use `chrome.headingRect.minY + lineHeight/2` where lineHeight is the heading font's line height, so a wrapped heading keeps the badge on its first line). Draw a rounded rect behind both at `Color.aw`-independent `(tableBorderColor ?? .labelColor).withAlphaComponent(0.08)` with 4pt corner radius and 4pt horizontal padding.

5. Accessibility: `sectionAccessibilityChildren()` builds a `PillAccessibilityElement` per chrome (same class as pills; set role `.button`, label from `sectionAccessibilityLabel`, `setAccessibilityValue(chrome.collapsed ? "collapsed" : "expanded")`, live `frameProvider` from `rowRect`, `onPress = { onSectionToggled?(key) }`). Append it in `accessibilityChildren()`: `pillAccessibilityChildren() + sectionAccessibilityChildren() + materializedTableElements()`. Localize: the label and values go through `String(localized:)` with `comment:` (three strings: `"\(key), \(added) added, \(removed) removed"`, `"collapsed"`, `"expanded"`). Count-dependent copy: "added"/"removed" here are labels after a number, not pluralized nouns, so no stringsdict is needed; note that in a comment.

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
    @Test("a folded document renders no body text for the collapsed section and keeps the others")
    func foldedDocumentOmitsCollapsedBody() {
        let doc = AttributedMarkdownBuilder.build("## a\n\n```diff\n+only-in-a\n```\n\n## b\n\n```diff\n+only-in-b\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        let folded = MarkdownTextView.foldedDocument(doc, index: index, collapsed: ["a"])
        let text = MarkdownAttributedStringBuilder.attributedString(for: folded, textColor: .white, sectionIndex: index).string
        #expect(!text.contains("only-in-a"))
        #expect(text.contains("only-in-b"))
        #expect(text.contains("a"))
        // Folding the heading's own separator too leaves no blank line before the next heading.
        #expect(!text.contains("a\n\n\n"))
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
    static func foldedDocument(_ doc: RenderedDocument, index: BranchDiffSectionIndex?, collapsed: Set<String>) -> RenderedDocument {
        guard let index, !collapsed.isEmpty else { return doc }
        let ranges = index.sections.filter { collapsed.contains($0.key) }.map(\.bodyRuns)
        return doc.folding(removingRunRanges: ranges)
    }
```

c. `attributedString(for:)` passes `sectionIndex: sectionIndex` to the builder.

d. In `updateNSView`: compute `let displayDoc = Self.foldedDocument(doc, index: sectionIndex, collapsed: collapsedSections)` at the top and use `displayDoc` everywhere the method currently uses `doc` for building and for `lastDoc` (selection mapping must see the folded runs). Keep `docSourceChanged` on `doc.source`. Add `let foldChanged = context.coordinator.lastCollapsedSections != collapsedSections` into `sourceChanged` (not into `docSourceChanged`, so the scroll anchor does not re-fire). Store `lastCollapsedSections = collapsedSections` alongside `lastTextColor`.

e. Selection: when `foldChanged`, pass `preserving: nil` (clear the selection) instead of the preserved range.

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

`DocumentPaneView.swift`: add the three inputs; at the `MarkdownTextView(` call pass `sectionIndex: sectionIndex ?? localSectionIndex`, `collapsedSections: collapsedSections`, `onSectionToggled: onSectionToggled`, where `localSectionIndex` is a `@State private var localSectionIndex: BranchDiffSectionIndex?` set at the same place Task 3 computes the index for the `Render` (so a freshly loaded tab folds before the group has stored the render).

`DocumentGroupView.swift`: at the `DocumentPaneView(` call (line ~210) pass `sectionIndex: tabMemory.sectionIndex(for: document)`, `collapsedSections: tabMemory.collapsedSections(for: document)`, `onSectionToggled: { key in tabMemory.toggleSection(key, for: document) }`.

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
    static func placement(visibleTop: CGFloat, rows: [(minY: CGFloat, maxY: CGFloat)], headerHeight: CGFloat) -> (index: Int, pushOffset: CGFloat)?
}
```

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
        let p = try #require(BranchDiffStickyHeaderView.placement(visibleTop: 300, rows: rows, headerHeight: 30))
        #expect(p.index == 0 && p.pushOffset == 0)
        let q = try #require(BranchDiffStickyHeaderView.placement(visibleTop: 700, rows: rows, headerHeight: 30))
        #expect(q.index == 1 && q.pushOffset == 0)
    }

    @Test("the next heading pushes the pinned header up as it approaches, and takes over once it passes")
    func pushesOut() throws {
        // next heading at 500; visible top 480 → 20pt of room for a 30pt header → pushed up 10
        let p = try #require(BranchDiffStickyHeaderView.placement(visibleTop: 480, rows: rows, headerHeight: 30))
        #expect(p.index == 0 && p.pushOffset == -10)
        // heading exactly at the top edge → it is now the pinned one
        let q = try #require(BranchDiffStickyHeaderView.placement(visibleTop: 500, rows: rows, headerHeight: 30))
        #expect(q.index == 1 && q.pushOffset == 0)
    }

    @Test("a heading exactly at the top edge is not pinned (it is already visible in place)")
    func headingAtTopIsInPlace() {
        // Pinning a heading whose own row is fully visible would draw it twice.
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 100, rows: rows, headerHeight: 30)?.index == 0)
        #expect(BranchDiffStickyHeaderView.placement(visibleTop: 99, rows: rows, headerHeight: 30) == nil)
    }

    @Test("the view hides without a model and exposes a button with the section label") @MainActor
    func viewModelAndAccessibility() {
        let view = BranchDiffStickyHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        #expect(view.isHidden)
        view.model = .init(key: "a.swift", title: "a.swift", added: 3, removed: 1, collapsed: false)
        #expect(!view.isHidden)
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "a.swift, 3 added, 1 removed")
        var activated: String?
        view.onActivate = { activated = $0 }
        _ = view.accessibilityPerformPress()
        #expect(activated == "a.swift")
    }
}
```

Decide the semantics precisely: pinned index = the last row with `row.minY <= visibleTop`; pushOffset = `min(0, nextRow.minY - visibleTop - headerHeight)` when a next row exists, else 0. With `visibleTop == row.minY` the row is at the edge and counts as pinned (test 4 expects index 0 at 100 and nil at 99); the drawn header covers the in-place heading exactly, so nothing shows twice.

- [ ] **Step 2: Run to verify it fails**

Run: `./script/swift-test.sh --filter BranchDiffStickyHeaderTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`BranchDiffStickyHeaderView.swift`: an `NSView` (not flipped) with an `NSTextField` label (font `MarkdownAttributedStringBuilder.sectionHeadingFont()` scaled down: use `NSFont.systemFont(ofSize: 13, weight: .semibold)` so the bar stays 30pt), a chevron `NSImageView`, and two `NSTextField`s for counts right-aligned; `wantsLayer = true`, `layer.backgroundColor = backgroundColor.cgColor`, 1pt bottom rule drawn in `draw(_:)` with `ruleColor`. `mouseDown` → `onActivate?(model.key)`. Accessibility: `isAccessibilityElement = true`, role `.button`, label via `CommentBadgeOverlay.sectionAccessibilityLabel`, value collapsed/expanded, `accessibilityPerformPress()` calls `onActivate`. `model` didSet: `isHidden = model == nil`, refresh the subviews, `needsDisplay = true`. Implement `placement` exactly as specified.

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
        let rows = chrome.map { (minY: $0.rowRect.minY, maxY: $0.rowRect.maxY) }
        guard let placement = BranchDiffStickyHeaderView.placement(
            visibleTop: clip.bounds.minY, rows: rows, headerHeight: BranchDiffStickyHeaderView.height)
        else { header.model = nil; return }
        let section = chrome[placement.index]
        header.model = .init(key: section.key, title: section.key, added: section.added, removed: section.removed, collapsed: section.collapsed)
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
The `title` shown is the section key; strip a trailing `#n` ordinal for display (`key.replacing(/#\d+$/, with: "")`).

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
  - `AwesoMuxApp.showBranchChanges(forPane paneID: TerminalPane.ID, completion: @escaping @MainActor () -> Void = {})`; `showBranchChangesForActivePane()` resolves the active pane and calls it.
  - `DocumentPaneSendBar` new inputs: `var sectionKeys: [String] = []`, `var collapsedSections: Set<String> = []`, `var onSetCollapsedSections: (Set<String>) -> Void = { _ in }`.
  - Pure helper for tests: `enum BranchChangesRefreshPolicy { static func verdict(target: DocumentNudgeTargetResolution, inFlight: Bool) -> Verdict }` with `enum Verdict: Equatable { case ready; case busy; case unavailable(String) }` (the string is the caption).

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

In `BranchChangesOpenerTests.swift` add:
```swift
    @Test("the path model built for an explicit pane uses that pane's directory, not the session's active pane")
    func pathModelUsesExplicitPane() {
        let active = TerminalPane(title: "a", workingDirectory: "/tmp", executionPlan: .local)
        let other = TerminalPane(title: "b", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp")   // use the same fixture helper the file already has for sessions
        // add both panes so `other` is not the active one (use the file's existing layout helpers)
        let model = TerminalPathBarModel.make(pane: other, session: session)
        #expect(model.path == "~")
    }
```
Adapt the session/layout fixture to whatever `BranchChangesOpenerTests` already uses to build a session with panes; the assertion is only that the model reflects `other`.

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

e. `DocumentPaneSendBar`: add `@Environment(\.branchChangesRefresh) private var branchChangesRefresh`, `@State private var refreshInFlight = false`, the three new inputs. Replace the `else if pane.generatedDocumentKind != nil` branch with:
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
            target: session.layout.documentNudgeTarget(for: pane.id), inFlight: refreshInFlight)
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

    private func refresh() {
        guard !refreshInFlight, let branchChangesRefresh,
            case .available(let target) = session.layout.documentNudgeTarget(for: pane.id) else { return }
        refreshInFlight = true
        branchChangesRefresh.run(target.id) { refreshInFlight = false }
    }
```
`SendToAgentButton.Purpose` (line ~724) gains a `.refreshBranchChanges` case; give it the `arrow.clockwise` symbol wherever `Purpose` maps to an icon (read the enum's uses in that struct and mirror `.resumeSession`). If `Purpose` carries no icon, add `systemImage` handling only for this case.

f. `DocumentGroupView.swift` at `DocumentPaneSendBar(`: pass `sectionKeys: tabMemory.sectionIndex(for: document)?.keys ?? []`, `collapsedSections: tabMemory.collapsedSections(for: document)`, `onSetCollapsedSections: { tabMemory.setCollapsedSections($0, for: document) }`.

g. Run `./script/update_string_catalog.sh` and include `Resources/Localizable.xcstrings` in the handoff.

- [ ] **Step 4: Run tests and smoke**

Run: `./script/swift-test.sh --filter BranchChangesRefreshActionTests`, `--filter BranchChangesOpenerTests`, `--filter BranchChangesCompletionTests`. Then `./script/build_and_run.sh`: open branch changes from pane A, focus pane B (different repo or none), press Refresh on the tab: the tab re-renders for pane A's repo; snapshot time updates; folds persist. Close pane A: the button disables with "This tab's terminal was closed". Collapse All / Expand All flip every section.

- [ ] **Step 5: Format and hand off**

`./script/format.sh` on every changed Swift file. Do not commit.

---

### Task 9: Spike: per-line VoiceOver roles (bounded, 45 minutes)

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
