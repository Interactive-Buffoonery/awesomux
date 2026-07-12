@testable import AwesoMuxCore
import Testing

@Suite("PlanAnnotationWriter")
struct PlanAnnotationWriterTests {
    @Test("existingIDs collects AMX and legacy ids")
    func existingIDs() {
        let src = "<mark>a</mark><!-- AMX id=q3k7 by=user: x --> <mark>b</mark><!-- USER COMMENT 2: y -->"
        #expect(PlanAnnotationWriter.existingIDs(in: src) == ["q3k7", "2"])
    }

    @Test("insertingAnnotation wraps the span and round-trips through the builder")
    func insertSpan() throws {
        let src = "see this ok"
        let (out, id) = try #require(PlanAnnotationWriter.insertingAnnotation(
            in: src, span: 4 ..< 8, author: .user, intent: .replace, payload: "that"
        ))
        let doc = AttributedMarkdownBuilder.build(out)
        let annotation = try #require(doc.annotation(id: id))
        #expect(annotation.intent == .replace)
        #expect(annotation.payload == "that")
        #expect(annotation.anchor == .span)
        #expect(doc.runs.first { $0.markID == id }?.text == "this")
        #expect(doc.runs.map(\.text).joined() == "see this ok")
    }

    @Test("generated insert id avoids existing legacy ids")
    func insertAvoidsExistingIDs() throws {
        let src = "<mark>a</mark><!-- USER COMMENT 3: x --> more text here"
        let (_, id) = try #require(PlanAnnotationWriter.insertingAnnotation(
            in: src, span: 45 ..< 49, author: .user, payload: "n"
        ))
        #expect(id != "3")
        #expect(id.utf8.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") })
    }

    @Test("appendingDocumentAnnotation lands own-line and parses as document-level")
    func appendDocument() throws {
        let (out, id) = try #require(PlanAnnotationWriter.appendingDocumentAnnotation(
            in: "plan text\n", author: .codex, payload: "overall: needs rollback"
        ))
        #expect(out == "plan text\n\n<!-- AMX id=\(id) by=codex: overall: needs rollback -->\n")
        let annotation = try #require(AttributedMarkdownBuilder.build(out).annotation(id: id))
        #expect(annotation.anchor == .document)
        #expect(annotation.payload == "overall: needs rollback")
    }

    @Test("document annotations preserve paragraph breaks in a single-line marker")
    func appendMultilineDocument() throws {
        let payload = "First paragraph.\n\nSecond paragraph."
        let result = try #require(PlanAnnotationWriter.appendingDocumentAnnotation(
            in: "# Plan\n", author: .user, payload: payload, id: "w8p2"
        ))

        #expect(result.source.contains("encoding=lines"))
        #expect(AttributedMarkdownBuilder.build(result.source).annotation(id: "w8p2")?.payload == payload)
    }

    @Test("a second document note is refused")
    func refusesSecondDocumentNote() {
        let source = "# Plan\n\n<!-- AMX id=w8p2 by=user: overall note -->\n"

        #expect(PlanAnnotationWriter.appendingDocumentAnnotation(
            in: source,
            author: .user,
            payload: "another note"
        ) == nil)
    }

    @Test("updatingAnnotation flips status without touching surroundings")
    func statusFlip() throws {
        let src = "pre <mark>a</mark><!-- AMX id=q3k7 by=user: note --> post"
        let out = try #require(PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: src) {
            $0.status = .resolved
        })
        #expect(out == "pre <mark>a</mark><!-- AMX id=q3k7 by=user status=resolved: note --> post")
    }

    @Test("editing a resolved annotation reopens it")
    func editReopensResolvedAnnotation() throws {
        let source = "<!-- AMX id=w8p2 by=user status=resolved: old note -->\n"
        let output = try #require(PlanAnnotationWriter.updatingAnnotation(id: "w8p2", in: source) {
            $0.payload = "updated note"
        })

        let annotation = try #require(AttributedMarkdownBuilder.build(output).documentNote)
        #expect(annotation.payload == "updated note")
        #expect(annotation.status == .open)
    }

    @Test("updatingAnnotation upgrades a legacy marker to AMX form, keeping its id")
    func legacyUpgrade() throws {
        let src = "<mark>a</mark><!-- USER COMMENT 3: old \\| note --> tail"
        let out = try #require(PlanAnnotationWriter.updatingAnnotation(id: "3", in: src) {
            $0.payload = "new note"
        })
        #expect(out == "<mark>a</mark><!-- AMX id=3 by=user: new note --> tail")
        let doc = AttributedMarkdownBuilder.build(out)
        #expect(doc.annotation(id: "3")?.payload == "new note")
        #expect(doc.annotation(id: "3")?.isLegacy == false)
    }

    @Test("updatingAnnotation returns nil for an unknown id")
    func updateUnknownID() {
        #expect(PlanAnnotationWriter.updatingAnnotation(id: "none", in: "text") { _ in } == nil)
    }

    @Test("appendingNote after a span marker stays inline and attaches")
    func noteAfterSpanMarker() throws {
        let src = "<mark>a</mark><!-- AMX id=q3k7 by=user: note --> tail"
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "q3k7", in: src, author: .claudeCode, payload: "done"
        ))
        #expect(out == "<mark>a</mark><!-- AMX id=q3k7 by=user: note --><!-- AMX re=q3k7 by=claude-code: done --> tail")
        let annotation = try #require(AttributedMarkdownBuilder.build(out).annotation(id: "q3k7"))
        #expect(annotation.notes == [.init(author: .claudeCode, payload: "done")])
    }

    @Test("an empty span is refused, fail-closed")
    func emptySpanIsRefused() {
        #expect(PlanAnnotationWriter.insertingAnnotation(in: "hello", span: 2 ..< 2, author: .user, payload: "x") == nil)
    }

    @Test("replying to a resolved annotation reopens it in the same write")
    func replyReopensResolvedParent() throws {
        let src = "<mark>a</mark><!-- AMX id=q3k7 by=user status=resolved: note --> tail"
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "q3k7", in: src, author: .user, payload: "actually, revert"
        ))
        let annotation = try #require(AttributedMarkdownBuilder.build(out).annotation(id: "q3k7"))
        #expect(annotation.status == .open)
        #expect(annotation.notes == [.init(author: .user, payload: "actually, revert")])
    }

    @Test("thread replies preserve paragraph breaks")
    func appendMultilineReply() throws {
        let source = "<!-- AMX id=w8p2 by=user: root -->\n"
        let payload = "Reply one.\n\nReply two."
        let output = try #require(PlanAnnotationWriter.appendingNote(
            to: "w8p2", in: source, author: .user, payload: payload
        ))

        #expect(output.contains("encoding=lines"))
        #expect(AttributedMarkdownBuilder.build(output).annotation(id: "w8p2")?.notes.first?.payload == payload)
    }

    @Test("appending notes preserves their file order")
    func notesAppendInOrder() throws {
        let first = "<mark>a</mark><!-- AMX id=q3k7 by=user: note -->"
        let second = try #require(PlanAnnotationWriter.appendingNote(
            to: "q3k7", in: first, author: .codex, payload: "first reply"
        ))
        let third = try #require(PlanAnnotationWriter.appendingNote(
            to: "q3k7", in: second, author: .user, payload: "second reply"
        ))
        #expect(AttributedMarkdownBuilder.build(third).annotation(id: "q3k7")?.notes.map(\.payload) == ["first reply", "second reply"])
    }

    @Test("oversized payloads are refused before a writer can create an inert marker")
    func oversizedPayloadIsRefused() {
        let payload = String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1)
        #expect(PlanAnnotationWriter.insertingAnnotation(in: "text", span: 0 ..< 1, author: .user, payload: payload) == nil)
        #expect(PlanAnnotationWriter.appendingDocumentAnnotation(in: "text", author: .user, payload: payload) == nil)
        #expect(PlanAnnotationWriter.appendingNote(to: "gone", in: "text", author: .user, payload: payload) == nil)
    }

    @Test("appendingNote after an own-line marker takes its own line and still parses")
    func noteAfterDocumentMarker() throws {
        let src = "text\n\n<!-- AMX id=w8p2 by=user: doc note -->\n"
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "w8p2", in: src, author: .codex, payload: "ack"
        ))
        let annotation = try #require(AttributedMarkdownBuilder.build(out).annotation(id: "w8p2"))
        #expect(annotation.anchor == .document)
        #expect(annotation.notes == [.init(author: .codex, payload: "ack")])
    }

    @Test("appendingNote after an own-line marker in a CRLF file takes its own line")
    func noteAfterDocumentMarkerCRLF() throws {
        // The \r before the \n is line-ending whitespace; treating it as
        // content made the marker read as inline and glued the reply onto the
        // same line, where the combined text no longer parsed as two markers.
        let src = "text\r\n\r\n<!-- AMX id=w8p2 by=user: doc note -->\r\n"
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "w8p2", in: src, author: .codex, payload: "ack"
        ))
        #expect(out.contains(" -->\n<!-- AMX re=w8p2"))
        let annotation = try #require(AttributedMarkdownBuilder.build(out).annotation(id: "w8p2"))
        #expect(annotation.notes == [.init(author: .codex, payload: "ack")])
    }

    @Test("appendingNote falls back to end-of-file when the marker is gone")
    func noteFallbackAppends() throws {
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "gone", in: "text\n", author: .user, payload: "late reply"
        ))
        #expect(out == "text\n\n<!-- AMX re=gone by=user: late reply -->\n")
    }

    @Test("removingAnnotation unwraps the mark and removes thread notes")
    func removeSpanWithNotes() throws {
        let src = "see <mark>this</mark><!-- AMX id=q3k7 by=user: note --><!-- AMX re=q3k7 by=codex: reply --> ok"
        let out = try #require(PlanAnnotationWriter.removingAnnotation(id: "q3k7", in: src))
        #expect(out == "see this ok")
    }

    @Test("removingAnnotation drops an own-line document marker without a blank gap")
    func removeDocumentLevel() throws {
        let src = "para one\n\n<!-- AMX id=w8p2 by=user: doc note -->\n<!-- AMX re=w8p2 by=codex: reply -->\n\npara two\n"
        let out = try #require(PlanAnnotationWriter.removingAnnotation(id: "w8p2", in: src))
        let doc = AttributedMarkdownBuilder.build(out)
        #expect(doc.annotations.isEmpty)
        #expect(doc.runs.map(\.text).joined() == "para one\n\npara two")
    }

    @Test("removingAnnotation returns nil for an unknown id")
    func removeUnknownID() {
        #expect(PlanAnnotationWriter.removingAnnotation(id: "none", in: "text") == nil)
    }

    @Test("removal of the second of two annotations leaves the first intact")
    func removalStaysLocal() throws {
        let src = "<mark>a</mark><!-- AMX id=aa11 by=user: one --> mid <mark>b</mark><!-- AMX id=bb22 by=user: two -->"
        let out = try #require(PlanAnnotationWriter.removingAnnotation(id: "bb22", in: src))
        #expect(out == "<mark>a</mark><!-- AMX id=aa11 by=user: one --> mid b")
    }

    // MARK: Adversarial hardening (review convergence)

    @Test("marker-shaped text inside a code fence is never a write target")
    func fencedExampleTextIsImmune() {
        let src = """
        Real note <mark>a</mark><!-- AMX id=q3k7 by=user: real -->

        ```
        <!-- AMX id=fake by=user: example text in docs -->
        ```
        """
        #expect(PlanAnnotationWriter.existingIDs(in: src) == ["q3k7"])
        #expect(PlanAnnotationWriter.removingAnnotation(id: "fake", in: src) == nil)
        #expect(PlanAnnotationWriter.updatingAnnotation(id: "fake", in: src) { _ in } == nil)
    }

    @Test("duplicate ids refuse every write, fail-closed")
    func duplicateIDsRefuseWrites() {
        let src = """
        <!-- AMX id=q3k7 by=user: smuggled -->

        <mark>x</mark><!-- AMX id=q3k7 by=user: real -->
        """
        #expect(PlanAnnotationWriter.removingAnnotation(id: "q3k7", in: src) == nil)
        #expect(PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: src) { $0.status = .resolved } == nil)
        #expect(PlanAnnotationWriter.appendingNote(to: "q3k7", in: src, author: .user, payload: "x") == nil)
    }

    @Test("replying to a legacy annotation upgrades the parent to AMX form")
    func replyUpgradesLegacyParent() throws {
        let src = "<mark>x</mark><!-- USER COMMENT 3: old --> tail"
        let out = try #require(PlanAnnotationWriter.appendingNote(
            to: "3", in: src, author: .claudeCode, payload: "done"
        ))
        #expect(out == "<mark>x</mark><!-- AMX id=3 by=user: old --><!-- AMX re=3 by=claude-code: done --> tail")
        let doc = AttributedMarkdownBuilder.build(out)
        let annotation = try #require(doc.annotation(id: "3"))
        #expect(annotation.isLegacy == false)
        #expect(annotation.notes == [.init(author: .claudeCode, payload: "done")])
    }

    @Test("a document-level marker inside a blockquote is a real write target")
    func blockquoteMarkerIsWritable() throws {
        let src = "> context\n>\n> <!-- AMX id=w8p2 by=user: rollback missing -->\n"
        let out = try #require(PlanAnnotationWriter.updatingAnnotation(id: "w8p2", in: src) {
            $0.status = .resolved
        })
        #expect(out.contains("> <!-- AMX id=w8p2 by=user status=resolved: rollback missing -->"))
    }
}
