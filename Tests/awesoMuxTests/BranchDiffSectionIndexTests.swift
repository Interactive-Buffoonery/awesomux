import Foundation
import Testing

@testable import awesoMux
@testable import AwesoMuxCore

@Suite("Branch diff section index")
struct BranchDiffSectionIndexTests {
    private func build(_ md: String) -> (RenderedDocument, BranchDiffSectionIndex) {
        let doc = AttributedMarkdownBuilder.build(md)
        return (doc, BranchDiffSectionIndex(document: doc))
    }

    /// Same fixtures as `BranchChangesRendererTests`: an unlocalized `Chrome`
    /// (deliberately `internal`, hence `@testable import AwesoMuxCore` above)
    /// and an identity built from the same defaults that suite's `render` helper uses.
    private func render(_ diff: String, budgetBytes: Int) -> String {
        BranchChangesRenderer.render(
            diff: Data(diff.utf8),
            identity: BranchChangesIdentity(
                gitBranch: "feature/x",
                baseRef: "refs/remotes/origin/main",
                repositoryName: "awesomux"
            )!,
            isTruncated: false,
            chrome: .unlocalizedFallback,
            budgetBytes: budgetBytes
        )
    }

    @Test("one section per H2 heading; the H1 is skipped; a fence-less heading is a section with no body")
    func sectionsFollowHeadings() {
        let (doc, index) = build(
            """
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
    func renameOnlySection() {
        let diff =
            "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\ndiff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let markdown = render(diff, budgetBytes: 100_000)
        let (_, index) = build(markdown)
        #expect(index.sections.count == 2)
        #expect(index.sections[0].title.hasPrefix("new.txt"))
        #expect(!index.sections[0].isFoldable)
        #expect(index.sections[1].isFoldable && index.sections[1].added == 1)
    }

    @Test("the closing truncation notice is outside the last section's body, so folding the last file keeps it visible")
    func truncationNoticeSurvivesFold() throws {
        let diff = (0..<2).map {
            "diff --git a/f\($0).txt b/f\($0).txt\n--- a/f\($0).txt\n+++ b/f\($0).txt\n@@ -1 +1 @@\n-old\n+"
                + String(repeating: "x", count: 300) + "\n"
        }.joined()
        let markdown = render(diff, budgetBytes: 450)
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
        #expect(doc.runs.contains { $0.style == .code })  // the overflow run exists
        #expect(index.sections[0].added == cap + 5)
        #expect(index.sections[0].removed == 0)
    }

    @Test("hunk headers parse, including -0,0 and a missing length")
    func hunkHeaderParsing() {
        typealias H = BranchDiffSectionIndex.HunkHeader
        #expect(
            BranchDiffSectionIndex.parseHunkHeader("@@ -344,10 +345,29 @@ func x")
                == H(oldStart: 344, oldLength: 10, newStart: 345, newLength: 29))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -0,0 +1,5 @@") == H(oldStart: 0, oldLength: 0, newStart: 1, newLength: 5))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ -7 +7 @@") == H(oldStart: 7, oldLength: 1, newStart: 7, newLength: 1))
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@ garbage @@") == nil)
        #expect(BranchDiffSectionIndex.parseHunkHeader("@@@ -1,2 -3,4 +5,6 @@@") == nil)
    }

    @Test("an unparsable hunk header yields a nil header and still counts its lines; hunks are recorded in order")
    func unparsableHunkStillCounts() {
        let (doc, index) = build("## f\n\n```diff\n@@ nope @@\n+a\n-b\n@@ -50,1 +60,1 @@\n b\n```\n")
        let section = index.sections[0]
        #expect(section.added == 1 && section.removed == 1)
        #expect(section.hunks.count == 2)
        #expect(section.hunks[0].header == nil)
        #expect(doc.runs[section.hunks[0].runIndex].style == .diffLine(.hunk))
        #expect(section.hunks[1].header?.oldStart == 50 && section.hunks[1].header?.newStart == 60)
        #expect(doc.runs[section.hunks[1].runIndex].style == .diffLine(.hunk))
    }

    @Test("heading spans group consecutive heading runs, italic status included, one span per file")
    func headingSpansGroupOneSpanPerHeading() {
        // The status suffix is a second, italic heading run of the SAME heading;
        // the builder and the index both key off these spans, so a drift here
        // silently strips a file's chrome.
        let (doc, _) = build("## a.swift — _new file_\n\n```diff\n+x\n```\n\n## b.swift\n\n```diff\n+y\n```\n")
        let spans = BranchDiffSectionIndex.headingSpans(in: doc.runs)
        #expect(spans.count == 2)
        #expect(spans[0].count > 1, "the italic status run belongs to the first heading's span")
        #expect(doc.runs[spans[0]].contains { $0.italic })
        #expect(doc.runs[spans[1]].map(\.text).joined() == "b.swift")
        #expect(BranchDiffSectionIndex.headingSpans(in: []).isEmpty)
    }
}
