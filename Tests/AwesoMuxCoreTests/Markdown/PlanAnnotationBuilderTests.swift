import Testing
@testable import AwesoMuxCore

@Suite("PlanAnnotation building")
struct PlanAnnotationBuilderTests {
    @Test("AMX span marker stamps runs and aggregates the annotation")
    func spanAnnotation() throws {
        let src = "see <mark>this</mark><!-- AMX id=q3k7 by=user intent=replace: that --> ok"
        let doc = AttributedMarkdownBuilder.build(src)
        let run = try #require(doc.runs.first { $0.markID == "q3k7" })
        #expect(run.text == "this")
        let annotation = try #require(doc.annotation(id: "q3k7"))
        #expect(annotation.author == .user)
        #expect(annotation.intent == .replace)
        #expect(annotation.status == .open)
        #expect(annotation.payload == "that")
        #expect(annotation.anchor == .span)
        #expect(!annotation.isLegacy)
    }

    @Test("own-line AMX marker is a document-level annotation with no runs")
    func documentLevelAnnotation() throws {
        let src = "para one\n\n<!-- AMX id=w8p2 by=codex: rollback is missing -->\n\npara two"
        let doc = AttributedMarkdownBuilder.build(src)
        let annotation = try #require(doc.annotation(id: "w8p2"))
        #expect(annotation.anchor == .document)
        #expect(annotation.payload == "rollback is missing")
        // The marker emits no runs and no extra separator: the rendered text
        // reads as the two paragraphs joined by one block separator.
        #expect(doc.runs.map(\.text).joined() == "para one\n\npara two")
    }

    @Test("document-level replace intent demotes to comment")
    func documentLevelReplaceDemotes() throws {
        let src = "<!-- AMX id=w8p2 by=user intent=replace: whole new plan -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let annotation = try #require(doc.annotation(id: "w8p2"))
        #expect(annotation.intent == .comment)
    }

    @Test("thread notes attach to their annotation in file order")
    func threadNotesAttach() throws {
        let src = """
        <mark>a</mark><!-- AMX id=q3k7 by=user: needs numbers -->

        <!-- AMX re=q3k7 by=claude-code: added benchmarks -->

        <!-- AMX re=q3k7 by=user: thanks, verified -->
        """
        let doc = AttributedMarkdownBuilder.build(src)
        let annotation = try #require(doc.annotation(id: "q3k7"))
        #expect(annotation.notes == [
            .init(author: .claudeCode, payload: "added benchmarks"),
            .init(author: .user, payload: "thanks, verified"),
        ])
    }

    @Test("a note preceding its annotation still attaches")
    func noteBeforeAnnotationAttaches() throws {
        let src = "<!-- AMX re=q3k7 by=codex: early reply -->\n\n<mark>a</mark><!-- AMX id=q3k7 by=user: note -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let annotation = try #require(doc.annotation(id: "q3k7"))
        #expect(annotation.notes == [.init(author: .codex, payload: "early reply")])
    }

    @Test("orphan notes are hidden, not surfaced")
    func orphanNoteHidden() {
        let doc = AttributedMarkdownBuilder.build("<!-- AMX re=gone by=user: reply to nothing -->")
        #expect(doc.annotations.isEmpty)
    }

    @Test("legacy and AMX markers coexist with disjoint ids")
    func legacyAndAMXCoexist() throws {
        let src = "<mark>a</mark><!-- USER COMMENT 1: old --> and <mark>b</mark><!-- AMX id=q3k7 by=user: new -->"
        let doc = AttributedMarkdownBuilder.build(src)
        #expect(doc.annotations.map(\.id) == ["1", "q3k7"])
        let legacy = try #require(doc.annotation(id: "1"))
        #expect(legacy.isLegacy)
        #expect(legacy.author == .user)
        #expect(legacy.payload == "old")
        #expect(doc.displayNumber(for: "1") == 1)
        #expect(doc.displayNumber(for: "q3k7") == 2)
    }

    @Test("the inline open count excludes the document note")
    func openCountSkipsResolved() {
        let src = """
        <mark>a</mark><!-- AMX id=q3k7 by=user: open one -->

        <!-- AMX id=w8p2 by=user status=resolved: handled -->
        """
        let doc = AttributedMarkdownBuilder.build(src)
        #expect(doc.annotations.count == 2)
        #expect(doc.openAnnotationCount == 1)
        #expect(doc.documentNote?.id == "w8p2")
        #expect(doc.resolvedAnnotationIDs.isEmpty)
    }

    @Test("duplicate AMX id keeps the first annotation (first-writer-wins)")
    func duplicateIDFirstWins() throws {
        let src = "<mark>a</mark><!-- AMX id=q3k7 by=user: first --> <mark>b</mark><!-- AMX id=q3k7 by=user: second -->"
        let doc = AttributedMarkdownBuilder.build(src)
        #expect(doc.annotations.count == 1)
        #expect(doc.annotation(id: "q3k7")?.payload == "first")
        #expect(doc.runs.filter { $0.markID == "q3k7" }.map(\.text) == ["a"])
    }

    @Test("a marker separated from its mark is document-level")
    func separatedMarkerIsDocumentLevel() throws {
        let src = "<mark>a</mark> prose <!-- AMX id=q3k7 by=user: note -->"
        let doc = AttributedMarkdownBuilder.build(src)
        let annotation = try #require(doc.annotation(id: "q3k7"))
        #expect(annotation.anchor == .document)
        #expect(doc.runs.allSatisfy { $0.markID == nil })
    }

    @Test("CRLF document markers parse as document-level annotations")
    func crlfDocumentMarkerParses() throws {
        let doc = AttributedMarkdownBuilder.build("text\r\n\r\n<!-- AMX id=q3k7 by=user: note -->\r\n")
        #expect(try #require(doc.annotation(id: "q3k7")).anchor == .document)
    }

    @Test("an ordinary HTML comment block is not an annotation")
    func ordinaryHTMLBlockIgnored() {
        let doc = AttributedMarkdownBuilder.build("<!-- just a comment -->\n\ntext")
        #expect(doc.annotations.isEmpty)
    }

    @Test("a document-level marker inside a blockquote still parses")
    func blockquoteMarkerParses() throws {
        let src = "> quoted text\n>\n> <!-- AMX id=w8p2 by=user: doc note in quote -->\n"
        let annotation = try #require(AttributedMarkdownBuilder.build(src).annotation(id: "w8p2"))
        #expect(annotation.anchor == .document)
        #expect(annotation.payload == "doc note in quote")
    }

    @Test("a document-level marker inside a list item still parses")
    func listItemMarkerParses() throws {
        let src = "- item one\n- <!-- AMX id=w8p2 by=user: doc note in list -->\n- item three\n"
        let annotation = try #require(AttributedMarkdownBuilder.build(src).annotation(id: "w8p2"))
        #expect(annotation.anchor == .document)
    }

    @Test("marker-shaped text inside a code fence never becomes an annotation")
    func fencedMarkerTextIgnored() {
        let src = "```\n<!-- AMX id=fake by=user: example -->\n```\n"
        #expect(AttributedMarkdownBuilder.build(src).annotations.isEmpty)
    }
}
