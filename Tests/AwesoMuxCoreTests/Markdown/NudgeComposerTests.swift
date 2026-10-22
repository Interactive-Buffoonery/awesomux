import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("NudgeComposer")
struct NudgeComposerTests {
    @Test(arguments: [
        ("notes; touch /tmp/pwned #.md", "'notes; touch /tmp/pwned #.md'"),
        ("a'b", "'a'\\''b'"),
    ])
    func quotedPaths(path: String, expected: String) {
        #expect(NudgeComposer.shellSingleQuoted(path) == expected)
        #expect(NudgeComposer.text(displayPath: path).contains(expected))
    }

    @Test(arguments: [
        "/tmp/worktree-one/notes.md",
        "/tmp/review Sarah's café.md", "/tmp/literal%00.md",
    ])
    func admittedPaths(path: String) throws {
        let admitted = try #require(NudgeComposer.absoluteLocalPath(for: URL(fileURLWithPath: path)))
        #expect(admitted == path)
        let prompt = NudgeComposer.text(AnnotationHandoffInput(provider: .codex, displayPath: admitted))
        #expect(prompt.contains(NudgeComposer.shellSingleQuoted(path)))
        #expect(RichInputStaging.stagedPayload(prompt) == prompt)
        #expect(!prompt.hasSuffix("\n"))
        if path == "/tmp/worktree-one/notes.md" {
            #expect(prompt != NudgeComposer.text(AnnotationHandoffInput(provider: .codex, displayPath: "/tmp/worktree-two/notes.md")))
        }
    }

    @Test(
        arguments: [
            "\n", "\r", "\t", "\u{1B}", "\u{7F}", "\u{85}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", nil,
        ] as [String?])
    func refusedPaths(character: String?) throws {
        let url =
            try character.map { URL(fileURLWithPath: "/tmp/evil\($0).md") }
            ?? #require(URL(string: "https://example.invalid/notes.md"))
        #expect(NudgeComposer.absoluteLocalPath(for: url) == nil)
    }

}
