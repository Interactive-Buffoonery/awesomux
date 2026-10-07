import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("NudgeComposer")
struct NudgeComposerTests {
    @Test("a path with shell metacharacters is single-quoted, not left injectable")
    func shellMetacharsAreQuoted() {
        let text = NudgeComposer.text(displayPath: "notes; touch /tmp/pwned #.md")
        // The path appears wrapped in single quotes so a shell treats it as one inert
        // literal rather than running the embedded command.
        #expect(text.contains("'notes; touch /tmp/pwned #.md'"))
    }

    @Test("an embedded single quote is escaped with the '\\'' idiom")
    func embeddedSingleQuoteIsEscaped() {
        let quoted = NudgeComposer.shellSingleQuoted("a'b")
        #expect(quoted == "'a'\\''b'")
    }

    @Test("local handoff paths stay exact through staging or are refused")
    func localHandoffPathAdmission() throws {
        let paths = [
            "/tmp/worktree-one/notes.md",
            "/tmp/worktree-two/notes.md",
            "/tmp/review Sarah's café.md",
            "/tmp/literal%00.md",
        ]
        var prompts: [String] = []
        for path in paths {
            let admitted = try #require(NudgeComposer.absoluteLocalPath(for: URL(fileURLWithPath: path)))
            #expect(admitted == path)
            let prompt = NudgeComposer.text(AnnotationHandoffInput(provider: .codex, displayPath: admitted))
            #expect(prompt.contains(NudgeComposer.shellSingleQuoted(path)))
            #expect(RichInputStaging.stagedPayload(prompt) == prompt)
            #expect(!prompt.hasSuffix("\n"))
            prompts.append(prompt)
        }
        #expect(prompts[0] != prompts[1])

        // Multiline staging permits LF/TAB, but accepting them in a file path
        // would let a different terminal input cross the handoff boundary.
        let unsafe = [
            "\n", "\r", "\t", "\u{1B}", "\u{7F}", "\u{85}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        ]
        for character in unsafe {
            let fileURL = URL(fileURLWithPath: "/tmp/evil\(character).md")
            #expect(NudgeComposer.absoluteLocalPath(for: fileURL) == nil)
        }
        let remoteURL = try #require(URL(string: "https://example.invalid/notes.md"))
        #expect(NudgeComposer.absoluteLocalPath(for: remoteURL) == nil)
    }
}
