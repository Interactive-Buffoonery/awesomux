import Testing
@testable import AwesoMuxCore

// MARK: - MarkdownRenderModelBuilder tests

@Suite("MarkdownRenderModelBuilder")
struct MarkdownRenderModelBuilderTests {

    // MARK: Headings

    @Test("heading level 1")
    func headingLevel1() {
        let blocks = MarkdownRenderModelBuilder.build("# Hi")
        #expect(blocks == [.heading(level: 1, [.text("Hi")])])
    }

    @Test("heading level 2")
    func headingLevel2() {
        let blocks = MarkdownRenderModelBuilder.build("## Section")
        #expect(blocks == [.heading(level: 2, [.text("Section")])])
    }

    // MARK: Paragraph / inlines

    @Test("bold and italic in paragraph")
    func boldAndItalic() {
        let blocks = MarkdownRenderModelBuilder.build("**bold** and *it*")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph, got \(blocks[0])")
            return
        }
        #expect(inlines.contains(.strong([.text("bold")])))
        #expect(inlines.contains(.text(" and ")))
        #expect(inlines.contains(.emphasis([.text("it")])))
    }

    @Test("inline code")
    func inlineCode() {
        let blocks = MarkdownRenderModelBuilder.build("Use `foo()` here.")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph"); return
        }
        #expect(inlines.contains(.code("foo()")))
    }

    @Test("link with destination")
    func linkWithDestination() {
        let blocks = MarkdownRenderModelBuilder.build("[label](https://example.com)")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph"); return
        }
        let link = inlines.first
        guard case let .link(destination, children) = link else {
            Issue.record("Expected link inline, got \(String(describing: link))")
            return
        }
        #expect(destination == "https://example.com")
        #expect(children == [.text("label")])
    }

    @Test("strikethrough")
    func strikethrough() {
        // CommonMark GFM extension: ~~text~~
        let blocks = MarkdownRenderModelBuilder.build("~~gone~~")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph"); return
        }
        #expect(inlines.contains(.strikethrough([.text("gone")])))
    }

    // MARK: Code block

    @Test("fenced code block with language")
    func fencedCodeBlock() {
        let blocks = MarkdownRenderModelBuilder.build("```swift\ncode\n```")
        #expect(blocks == [.codeBlock(language: "swift", code: "code")])
    }

    @Test("fenced code block without language")
    func fencedCodeBlockNoLanguage() {
        let blocks = MarkdownRenderModelBuilder.build("```\nhello\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "hello")])
    }

    // MARK: Lists

    @Test("unordered list with two items")
    func unorderedList() {
        let blocks = MarkdownRenderModelBuilder.build("- alpha\n- beta")
        #expect(blocks.count == 1)
        guard case let .unorderedList(items) = blocks[0] else {
            Issue.record("Expected unorderedList"); return
        }
        #expect(items.count == 2)
        #expect(items[0] == [.paragraph([.text("alpha")])])
        #expect(items[1] == [.paragraph([.text("beta")])])
    }

    @Test("ordered list with non-default start")
    func orderedList() {
        let blocks = MarkdownRenderModelBuilder.build("3. first\n4. second")
        #expect(blocks.count == 1)
        guard case let .orderedList(start, items) = blocks[0] else {
            Issue.record("Expected orderedList"); return
        }
        #expect(start == 3)
        #expect(items.count == 2)
    }

    // MARK: Block quote

    @Test("block quote")
    func blockQuote() {
        let blocks = MarkdownRenderModelBuilder.build("> hello")
        #expect(blocks.count == 1)
        guard case let .blockQuote(children) = blocks[0] else {
            Issue.record("Expected blockQuote"); return
        }
        #expect(children == [.paragraph([.text("hello")])])
    }

    // MARK: Thematic break

    @Test("thematic break")
    func thematicBreak() {
        let blocks = MarkdownRenderModelBuilder.build("---")
        #expect(blocks == [.thematicBreak])
    }

    @Test("YAML front matter is not rendered as primary markdown blocks")
    func yamlFrontMatterSkipped() {
        let blocks = MarkdownRenderModelBuilder.build("""
        ---
        name: awesomux-awesomeness
        description: Publish or update plans
        ---

        # awesomux-awesomeness publishing
        """)
        #expect(blocks == [.heading(level: 1, [.text("awesomux-awesomeness publishing")])])
    }

    // MARK: Anti-regression: <mark> stripping

    @Test("<mark> tag is stripped — inner text survives, no literal tag in output")
    func markTagStripped() {
        let blocks = MarkdownRenderModelBuilder.build("Plain <mark>x</mark> text.")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph"); return
        }

        // The tag strings must never appear.
        let allText = inlines.compactMap { if case let .text(s) = $0 { return s } else { return nil } }.joined()
        #expect(!allText.contains("<mark>"), "Literal <mark> found in output: \(allText)")
        #expect(!allText.contains("</mark>"), "Literal </mark> found in output: \(allText)")

        // The inner content "x" must be present.
        #expect(inlines.contains(.text("x")), "Inner text 'x' not found in inlines: \(inlines)")
    }

    // MARK: Soft break / hard break

    @Test("soft break maps to .softBreak, not .lineBreak")
    func softBreakMapToSoftBreak() {
        // A bare newline in a paragraph is a SoftBreak in CommonMark.
        let blocks = MarkdownRenderModelBuilder.build("line one\nline two")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph, got \(blocks[0])"); return
        }
        // The soft break must produce .softBreak, not .lineBreak.
        #expect(inlines.contains(.softBreak), "Expected .softBreak in: \(inlines)")
        #expect(!inlines.contains(.lineBreak), "Unexpected .lineBreak in: \(inlines)")
    }

    @Test("hard break maps to .lineBreak")
    func hardBreakMapsToLineBreak() {
        // Two trailing spaces before a newline is a hard (LineBreak) in CommonMark.
        let blocks = MarkdownRenderModelBuilder.build("line one  \nline two")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph, got \(blocks[0])"); return
        }
        // The hard break must produce .lineBreak, not .softBreak.
        #expect(inlines.contains(.lineBreak), "Expected .lineBreak in: \(inlines)")
        #expect(!inlines.contains(.softBreak), "Unexpected .softBreak in: \(inlines)")
    }

    @Test("soft-wrapped two-line paragraph joins with space not newline")
    func softWrappedParagraphJoinsWithSpace() {
        let blocks = MarkdownRenderModelBuilder.build("hello\nworld")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph, got \(blocks[0])"); return
        }
        // Inlines must be [text("hello"), .softBreak, text("world")].
        // The .softBreak must NOT be a .lineBreak — the view renders softBreak as " ".
        let expected: [MarkdownInline] = [.text("hello"), .softBreak, .text("world")]
        #expect(inlines == expected, "Got \(inlines)")
    }

    // MARK: Anti-regression: HTML comment dropped

    @Test("HTML comment is dropped — comment text never visible")
    func htmlCommentDropped() {
        let blocks = MarkdownRenderModelBuilder.build("Visible<!-- hidden comment -->")
        #expect(blocks.count == 1)
        guard case let .paragraph(inlines) = blocks[0] else {
            Issue.record("Expected paragraph"); return
        }

        // The visible part must survive.
        #expect(inlines.contains(.text("Visible")), "Visible text not found in inlines: \(inlines)")

        // The word "hidden" must appear nowhere in any inline's text.
        let allText = inlines.compactMap { if case let .text(s) = $0 { return s } else { return nil } }.joined()
        #expect(!allText.contains("hidden"), "Comment text leaked into output: \(allText)")
    }
}
