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

    @Test("parses CRLF front matter without changing body bytes")
    func crlfFrontMatterPreservesBodyBytes() throws {
        let source = "---\r\nname: example\r\n---\r\nBody\r\n"
        let frontMatter = try #require(MarkdownFrontMatter.parse(source))
        #expect(frontMatter.metadataText == "name: example")
        #expect(frontMatter.body.utf8.elementsEqual("Body\r\n".utf8))
        #expect(frontMatter.fullRange == 0..<"---\r\nname: example\r\n---\r\n".utf8.count)

        let document = AttributedMarkdownBuilder.build(source)
        let bodyRuns = document.runs.filter { $0.style == .body && $0.text == "Body" }

        #expect(document.runs.filter { $0.style == .frontMatter }.map(\.text) == ["name: example"])
        #expect(bodyRuns.count == 1)
        #expect(bodyRuns.first?.sourceRange?.lowerBound == frontMatter.fullRange.upperBound)
    }

    @Test("a final closing delimiter can end in a lone CR", arguments: ["---", "..."])
    func finalClosingDelimiterWithLoneCarriageReturn(closer: String) throws {
        let source = "---\nname: example\n\(closer)\r"
        let frontMatter = try #require(MarkdownFrontMatter.parse(source))
        #expect(frontMatter.metadataText == "name: example")
        #expect(frontMatter.body.isEmpty)
        #expect(frontMatter.fullRange == 0..<source.utf8.count)
    }

    @Test("mixed line endings retain exact metadata range and body bytes")
    func mixedLineEndingsPreserveSourceBytes() throws {
        let prefix = "---\r\nname: example\n...\r\n"
        let source = prefix + "Body\r\n"

        let frontMatter = try #require(MarkdownFrontMatter.parse(source))

        #expect(frontMatter.metadataText == "name: example")
        #expect(frontMatter.fullRange == 0..<prefix.utf8.count)
        #expect(frontMatter.body.utf8.elementsEqual("Body\r\n".utf8))
    }

    @Test("empty and unclosed front matter remain distinct")
    func emptyAndUnclosedFrontMatter() throws {
        let empty = "---\r\n---\r\nBody"
        let frontMatter = try #require(MarkdownFrontMatter.parse(empty))
        #expect(frontMatter.metadataText.isEmpty)
        #expect(frontMatter.body == "Body")
        #expect(frontMatter.fullRange == 0..<"---\r\n---\r\n".utf8.count)
        #expect(MarkdownFrontMatter.parse("---\r\nname: example\r\nBody") == nil)
    }
}
