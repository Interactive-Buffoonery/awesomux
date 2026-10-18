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

    @Test(arguments: [
        ("[Approve](https://evil.example)<script>", "refs/remotes/origin/main", "awesomux", nil as String?, nil as String?),
        (
            "fea\u{202E}ture", "refs/remotes/origin/ma\u{200B}in", "awe\u{2066}somux", "# feature\n",
            "Compared with `origin/main` in `awesomux`."
        ),
        ("fix-`quoting`", "refs/remotes/origin/ma`in", "awesomux", "# fix-\\`quoting\\`\n", "Compared with ``origin/ma`in`` in"),
    ])
    func sanitizesHeaderInjection(branch: String, baseRef: String, repository: String, prefix: String?, comparison: String?) {
        let text = render(Data("+x\n".utf8), branch: branch, baseRef: baseRef, repositoryName: repository)
        #expect(!text.contains("["))
        #expect(!text.contains("<script>"))
        #expect(
            !text.unicodeScalars.contains {
                (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || $0.value == 0x200B
            })
        if let prefix { #expect(text.hasPrefix(prefix)) }
        if let comparison { #expect(text.contains(comparison)) }
    }

    @Test(arguments: [
        ("+a\u{1B}[31mred\u{0}\u{7}\u{7F}\tb\n+second\n", "+a[31mred\tb\n+second\n"),
        ("+safe\u{202E}hidden\u{2066}isolate\u{200B}zero\n", "+safe<U+202E>hidden<U+2066>isolate<U+200B>zero\n"),
    ])
    func sanitizesDiffBody(input: String, expected: String) throws {
        let body = try fencedBody(of: render(input))
        #expect(body == expected)
        let unsafe: Set<UInt32> = [0, 7, 0x1B, 0x7F, 0x202E, 0x2066, 0x200B]
        #expect(!body.unicodeScalars.contains { unsafe.contains($0.value) })
    }

    @Test(arguments: [
        (
            """
            diff --git "a/[x](https://evil.example)<b>.txt" "b/[x](https://evil.example)<b>.txt"
            index 1111111..2222222 100644
            --- "a/[x](https://evil.example)<b>.txt"
            +++ "b/[x](https://evil.example)<b>.txt"
            @@ -1 +1 @@
            -a
            +b

            """, "x(https://evil.example)b.txt"
        ),
        (
            """
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

            """, "c\\`d\\*e\\_f.txt — _renamed from a\\`b.txt_"
        ),
    ])
    func inertPathHeading(diff: String, expected: String) throws {
        #expect(try #require(sections(of: render(diff)).first?.heading) == expected)
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

    @Test("a bidi override smuggled through octal escapes is still neutralized")
    func octalEscapedBidiIsNeutralized() throws {
        // U+202E is E2 80 AE; escaped, the sanitizer's first pass never sees it.
        let diff = "diff --git \"a/x\\342\\200\\256y.txt\" \"b/x\\342\\200\\256y.txt\"\nBinary files a/x and b/x differ\n"
        let text = render(diff)
        #expect(!text.unicodeScalars.contains { $0.value == 0x202E })
        #expect(sections(of: text).first?.heading == "xU+202Ey.txt")
    }

    @Test("the budget cuts on a whole line inside a file and drops a file it cannot start")
    func budgetCutsWithinAndBetweenFiles() throws {
        var diff = ""
        for file in 1...3 {
            diff += "diff --git a/f\(file).txt b/f\(file).txt\nindex 1..2 100644\n--- a/f\(file).txt\n+++ b/f\(file).txt\n@@ -1 +1,40 @@\n"
            diff += (1...40).map { "+f\(file) line \($0) with some trailing text" }.joined(separator: "\n") + "\n"
        }
        let text = render(diff, budgetBytes: 1400)
        #expect(text.utf8.count <= 1400)
        #expect(text.contains(Self.truncationNotice))
        let originalLines = Set(diff.split(separator: "\n").map(String.init))
        for section in sections(of: text) {
            #expect(section.body.hasSuffix("\n"))
            for line in section.body.split(separator: "\n") { #expect(originalLines.contains(String(line))) }
        }
    }

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

    @Test("a control byte between two backtick runs cannot smuggle a longer run past the fence")
    func runCountingFollowsTheKeptBytes() throws {
        // `` + NUL + `` renders as four adjacent backticks. A count taken over
        // the INPUT sees two runs of two and would size the fence at three.
        let text = render("+``\u{0}``\n")
        #expect(text.contains("\n`````diff\n"))
    }

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

    @Test("an empty body that was cut short is never reported as agreement")
    func cutBodyDoesNotClaimAgreement() {
        let text = render("", isTruncated: true)
        #expect(!text.contains("This branch matches"))
        #expect(text.contains(Self.truncationNotice))
    }

    @Test("an AMX marker inside the diff is not parsed back as an annotation")
    func fencedAnnotationMarkersAreInert() {
        let text = render("+<!-- AMX id=q3k7 by=user: smuggled -->\n")
        #expect(text.contains("<!-- AMX id=q3k7 by=user: smuggled -->"))
        #expect(PlanAnnotationWriter.existingIDs(in: text).isEmpty)
    }
}
