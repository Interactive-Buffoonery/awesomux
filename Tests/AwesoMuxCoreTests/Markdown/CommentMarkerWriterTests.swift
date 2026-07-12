// Tests/AwesoMuxCoreTests/Markdown/CommentMarkerWriterTests.swift
import Testing
@testable import AwesoMuxCore

@Suite("CommentMarkerWriter")
struct CommentMarkerWriterTests {
    @Test("N is 1, then max+1 past existing markers")
    func numbering() {
        #expect(CommentMarkerWriter.nextCommentNumber(in: "plain") == 1)
        #expect(CommentMarkerWriter.nextCommentNumber(in: "<!-- USER COMMENT 1: a --><!-- USER COMMENT 4: b -->") == 5)
    }
    @Test("inserting wraps the span and appends the numbered marker")
    func insert() {
        let (out, n) = CommentMarkerWriter.insertingComment(in: "fix the loader now", span: 8..<14, note: "make async")
        #expect(n == 1)
        #expect(out == "fix the <mark>loader</mark><!-- USER COMMENT 1: make async --> now")
    }

    // MARK: - editingComment

    @Test("editingComment replaces the note for the targeted number")
    func editBasic() {
        let source = "x <mark>a</mark><!-- USER COMMENT 1: old --> y"
        let result = CommentMarkerWriter.editingComment(in: source, number: 1, newNote: "new")
        #expect(result == "x <mark>a</mark><!-- USER COMMENT 1: new --> y")
    }

    @Test("editingComment returns nil for a missing number")
    func editMissing() {
        let source = "x <mark>a</mark><!-- USER COMMENT 1: old --> y"
        #expect(CommentMarkerWriter.editingComment(in: source, number: 99, newNote: "new") == nil)
    }

    @Test("editingComment with two comments only touches the targeted one")
    func editTargeted() {
        let source = "<mark>a</mark><!-- USER COMMENT 1: first --> <mark>b</mark><!-- USER COMMENT 2: second -->"
        let result = CommentMarkerWriter.editingComment(in: source, number: 2, newNote: "changed")
        #expect(result == "<mark>a</mark><!-- USER COMMENT 1: first --> <mark>b</mark><!-- USER COMMENT 2: changed -->")
    }

    // MARK: - removingComment

    @Test("removingComment strips wrapper and marker leaving inner text")
    func removeBasic() {
        let source = "x <mark>a</mark><!-- USER COMMENT 1: note --> y"
        let result = CommentMarkerWriter.removingComment(in: source, number: 1)
        #expect(result == "x a y")
    }

    @Test("removingComment returns nil for a missing number")
    func removeMissing() {
        let source = "x <mark>a</mark><!-- USER COMMENT 1: note --> y"
        #expect(CommentMarkerWriter.removingComment(in: source, number: 99) == nil)
    }

    @Test("removingComment with two comments removes only the targeted one")
    func removeTargeted() {
        let source = "<mark>a</mark><!-- USER COMMENT 1: first --> <mark>b</mark><!-- USER COMMENT 2: second -->"
        let result = CommentMarkerWriter.removingComment(in: source, number: 1)
        #expect(result == "a <mark>b</mark><!-- USER COMMENT 2: second -->")
    }

    // MARK: - Exact-number boundary

    @Test("editingComment number 1 does NOT match inside marker 11")
    func editNoMatchInsideHigherNumber() {
        let source = "a <mark>x</mark><!-- USER COMMENT 11: keep --> b"
        #expect(CommentMarkerWriter.editingComment(in: source, number: 1, newNote: "y") == nil)
    }

    @Test("editingComment number 1 leaves marker 11 untouched when both are present")
    func editDoesNotCorruptHigherNumber() {
        let source = "<mark>a</mark><!-- USER COMMENT 1: first --> <mark>b</mark><!-- USER COMMENT 11: keep -->"
        let result = CommentMarkerWriter.editingComment(in: source, number: 1, newNote: "changed")
        #expect(result == "<mark>a</mark><!-- USER COMMENT 1: changed --> <mark>b</mark><!-- USER COMMENT 11: keep -->")
    }

    // MARK: - Arrow-sequence sanitization

    @Test("insertingComment with --> in note produces a single intact marker")
    func insertSanitizesArrow() {
        let source = "hello world"
        let (out, _) = CommentMarkerWriter.insertingComment(in: source, span: 6..<11, note: "see x --> y")
        // The marker must be well-formed: nextCommentNumber sees exactly one marker → returns 2
        #expect(CommentMarkerWriter.nextCommentNumber(in: out) == 2)
    }

    @Test("removingComment cleanly strips a marker whose note contained -->")
    func removeSanitizedArrow() {
        let source = "hello world"
        let (inserted, n) = CommentMarkerWriter.insertingComment(in: source, span: 6..<11, note: "see x --> y")
        let removed = CommentMarkerWriter.removingComment(in: inserted, number: n)
        #expect(removed == source)
    }

    @Test("editingComment with --> in newNote produces a single intact marker")
    func editSanitizesArrow() {
        let source = "x <mark>a</mark><!-- USER COMMENT 1: old --> y"
        let result = CommentMarkerWriter.editingComment(in: source, number: 1, newNote: "bad --> note")!
        // After edit the marker is still well-formed: nextCommentNumber returns 2
        #expect(CommentMarkerWriter.nextCommentNumber(in: result) == 2)
        // And removingComment can cleanly strip it
        let removed = CommentMarkerWriter.removingComment(in: result, number: 1)
        #expect(removed == "x a y")
    }

    // MARK: - Multi-comment removal (Codex regression)

    @Test("removing the second of two comments leaves the first intact")
    func removeSecondPreservesFirst() {
        let source = "<mark>a</mark><!-- USER COMMENT 1: first --> mid <mark>b</mark><!-- USER COMMENT 2: second -->"
        let removed = CommentMarkerWriter.removingComment(in: source, number: 2)!
        #expect(removed == "<mark>a</mark><!-- USER COMMENT 1: first --> mid b")
    }

    @Test("removing the first of two comments leaves the second intact")
    func removeFirstPreservesSecond() {
        let source = "<mark>a</mark><!-- USER COMMENT 1: first --> mid <mark>b</mark><!-- USER COMMENT 2: second -->"
        let removed = CommentMarkerWriter.removingComment(in: source, number: 1)!
        #expect(removed == "a mid <mark>b</mark><!-- USER COMMENT 2: second -->")
    }

    // MARK: - Newline normalization (Codex regression)

    @Test("a note with newlines collapses to a single-line marker that round-trips")
    func insertNormalizesNewlines() {
        let source = "hello world"
        let (out, n) = CommentMarkerWriter.insertingComment(in: source, span: 6..<11, note: "line one\nline two")
        #expect(!out.contains("line one\nline two"))
        #expect(out.contains("line one line two"))
        #expect(CommentMarkerWriter.nextCommentNumber(in: out) == 2)
        #expect(CommentMarkerWriter.removingComment(in: out, number: n) == source)
    }

    // MARK: - Round-trip

    @Test("insert → edit → remove leaves the original inner text")
    func roundTrip() {
        let original = "hello world"
        // insert comment on "world" (UTF-8 bytes 6..<11)
        let (inserted, n) = CommentMarkerWriter.insertingComment(in: original, span: 6..<11, note: "draft")
        // edit the note
        let edited = CommentMarkerWriter.editingComment(in: inserted, number: n, newNote: "final")!
        // remove the comment
        let removed = CommentMarkerWriter.removingComment(in: edited, number: n)!
        #expect(removed == original)
    }
}
