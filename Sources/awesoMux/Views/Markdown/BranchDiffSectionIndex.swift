import AwesoMuxCore

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
        // ponytail: no per-line numbering yet. A gutter (spec §6) can derive
        // every line's old/new number from `header` plus the same walk that
        // counts lines here; storing tens of thousands of pairs per tab for a
        // feature that does not exist is memory spent on nothing.
    }

    struct Section: Equatable {
        let key: String  // opaque identity, never displayed
        let title: String  // the full heading text, for the sticky header and VoiceOver
        let headingRuns: Range<Int>
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

    /// Keys are unique by construction (`key(keyText:occurrence:)` disambiguates
    /// repeats), so this is a total index of `sections`. Stored rather than
    /// scanned: the attributed-string builder asks once per heading, which was
    /// O(n²) in changed-file count on the main thread (review).
    private let sectionsByKey: [String: Section]

    var keys: [String] { sections.map(\.key) }

    func section(key: String) -> Section? { sectionsByKey[key] }

    /// Hand-written so the compare stays on `sections` alone. `sectionsByKey` is
    /// derived from it, and Array's buffer-identity fast path is what keeps
    /// `MarkdownTextView.updateNSView`'s per-pass index compare near-free.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.sections == rhs.sections }

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

    /// Maximal spans of consecutive level-2 heading runs, in document order —
    /// one span per file heading, including its inline italic status run. Shared
    /// with `MarkdownAttributedStringBuilder.sectionKeysByRun`, which must derive
    /// the SAME spans or a heading silently loses its chrome (review).
    static func headingSpans(in runs: [RenderedRun]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i < runs.count {
            guard case .heading(level: 2) = runs[i].style else { i += 1; continue }
            var end = i
            while end < runs.count, case .heading(level: 2) = runs[end].style { end += 1 }
            spans.append(i..<end)
            i = end
        }
        return spans
    }

    init(document: RenderedDocument) {
        let runs = document.runs
        var sections: [Section] = []
        var occurrences: [String: Int] = [:]
        for heading in Self.headingSpans(in: runs) {
            let slice = runs[heading]
            let keyText = Self.keyText(headingRuns: slice)
            let occurrence = occurrences[keyText, default: 0]
            occurrences[keyText] = occurrence + 1
            let title = slice.map(\.text).joined()
            // The fence, if any, starts after the heading's own block separator.
            var fenceStart = heading.upperBound
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
                        break  // a line break inside the fence
                    default:
                        break scan  // the "\n\n" after the fence, or the next block
                    }
                    fenceEnd += 1
                }
            }
            // A fold removes the heading's separator plus the fence, and keeps
            // the "\n\n" after the fence for whatever follows. A fence-less
            // heading has an empty range and is not foldable.
            let bodyRuns =
                fenceEnd > fenceStart
                ? heading.upperBound..<fenceEnd : heading.upperBound..<heading.upperBound
            sections.append(
                Section(
                    key: Self.key(keyText: keyText, occurrence: occurrence),
                    title: title,
                    headingRuns: heading,
                    bodyRuns: bodyRuns,
                    added: added, removed: removed, hunks: hunks))
        }
        self.sections = sections
        self.sectionsByKey = Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `@@ -a[,b] +c[,d] @@…`; a missing length means 1. Anything else returns
    /// nil — including a combined-diff header, whose `@@@` fails the `"@@ "`
    /// prefix on its third `@`.
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        guard line.hasPrefix("@@ ") else { return nil }
        let parts = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
            let old = range(parts[0].dropFirst()), let new = range(parts[1].dropFirst())
        else { return nil }
        return HunkHeader(oldStart: old.start, oldLength: old.length, newStart: new.start, newLength: new.length)
    }

    private static func range(_ text: Substring) -> (start: Int, length: Int)? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2, let start = Int(pieces[0]), start >= 0 else { return nil }
        if pieces.count == 1 { return (start, 1) }
        guard let length = Int(pieces[1]), length >= 0 else { return nil }
        return (start, length)
    }
}
