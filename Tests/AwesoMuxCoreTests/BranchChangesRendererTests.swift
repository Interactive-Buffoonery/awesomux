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
        #expect(text.contains("Branch `HEAD`"))
    }

    @Test("chrome values reach the header inside run-aware code spans")
    func codeSpansContainBackticksInBranchNames() {
        let text = render(Data("+x\n".utf8), branch: "fix-`quoting`")
        // A single-backtick span would end at the branch name's first backtick.
        #expect(text.contains("Branch `` fix-`quoting` ``"))
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
        #expect(text.contains("Branch `feature`"))
        #expect(text.contains("Compared with `origin/main`"))
        #expect(text.contains("Repository `awesomux`"))
    }

    // MARK: - Annotation smuggling

    @Test("an AMX marker inside the diff is not parsed back as an annotation")
    func fencedAnnotationMarkersAreInert() {
        let text = render("+<!-- AMX id=q3k7 by=user: smuggled -->\n")
        #expect(text.contains("<!-- AMX id=q3k7 by=user: smuggled -->"))
        #expect(PlanAnnotationWriter.existingIDs(in: text).isEmpty)
    }
}
