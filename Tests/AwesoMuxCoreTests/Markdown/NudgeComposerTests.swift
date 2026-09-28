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
}
