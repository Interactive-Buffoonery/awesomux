// Tests/AwesoMuxCoreTests/Markdown/SourceOffsetMapperTests.swift
import Testing
import Markdown
@testable import AwesoMuxCore

@Suite("SourceOffsetMapper")
struct SourceOffsetMapperTests {
    @Test("Document(parsing:) populates source ranges on leaves by default")
    func rangesExistByDefault() {
        let doc = Document(parsing: "# Title\n\nHello **world**.")
        var leafRanges = 0, leaves = 0
        func walk(_ m: Markup) {
            if m.childCount == 0 { leaves += 1; if m.range != nil { leafRanges += 1 } }
            m.children.forEach(walk)
        }
        walk(doc)
        #expect(leaves > 0)
        #expect(leafRanges == leaves)   // if this fails, parsing needs a source-tracking option — STOP and fix here
    }

    @Test("line 1 column 1 is offset 0")
    func origin() { #expect(SourceOffsetMapper(source: "abc\ndef").utf8Offset(forLine: 1, column: 1) == 0) }

    @Test("column counts UTF-8 bytes within the line")
    func columnWithinLine() {
        let m = SourceOffsetMapper(source: "abc\ndef")
        #expect(m.utf8Offset(forLine: 1, column: 3) == 2)
        #expect(m.utf8Offset(forLine: 2, column: 1) == 4)
    }

    @Test("multibyte characters advance the offset by their UTF-8 length")
    func multibyte() {
        let m = SourceOffsetMapper(source: "é!\nx")
        #expect(m.utf8Offset(forLine: 1, column: 3) == 2)
        #expect(m.utf8Offset(forLine: 2, column: 1) == 4)
    }

    @Test("a real swift-markdown node round-trips through the mapper")
    func roundTripsRealNode() throws {
        let source = "# Title\n\nHello **world**."
        let doc = Document(parsing: source)
        var found: Markup?
        func walk(_ m: Markup) { if let t = m as? Text, t.string == "world" { found = t }; m.children.forEach(walk) }
        walk(doc)
        let node = try #require(found); let range = try #require(node.range)
        let m = SourceOffsetMapper(source: source)
        let start = try #require(m.utf8Offset(forLine: range.lowerBound.line, column: range.lowerBound.column))
        let end = try #require(m.utf8Offset(forLine: range.upperBound.line, column: range.upperBound.column))
        #expect(String(decoding: Array(source.utf8)[start..<end], as: UTF8.self) == "world")
    }

    @Test("a real swift-markdown node with multibyte content round-trips through the mapper")
    func roundTripsRealNonASCIINode() throws {
        // Closes the gap between `multibyte` (mapper arithmetic in isolation) and a real
        // swift-markdown SourceLocation: an accented heading whose column is reported in
        // UTF-8 bytes must still slice cleanly. "Résumé" is 8 UTF-8 bytes / 6 scalars.
        let source = "## Résumé\n\n**world**"
        let doc = Document(parsing: source)
        var found: Markup?
        func walk(_ m: Markup) { if let t = m as? Text, t.string == "Résumé" { found = t }; m.children.forEach(walk) }
        walk(doc)
        let node = try #require(found); let range = try #require(node.range)
        let m = SourceOffsetMapper(source: source)
        let start = try #require(m.utf8Offset(forLine: range.lowerBound.line, column: range.lowerBound.column))
        let end = try #require(m.utf8Offset(forLine: range.upperBound.line, column: range.upperBound.column))
        #expect(String(decoding: Array(source.utf8)[start..<end], as: UTF8.self) == "Résumé")
    }

    @Test("out-of-range line or column returns nil")
    func outOfRange() {
        let m = SourceOffsetMapper(source: "abc")
        #expect(m.utf8Offset(forLine: 9, column: 1) == nil)
        #expect(m.utf8Offset(forLine: 1, column: 99) == nil)
    }

    @Test("column past a line's end returns nil, not an offset into the next line")
    func columnPastLineEnd() {
        // "abc\ndef": line 1 is "abc\n" (4 bytes). Column 5 is within the newline+1 = 5,
        // but column 6 is past it. The important regression: column 5 on line 1 must not
        // silently resolve to offset 4 (the start of line 2).
        let m = SourceOffsetMapper(source: "abc\ndef")
        #expect(m.utf8Offset(forLine: 1, column: 5) == nil)
    }
}
