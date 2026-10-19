import Testing
@testable import AwesoMuxCore

@Suite("MarkdownFrontMatter")
struct MarkdownFrontMatterTests {
    @Test(
        arguments: [
            ("---\nname: example\ndescription: test\n---\n\n# Title", 0..<40, "name: example\ndescription: test", "\n# Title"),
            ("---\n# Title", nil, nil, nil),
            ("# Title\n\n---\nname: example\n---", nil, nil, nil),
            ("\u{FEFF}---\nname: example\n---\nBody", 0..<25, "name: example", "Body"),
            ("---\nname: example\n...\nBody", 0..<22, "name: example", "Body"),
            ("---\nname: example\n---\r", 0..<22, "name: example", ""),
            ("---\nname: example\n...\r", 0..<22, "name: example", ""),
            ("---\r\nname: example\n...\r\nBody\r\n", 0..<24, "name: example", "Body\r\n"),
            ("---\r\n---\r\nBody", 0..<10, "", "Body"),
            ("---\r\nname: example\r\nBody", nil, nil, nil),
        ] as [(String, Range<Int>?, String?, String?)])
    func frontMatter(source: String, range: Range<Int>?, metadata: String?, body: String?) {
        let parsed = MarkdownFrontMatter.parse(source)
        #expect(parsed?.fullRange == range)
        #expect(parsed?.metadataText == metadata)
        #expect(parsed?.body.utf8.map { $0 } == body?.utf8.map { $0 })
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
}
