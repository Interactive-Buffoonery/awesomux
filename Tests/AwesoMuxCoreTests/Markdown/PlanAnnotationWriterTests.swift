import Testing
@testable import AwesoMuxCore

@Suite("PlanAnnotationWriter")
struct PlanAnnotationWriterTests {
    enum Operation { case resolve, edit, reply, remove, document }

    private func apply(_ operation: Operation, source: String, id: String, author: PlanAnnotationAuthor = .user, payload: String) -> String?
    {
        switch operation {
        case .resolve: return PlanAnnotationWriter.updatingAnnotation(id: id, in: source) { $0.status = .resolved }
        case .edit: return PlanAnnotationWriter.updatingAnnotation(id: id, in: source) { $0.payload = payload }
        case .reply: return PlanAnnotationWriter.appendingNote(to: id, in: source, author: author, payload: payload)
        case .remove: return PlanAnnotationWriter.removingAnnotation(id: id, in: source)
        case .document:
            return PlanAnnotationWriter.appendingDocumentAnnotation(in: source, author: author, payload: payload, id: id)?.source
        }
    }

    @Test(arguments: [
        (
            "pre <mark>a</mark><!-- AMX id=q3k7 by=user: note --> post", Operation.resolve, "q3k7", PlanAnnotationAuthor.user, "",
            "pre <mark>a</mark><!-- AMX id=q3k7 by=user status=resolved: note --> post"
        ),
        (
            "<mark>a</mark><!-- USER COMMENT 3: old \\| note --> tail", .edit, "3", .user, "new note",
            "<mark>a</mark><!-- AMX id=3 by=user: new note --> tail"
        ),
        (
            "<mark>a</mark><!-- AMX id=q3k7 by=user: note --> tail", .reply, "q3k7", .claudeCode, "done",
            "<mark>a</mark><!-- AMX id=q3k7 by=user: note --><!-- AMX re=q3k7 by=claude-code: done --> tail"
        ),
        ("text\n", .reply, "gone", .user, "late reply", "text\n\n<!-- AMX re=gone by=user: late reply -->\n"),
        (
            "see <mark>this</mark><!-- AMX id=q3k7 by=user: note --><!-- AMX re=q3k7 by=codex: reply --> ok", .remove, "q3k7", .user, "",
            "see this ok"
        ),
        (
            "<mark>a</mark><!-- AMX id=aa11 by=user: one --> mid <mark>b</mark><!-- AMX id=bb22 by=user: two -->", .remove, "bb22", .user,
            "", "<mark>a</mark><!-- AMX id=aa11 by=user: one --> mid b"
        ),
        (
            "<mark>x</mark><!-- USER COMMENT 3: old --> tail", .reply, "3", .claudeCode, "done",
            "<mark>x</mark><!-- AMX id=3 by=user: old --><!-- AMX re=3 by=claude-code: done --> tail"
        ),
        (
            "plan text\n", .document, "w8p2", .codex, "overall: needs rollback",
            "plan text\n\n<!-- AMX id=w8p2 by=codex: overall: needs rollback -->\n"
        ),
        (
            "> context\n>\n> <!-- AMX id=w8p2 by=user: rollback missing -->\n", .resolve, "w8p2", .user, "",
            "> context\n>\n> <!-- AMX id=w8p2 by=user status=resolved: rollback missing -->\n"
        ),
        (
            "text\n\n<!-- AMX id=w8p2 by=user: doc note -->\n", .reply, "w8p2", .codex, "ack",
            "text\n\n<!-- AMX id=w8p2 by=user: doc note -->\n<!-- AMX re=w8p2 by=codex: ack -->\n"
        ),
    ])
    func exactOperations(source: String, operation: Operation, id: String, author: PlanAnnotationAuthor, payload: String, expected: String)
        throws
    {
        let output = try #require(apply(operation, source: source, id: id, author: author, payload: payload))
        #expect(output == expected)
        let annotation = AttributedMarkdownBuilder.build(output).annotation(id: id)
        if operation == .document || (operation == .reply && id == "w8p2") {
            #expect(annotation?.anchor == .document)
        }
        if operation == .edit || operation == .document {
            #expect(annotation?.payload == payload)
            #expect(annotation?.isLegacy == false)
        }
        if operation == .reply && id != "gone" {
            #expect(annotation?.notes == [.init(author: author, payload: payload)])
            #expect(annotation?.isLegacy == false)
        }
    }

    enum Refusal: CaseIterable { case secondDocument, unknownUpdate, unknownRemoval, emptySpan, oversized, duplicate }

