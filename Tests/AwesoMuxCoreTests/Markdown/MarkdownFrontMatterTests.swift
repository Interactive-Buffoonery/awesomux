import Testing
@testable import AwesoMuxCore

@Suite("MarkdownFrontMatter")
struct MarkdownFrontMatterTests {
    @Test("detects leading YAML front matter and preserves the body")
    func detectsLeadingYamlFrontMatter() throws {
        let source = """
        ---
        name: example
        description: test
        ---

        # Title
        """
        let frontMatter = try #require(MarkdownFrontMatter.parse(source))
        #expect(frontMatter.metadataText == "name: example\ndescription: test")
        #expect(frontMatter.body == "\n# Title")
        #expect(frontMatter.fullRange == 0..<"---\nname: example\ndescription: test\n---\n".utf8.count)
    }

    @Test("does not treat a lone thematic break as front matter")
    func loneThematicBreakIgnored() {
        #expect(MarkdownFrontMatter.parse("---\n# Title") == nil)
    }

    @Test("does not detect delimiters after document content")
    func nonLeadingDelimiterIgnored() {
        let source = """
        # Title

        ---
        name: example
        ---
        """
        #expect(MarkdownFrontMatter.parse(source) == nil)
    }

    @Test("allows UTF-8 BOM before opening delimiter")
    func bomBeforeOpeningDelimiter() throws {
        let source = "\u{FEFF}---\nname: example\n---\nBody"
        let frontMatter = try #require(MarkdownFrontMatter.parse(source))
        #expect(frontMatter.metadataText == "name: example")
        #expect(frontMatter.body == "Body")
    }

    @Test("allows YAML dot closing delimiter")
    func dotClosingDelimiter() throws {
        let source = """
        ---
        name: example
        ...
        Body
        """
        let frontMatter = try #require(MarkdownFrontMatter.parse(source))
        #expect(frontMatter.metadataText == "name: example")
        #expect(frontMatter.body == "Body")
    }
}
