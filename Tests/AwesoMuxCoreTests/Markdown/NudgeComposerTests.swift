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

    @Test("verified runtime providers map to exact annotation authors")
    func providerAuthorMapping() {
        #expect(PlanAnnotationAuthor(agentKind: .claudeCode) == .claudeCode)
        #expect(PlanAnnotationAuthor(agentKind: .codex) == .codex)
        #expect(PlanAnnotationAuthor(agentKind: .pi) == .pi)
        #expect(PlanAnnotationAuthor(agentKind: .openCode) == .opencode)
        #expect(PlanAnnotationAuthor(agentKind: .grok) == nil)
        #expect(PlanAnnotationAuthor(agentKind: .shell) == nil)
    }

    @Test("provider-aware handoff names the provider and exact reply id")
    func providerIdentity() {
        let text = NudgeComposer.text(
            AnnotationHandoffInput(
                provider: .pi,
                displayPath: "plan.md",
                openAnnotationIDs: ["q3k7"]
            )
        )
        #expect(text.contains("You are Pi"))
        #expect(text.contains("provider id pi"))
        #expect(text.contains("by=pi"))
    }

    @Test("selected annotation is first and is not repeated in the open list")
    func selectedAnnotationOrdering() {
        let text = NudgeComposer.text(
            AnnotationHandoffInput(
                provider: .claudeCode,
                displayPath: "plan.md",
                selectedAnnotationID: "q3k7",
                openAnnotationIDs: ["w8p2", "q3k7", "w8p2"]
            )
        )
        #expect(text.contains("Prioritize annotation q3k7 first"))
        #expect(text.contains("Other open annotation ids, in document order: w8p2"))
        #expect(!text.contains("w8p2, q3k7"))
    }

    @Test("handoff includes ids but never annotation payloads")
    func idsWithoutPayloads() {
        let text = NudgeComposer.text(
            AnnotationHandoffInput(
                provider: .codex,
                displayPath: "plan.md",
                selectedAnnotationID: "q3k7",
                openAnnotationIDs: ["q3k7", "w8p2"]
            )
        )
        #expect(text.contains("q3k7"))
        #expect(text.contains("w8p2"))
        #expect(!text.contains("secret review payload"))
    }

    @Test("provider-aware handoff has no trailing newline")
    func providerHandoffHasNoTrailingNewline() {
        let text = NudgeComposer.text(
            AnnotationHandoffInput(provider: .opencode, displayPath: "any.md")
        )
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