    @Test(arguments: Refusal.allCases)
    func refusedWrites(reason: Refusal) {
        switch reason {
        case .secondDocument:
            #expect(
                PlanAnnotationWriter.appendingDocumentAnnotation(
                    in: "# Plan\n\n<!-- AMX id=w8p2 by=user: overall note -->\n", author: .user, payload: "another note") == nil)
        case .unknownUpdate:
            #expect(PlanAnnotationWriter.updatingAnnotation(id: "none", in: "text") { _ in } == nil)
        case .unknownRemoval:
            #expect(PlanAnnotationWriter.removingAnnotation(id: "none", in: "text") == nil)
        case .emptySpan:
            #expect(PlanAnnotationWriter.insertingAnnotation(in: "hello", span: 2..<2, author: .user, payload: "x") == nil)
        case .oversized:
            let payload = String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1)
            #expect(PlanAnnotationWriter.insertingAnnotation(in: "text", span: 0..<1, author: .user, payload: payload) == nil)
            #expect(PlanAnnotationWriter.appendingDocumentAnnotation(in: "text", author: .user, payload: payload) == nil)
            #expect(PlanAnnotationWriter.appendingNote(to: "gone", in: "text", author: .user, payload: payload) == nil)
        case .duplicate:
            let source = "<!-- AMX id=q3k7 by=user: smuggled -->\n\n<mark>x</mark><!-- AMX id=q3k7 by=user: real -->"
            #expect(PlanAnnotationWriter.removingAnnotation(id: "q3k7", in: source) == nil)
            #expect(PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: source) { $0.status = .resolved } == nil)
            #expect(PlanAnnotationWriter.appendingNote(to: "q3k7", in: source, author: .user, payload: "x") == nil)
        }
    }

    @Test(arguments: [
        ("<!-- AMX id=w8p2 by=user status=resolved: old note -->\n", Operation.edit, "w8p2", "updated note"),
        ("<mark>a</mark><!-- AMX id=q3k7 by=user status=resolved: note --> tail", .reply, "q3k7", "actually, revert"),
    ])
    func reopensResolved(source: String, operation: Operation, id: String, payload: String) throws {
        let output = try #require(apply(operation, source: source, id: id, payload: payload))
        let annotation = try #require(AttributedMarkdownBuilder.build(output).annotation(id: id))
        #expect(annotation.status == .open)
        if operation == .edit {
            #expect(annotation.payload == payload)
            #expect(annotation.anchor == .document)
        } else {
            #expect(annotation.notes == [.init(author: .user, payload: payload)])
        }
    }

    @Test(arguments: [
        ("# Plan\n", Operation.document, "w8p2", ["First paragraph.\n\nSecond paragraph."]),
        ("<!-- AMX id=w8p2 by=user: root -->\n", .reply, "w8p2", ["Reply one.\n\nReply two."]),
        ("<mark>a</mark><!-- AMX id=q3k7 by=user: note -->", .reply, "q3k7", ["first reply", "second reply"]),
    ])
    func multilineAndOrderedNotes(source: String, operation: Operation, id: String, payloads: [String]) throws {
        var output = source
        for (index, payload) in payloads.enumerated() {
            output = try #require(
                apply(operation, source: output, id: id, author: payloads.count > 1 && index == 0 ? .codex : .user, payload: payload))
        }
        let annotation = try #require(AttributedMarkdownBuilder.build(output).annotation(id: id))
        if payloads.count == 1 { #expect(output.contains("encoding=lines")) }
        if operation == .document {
            #expect(annotation.payload == payloads[0])
        } else {
            #expect(annotation.notes.map(\.payload) == payloads)
            #expect(annotation.notes.map(\.author) == (payloads.count > 1 ? [.codex, .user] : [.user]))
        }
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

    @Test("removingAnnotation drops an own-line document marker without a blank gap")
    func removeDocumentLevel() throws {
        let src = "para one\n\n<!-- AMX id=w8p2 by=user: doc note -->\n<!-- AMX re=w8p2 by=codex: reply -->\n\npara two\n"
        let out = try #require(PlanAnnotationWriter.removingAnnotation(id: "w8p2", in: src))
        let doc = AttributedMarkdownBuilder.build(out)
        #expect(doc.annotations.isEmpty)
        #expect(doc.runs.map(\.text).joined() == "para one\n\npara two")
    }

    @Test("marker-shaped text inside a code fence is never a write target")
    func fencedExampleTextIsImmune() {
        let src = """
        Real note <mark>a</mark><!-- AMX id=q3k7 by=user: real -->

        ```
        <!-- AMX id=fake by=user: example text in docs -->
        ```
        """
        #expect(PlanAnnotationWriter.existingIDs(in: src + "\n\n<mark>b</mark><!-- USER COMMENT 2: y -->") == ["q3k7", "2"])
        #expect(PlanAnnotationWriter.removingAnnotation(id: "fake", in: src) == nil)
        #expect(PlanAnnotationWriter.updatingAnnotation(id: "fake", in: src) { _ in } == nil)
    }

    @Test("HTML markers keep Unicode byte ranges and fence opacity")
    func htmlMarkersKeepUnicodeByteRanges() throws {
        let marker = "<!-- AMX id=w8p2 by=user: café -->"
        let source = "préface\n> \(marker)\n\n```html\n<!-- AMX id=fake by=user: example -->\n```\n"
        let markerRange = try #require(source.range(of: marker))
        let markerStart = try #require(markerRange.lowerBound.samePosition(in: source.utf8))
        let expectedStart = source.utf8.distance(
            from: source.utf8.startIndex,
            to: markerStart
        )

        let markers = PlanAnnotationWriter.locatedMarkers(in: source)

        #expect(markers.count == 1)
        #expect(markers[0].byteRange == expectedStart..<(expectedStart + marker.utf8.count))
        let output = try #require(
            PlanAnnotationWriter.updatingAnnotation(id: "w8p2", in: source) {
                $0.status = .resolved
            })
        #expect(output.contains("<!-- AMX id=w8p2 by=user status=resolved: café -->"))
        #expect(output.contains("<!-- AMX id=fake by=user: example -->"))
    }
}
