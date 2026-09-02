import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("BranchChangesRenderer")
struct BranchChangesRendererTests {

    private static let truncationNotice = "**This diff is incomplete.**"

    private func render(
        _ diff: String,
        isTruncated: Bool = false,
        budgetBytes: Int = BranchChangesRenderer.budgetBytes
    ) -> String {
        render(Data(diff.utf8), isTruncated: isTruncated, budgetBytes: budgetBytes)
    }

    private func render(
        _ diff: Data,
        isTruncated: Bool = false,
        budgetBytes: Int = BranchChangesRenderer.budgetBytes,
        branch: String? = "feature/x",
        baseRef: String = "refs/remotes/origin/main",
        repositoryName: String = "awesomux"
    ) -> String {
        BranchChangesRenderer.render(
            diff: diff,
            identity: BranchChangesIdentity(
                gitBranch: branch,
                baseRef: baseRef,
                repositoryName: repositoryName
            )!,
            isTruncated: isTruncated,
            chrome: .unlocalizedFallback,
            budgetBytes: budgetBytes
        )
    }

    /// The fenced body, without the fences.
    private func fencedBody(of text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let openIndex = try #require(
            lines.firstIndex {
                $0.count > 4 && $0.hasSuffix("diff") && $0.dropLast(4).allSatisfy { $0 == "`" }
            })
        let fence = String(lines[openIndex].dropLast(4))
        let closeIndex = try #require(lines[(openIndex + 1)...].firstIndex { $0 == fence })
        return lines[(openIndex + 1)..<closeIndex].joined(separator: "\n") + "\n"
    }

    /// Every `## heading` in document order, paired with the fenced body that
    /// follows it (empty when the section has no fence).
    private func sections(of text: String) -> [(heading: String, body: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [(heading: String, body: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("## ") {
                result.append((heading: String(line.dropFirst(3)), body: ""))
            } else if line.hasSuffix("diff"), line.dropLast(4).allSatisfy({ $0 == "`" }), line.count > 4 {
                let fence = String(line.dropLast(4))
                var body = ""
                index += 1
                while index < lines.count, lines[index] != fence {
                    body += lines[index] + "\n"
                    index += 1
                }
                if result.isEmpty { result.append((heading: "", body: body)) } else { result[result.count - 1].body = body }
            }
            index += 1
        }
        return result
    }

    // MARK: - File sections

    @Test("each file becomes a heading over its own fence, and git's header lines are gone")
    func filesBecomeSections() throws {
        let diff = """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 85d721e1..822571cd 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1,2 +1,2 @@
             context
            -old
            +new
            diff --git a/README.md b/README.md
            index 1111111..2222222 100644
            --- a/README.md
            +++ b/README.md
            @@ -1 +1 @@
            -a
            +b

            """
        let text = render(diff)
        let sections = sections(of: text)
        #expect(sections.map(\.heading) == ["Sources/A.swift", "README.md"])
        #expect(sections[0].body == "@@ -1,2 +1,2 @@\n context\n-old\n+new\n")
        #expect(sections[1].body == "@@ -1 +1 @@\n-a\n+b\n")
        #expect(!text.contains("diff --git"))
        #expect(!text.contains("index 85d721e1"))
        #expect(!text.contains("--- a/"))
        #expect(!text.contains("+++ b/"))
    }

    @Test("new, deleted, and renamed files say so in the heading")
    func fileStatusReachesTheHeading() throws {
        let diff = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..e69de29
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hello
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index e69de29..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old/name.txt b/new/name.txt
            similarity index 90%
            rename from old/name.txt
            rename to new/name.txt
            index 1111111..2222222 100644
            --- a/old/name.txt
            +++ b/new/name.txt
            @@ -1 +1 @@
            -x
            +y
            diff --git a/moved.txt b/relocated.txt
            similarity index 100%
            rename from moved.txt
            rename to relocated.txt

            """
        let text = render(diff)
        let sections = sections(of: text)
        #expect(
            sections.map(\.heading) == [
                "new.txt — _new file_",
                "gone.txt — _deleted_",
                "new/name.txt — _renamed from old/name.txt_",
                "relocated.txt — _renamed from moved.txt_",
            ])
        // A pure rename has no hunks and gets no fence.
        #expect(sections[3].body.isEmpty)
        #expect(text.hasSuffix("relocated.txt — _renamed from moved.txt_\n\n"))
    }

    @Test("binary and mode-only entries keep git's line in the fence rather than an empty section")
    func binaryAndModeLinesStayVisible() throws {
        let diff = """
            diff --git a/icon.png b/icon.png
            index 1111111..2222222 100644
            Binary files a/icon.png and b/icon.png differ
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755

            """
        let text = render(diff)
        let sections = sections(of: text)
        #expect(sections.map(\.heading) == ["icon.png", "run.sh"])
        #expect(sections[0].body == "Binary files a/icon.png and b/icon.png differ\n")
        #expect(sections[1].body == "old mode 100644\nnew mode 100755\n")
    }

    @Test("a hunk line that spells a file header does not start a section")
    func hunkContentCannotForgeAFileBoundary() throws {
        let diff = """
            diff --git a/notes.md b/notes.md
            index 1111111..2222222 100644
            --- a/notes.md
            +++ b/notes.md
            @@ -1 +1,3 @@
            +diff --git a/evil b/evil
            +--- a/evil
            ++++ b/evil

            """
        let text = render(diff)
        let sections = sections(of: text)
        #expect(sections.map(\.heading) == ["notes.md"])
        #expect(sections[0].body == "@@ -1 +1,3 @@\n+diff --git a/evil b/evil\n+--- a/evil\n++++ b/evil\n")
    }

    @Test("markdown syntax in a path cannot become chrome, and a quoted path loses its quotes")
    func pathHeadingIsInert() throws {
        let diff = """
            diff --git "a/[x](https://evil.example)<b>.txt" "b/[x](https://evil.example)<b>.txt"
            index 1111111..2222222 100644
            --- "a/[x](https://evil.example)<b>.txt"
            +++ "b/[x](https://evil.example)<b>.txt"
            @@ -1 +1 @@
            -a
            +b

            """
        let text = render(diff)
        let heading = try #require(sections(of: text).first?.heading)
        #expect(heading == "x(https://evil.example)b.txt")
    }

    @Test("a mode change with content still folds index and ---/+++ into the heading")
    func modeLinesDoNotEndTheHeader() throws {
        let diff = """
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755
            index 1111111..2222222
            --- a/run.sh
            +++ b/run.sh
            @@ -1 +1 @@
            -old
            +new

            """
        let sections = sections(of: render(diff))
        #expect(sections.map(\.heading) == ["run.sh"])
        #expect(sections[0].body == "old mode 100644\nnew mode 100755\n@@ -1 +1 @@\n-old\n+new\n")
    }

    @Test("git's C-quoted paths decode to the filename, in every header line that carries one")
    func quotedPathsDecode() throws {
        let diff = """
            diff --git "a/caf\\303\\251.png" "b/caf\\303\\251.png"
            index 1111111..2222222 100644
            Binary files "a/caf\\303\\251.png" and "b/caf\\303\\251.png" differ
            diff --git "a/na\\303\\257ve.txt" "b/na\\303\\257ve.txt"
            new file mode 100644
            index 0000000..ce01362
            --- /dev/null
            +++ "b/na\\303\\257ve.txt"
            @@ -0,0 +1 @@
            +hello
            diff --git "a/sp ace\\t.txt" "b/re named.txt"
            similarity index 100%
            rename from "sp ace\\t.txt"
            rename to "re named.txt"

            """
        let sections = sections(of: render(diff))
        #expect(
            sections.map(\.heading) == [
                "café.png",
                "naïve.txt — _new file_",
                "re named.txt — _renamed from sp ace\t.txt_",
            ])
    }

    @Test("a bidi override smuggled through octal escapes is still neutralized")
    func octalEscapedBidiIsNeutralized() throws {
        // U+202E is E2 80 AE; escaped, the sanitizer's first pass never sees it.
        let diff = "diff --git \"a/x\\342\\200\\256y.txt\" \"b/x\\342\\200\\256y.txt\"\nBinary files a/x and b/x differ\n"
        let text = render(diff)
        #expect(!text.unicodeScalars.contains { $0.value == 0x202E })
        #expect(sections(of: text).first?.heading == "xU+202Ey.txt")
    }

    @Test("a copied file is headed by its destination")
    func copyToNamesTheDestination() throws {
        let diff = """
            diff --git a/source.txt b/copied.txt
            similarity index 100%
            copy from source.txt
            copy to copied.txt

            """
        #expect(sections(of: render(diff)).map(\.heading) == ["copied.txt"])
    }

    @Test("markdown punctuation in a path is escaped so a rename cannot form a code span or emphasis")
    func headingPunctuationIsEscaped() throws {
        let diff = """
            diff --git a/a`b.txt b/c`d*e_f.txt
            similarity index 90%
            rename from a`b.txt
            rename to c`d*e_f.txt
            index 1111111..2222222 100644
            --- a/a`b.txt
            +++ b/c`d*e_f.txt
            @@ -1 +1 @@
            -x
            +y

            """
        let heading = try #require(sections(of: render(diff)).first?.heading)
        #expect(heading == "c\\`d\\*e\\_f.txt — _renamed from a\\`b.txt_")
    }

    @Test("a section that only kept its hunk header is dropped, not shown as an empty change")
    func hunkHeaderAloneIsNotAChange() throws {
        let long = String(repeating: "x", count: 2000)
        let diff = "diff --git a/f.txt b/f.txt\nindex 1..2 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n+\(long)\n"
        let text = render(diff, budgetBytes: 1200)
        #expect(sections(of: text).isEmpty)
        #expect(!text.contains("f.txt"))
        #expect(text.contains(Self.truncationNotice))
    }

    @Test("a truncated diff with nothing to show carries the notice once, not twice")
    func emptyTruncatedBodyHasOneNotice() {
        let text = render("", isTruncated: true)
        #expect(text.components(separatedBy: Self.truncationNotice).count == 2)
    }

    @Test("lines before any file header render in a headingless fence")
    func preambleLinesAreNotLost() throws {
        let text = render("* Unmerged path conflict.txt\n")
        let sections = sections(of: text)
        #expect(sections.count == 1)
        #expect(sections[0].heading.isEmpty)
        #expect(sections[0].body == "* Unmerged path conflict.txt\n")
    }

    @Test("the budget cuts on a whole line inside a file and drops a file it cannot start")
    func budgetCutsWithinAndBetweenFiles() throws {
        var diff = ""
        for file in 1...3 {
            diff += "diff --git a/f\(file).txt b/f\(file).txt\nindex 1..2 100644\n--- a/f\(file).txt\n+++ b/f\(file).txt\n@@ -1 +1,40 @@\n"
            diff += (1...40).map { "+f\(file) line \($0) with some trailing text" }.joined(separator: "\n") + "\n"
        }
        let text = render(diff, budgetBytes: 1400)
        let sections = sections(of: text)
        #expect(sections.count == 1)
        #expect(sections[0].heading == "f1.txt")
        #expect(sections[0].body.hasSuffix("\n"))
        #expect(!sections[0].body.contains("f1 line 40"))
        #expect(!text.contains("f2.txt"))
        #expect(text.contains(Self.truncationNotice))
        #expect(text.hasSuffix("\(Self.truncationNotice)\n\n"))
        #expect(text.utf8.count <= 1400)
    }

    // MARK: - Fence sizing

    @Test(
        "the fence always exceeds the body's longest backtick run",
        arguments: [0, 1, 2, 3, 4, 10, 40]
    )
    func fenceWidensPastTheLongestRun(runLength: Int) throws {
        let run = String(repeating: "`", count: runLength)
        let text = render("+let x = \(run)code\(run)\n")
        let expected = max(3, runLength + 1)
        #expect(text.contains("\n\(String(repeating: "`", count: expected))diff\n"))
        // One shorter must NOT appear as the opener, or a body-borne run could
        // close the fence early.
        #expect(!text.contains("\n\(String(repeating: "`", count: expected - 1))diff\n"))
    }

    @Test("a backtick run past the cap cuts the body and reports it incomplete")
    func pathologicalBacktickRunIsCutRatherThanFenced() throws {
        let run = String(repeating: "`", count: BranchChangesRenderer.maximumBacktickRun + 5)
        let text = render("+keep me\n+\(run)\n")
        #expect(text.contains("+keep me"))
        #expect(!text.contains(run))
        #expect(text.contains(Self.truncationNotice))
    }

    // MARK: - Body sanitization

    @Test("C0 controls and ESC are stripped, newlines and tabs survive")
    func stripsControlBytes() throws {
        let text = render("+a\u{1B}[31mred\u{0}\u{7}\u{7F}\tb\n+second\n")
        let body = try fencedBody(of: text)
        #expect(body == "+a[31mred\tb\n+second\n")
        #expect(!body.unicodeScalars.contains { $0.value == 0x1B })
    }

    @Test("a control byte between two backtick runs cannot smuggle a longer run past the fence")
    func runCountingFollowsTheKeptBytes() throws {
        // `` + NUL + `` renders as four adjacent backticks. A count taken over
        // the INPUT sees two runs of two and would size the fence at three.
        let text = render("+``\u{0}``\n")
        #expect(text.contains("\n`````diff\n"))
    }

    @Test("bidi and zero-width controls are rendered as visible codepoint tokens")
    func unsafeUnicodeIsVisible() throws {
        let text = render("+safe\u{202E}hidden\u{2066}isolate\u{200B}zero\n")
        let body = try fencedBody(of: text)
        #expect(body.contains("safe<U+202E>hidden<U+2066>isolate<U+200B>zero"))
        let escapedValues: Set<UInt32> = [0x202E, 0x2066, 0x200B]
        #expect(!body.unicodeScalars.contains { escapedValues.contains($0.value) })
    }

    // MARK: - Truncation

    @Test("a truncated diff says so above the fence and again below it")
    func truncationNoticeAppearsOnBothSidesOfTheFence() throws {
        let diff = (1...400).map { "+line \($0)" }.joined(separator: "\n") + "\n"
        let text = render(diff, budgetBytes: 900)
        let fenceStart = try #require(text.range(of: "\n```diff\n"))
        #expect(text[..<fenceStart.lowerBound].contains(Self.truncationNotice))
        #expect(text.hasSuffix("\(Self.truncationNotice)\n\n"))
        #expect(!text.contains("+line 400"))
    }

    @Test("the runner's own truncation flag is enough, even when the budget is not reached")
    func upstreamTruncationFlagAlonePropagates() throws {
        let text = render("+one line\n", isTruncated: true)
        let fenceStart = try #require(text.range(of: "\n```diff\n"))
        #expect(text[..<fenceStart.lowerBound].contains(Self.truncationNotice))
        #expect(text.hasSuffix("\(Self.truncationNotice)\n\n"))
    }

    @Test("an upstream cut drops its torn last line, not just the budget's")
    func upstreamTruncationCutsOnALineBoundary() throws {
        // The runner's cap is below the render budget, so this is the ordinary
        // truncation: the body fits, and its final line is still half a line.
        let text = render("+kept line\n+torn line that git nev", isTruncated: true)
        let body = try fencedBody(of: text)
        #expect(body == "+kept line\n")
        #expect(!text.contains("git nev"))
        let fenceStart = try #require(text.range(of: "\n```diff\n"))
        #expect(text[..<fenceStart.lowerBound].contains(Self.truncationNotice))
        #expect(text.hasSuffix("\(Self.truncationNotice)\n\n"))
    }

    @Test("an upstream cut that landed on a newline keeps its complete last line")
    func upstreamTruncationOnALineBoundaryKeepsTheFinalLine() throws {
        let text = render("+first\n+second\n", isTruncated: true)
        let body = try fencedBody(of: text)
        #expect(body == "+first\n+second\n")
        let fenceStart = try #require(text.range(of: "\n```diff\n"))
        #expect(text[..<fenceStart.lowerBound].contains(Self.truncationNotice))
        #expect(text.hasSuffix("\(Self.truncationNotice)\n\n"))
    }

    @Test("a complete diff never carries the incomplete notice")
    func completeDiffIsNotMarkedIncomplete() {
        let text = render("+one\n+two\n")
        #expect(!text.contains(Self.truncationNotice))
    }

    @Test("truncation drops the trailing partial line rather than showing half of it")
    func truncationCutsOnALineBoundary() throws {
        let lines = (1...60).map { "+line \($0) with some trailing text" }
        let text = render(lines.joined(separator: "\n") + "\n", budgetBytes: 1000)
        let body = try fencedBody(of: text)
        #expect(body.hasSuffix("\n"))
        let rendered = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(!rendered.isEmpty)
        let whole = Set(lines)
        #expect(rendered.allSatisfy { whole.contains($0) })
    }

    // MARK: - Budget

    @Test("invalid UTF-8 tripling in size still lands under the viewer's cap")
    func replacementCharacterExpansionStaysWithinTheDocumentCap() {
        // Every 0xFF becomes a three-byte U+FFFD, so 1 MiB of these bytes is
        // 3 MiB of output — twice the budget and above the viewer's own cap.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1024 * 1024)
        for index in 0..<(1024 * 1024) {
            bytes.append(index % 32 == 31 ? UInt8(ascii: "\n") : 0xFF)
        }
        let text = render(Data(bytes))
        #expect(text.utf8.count <= DocumentURLValidator.maxFileSizeBytes)
        #expect(text.utf8.count <= BranchChangesRenderer.budgetBytes)
        #expect(text.contains(Self.truncationNotice))
    }

    // MARK: - Empty

    @Test("an empty diff is an answer, not a fence")
    func emptyDiffNamesTheBase() {
        let text = render("")
        // Named as the tab names it — the ref namespace is ceremony in a
        // sentence, and the identity is the one place that decides.
        #expect(text.contains("This branch matches origin/main."))
        #expect(!text.contains("```diff"))
        #expect(!text.contains(Self.truncationNotice))
    }

    @Test("an empty body that was cut short is never reported as agreement")
    func cutBodyDoesNotClaimAgreement() {
        let text = render("", isTruncated: true)
        #expect(!text.contains("This branch matches"))
        #expect(text.contains(Self.truncationNotice))
    }

    // MARK: - Header

    @Test("a detached HEAD is named, not blank")
    func detachedHeadIsNamedHEAD() {
        let text = render(Data("+x\n".utf8), branch: nil)
        #expect(text.hasPrefix("# HEAD\n"))
    }

    @Test("the heading is the branch itself, and the comparison line names base and repository as code")
    func headerNamesBranchBaseAndRepository() {
        let text = render(Data("+x\n".utf8))
        #expect(text.hasPrefix("# feature/x\n\nCompared with `origin/main` in `awesomux`.\n\n_Snapshot taken just now."))
    }

    @Test("a backtick in a branch name is escaped in the heading, and a ref's reaches a run-aware code span")
    func backticksInNamesReadAsThemselves() {
        let text = render(Data("+x\n".utf8), branch: "fix-`quoting`", baseRef: "refs/remotes/origin/ma`in")
        #expect(text.hasPrefix("# fix-\\`quoting\\`\n"))
        // A single-backtick span would end at the ref's own backtick.
        #expect(text.contains("Compared with ``origin/ma`in`` in"))
    }

    @Test("markdown syntax in a branch name cannot become chrome")
    func headerStripsLinkAndHTMLSyntax() {
        let text = render(
            Data("+x\n".utf8),
            branch: "[Approve](https://evil.example)<script>"
        )
        #expect(!text.contains("["))
        #expect(!text.contains("<script>"))
    }

    @Test("spoofing scalars are stripped from the header, not just Markdown syntax")
    func headerSanitizesBidiAndZeroWidthScalars() {
        // A right-to-left override reverses everything after it on the line, so
        // a branch or repository name carrying one can rewrite the labels
        // awesoMux wrote around it. Zero-width joiners hide the difference
        // between two names entirely. `inlineCode` defends the Markdown grammar
        // and would pass both through.
        let text = render(
            Data("+x\n".utf8),
            branch: "fea\u{202E}ture",
            baseRef: "refs/remotes/origin/ma\u{200B}in",
            repositoryName: "awe\u{2066}somux"
        )
        #expect(!text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
        #expect(!text.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
        #expect(!text.unicodeScalars.contains { $0.value == 0x200B })
        #expect(text.hasPrefix("# feature\n"))
        #expect(text.contains("Compared with `origin/main` in `awesomux`."))
    }

    // MARK: - Annotation smuggling

    @Test("an AMX marker inside the diff is not parsed back as an annotation")
    func fencedAnnotationMarkersAreInert() {
        let text = render("+<!-- AMX id=q3k7 by=user: smuggled -->\n")
        #expect(text.contains("<!-- AMX id=q3k7 by=user: smuggled -->"))
        #expect(PlanAnnotationWriter.existingIDs(in: text).isEmpty)
    }
}
