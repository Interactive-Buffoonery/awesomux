import Testing
@testable import AwesoMuxCore

@Suite("NudgeComposer")
struct NudgeComposerTests {
    @Test("nudge text contains the display path")
    func containsDisplayPath() {
        let text = NudgeComposer.text(displayPath: "Sources/Foo.swift")
        #expect(text.contains("Sources/Foo.swift"))
    }

    @Test("nudge text references USER COMMENT marker convention")
    func containsUserCommentConvention() {
        let text = NudgeComposer.text(displayPath: "any.md")
        #expect(text.contains("USER COMMENT"))
    }

    @Test("nudge text teaches the AMX convention and single document note")
    func containsAMXConvention() {
        let text = NudgeComposer.text(displayPath: "any.md")
        #expect(text.contains("AMX id="))
        #expect(text.contains("status=resolved"))
        #expect(text.contains("AMX re="))
        #expect(text.contains("intent=replace"))
        #expect(text.contains("intent=delete"))
        #expect(text.contains("single AMX marker"))
        #expect(text.contains("document note has no replies"))
    }

    @Test("nudge text references the mark highlight syntax")
    func containsMarkSyntax() {
        let text = NudgeComposer.text(displayPath: "any.md")
        #expect(text.contains("<mark>"))
    }

    @Test("nudge text has no trailing newline (staged, not sent)")
    func noTrailingNewline() {
        let text = NudgeComposer.text(displayPath: "any.md")
        #expect(!text.hasSuffix("\n"))
    }

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
