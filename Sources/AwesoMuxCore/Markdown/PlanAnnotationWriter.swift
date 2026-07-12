// Sources/AwesoMuxCore/Markdown/PlanAnnotationWriter.swift
//
// Guarded, marker-local rewrites for AMX plan annotations
// (docs/plan-annotations.md). Every operation edits exactly the markers it
// targets — never whole-file regeneration — and callers wrap writes in the
// same stale-source guard as CommentMarkerWriter.applyIfCurrent.
//
// Markers are located by walking the swift-markdown AST, NOT by regexing the
// raw source: code fences and inline code are opaque nodes, so
// annotation-shaped example text inside them is never a write target, and the
// writer sees exactly the markers the parser renders (adversarial review: a
// raw-text scan deleted fenced example lines and could edit a smuggled
// duplicate-id marker instead of the real one).

import Foundation
import Markdown

public enum PlanAnnotationWriter {
    // MARK: - Located markers

    /// One parser-visible marker and its UTF-8 byte range in the source.
    struct LocatedMarker {
        enum Kind {
            case amx(PlanAnnotationMarker)
            case legacy(number: Int, note: String)
        }

        let byteRange: Range<Int>
        let kind: Kind
    }

    /// Every marker the parser would see, in document order.
    static func locatedMarkers(in source: String) -> [LocatedMarker] {
        let mapper = SourceOffsetMapper(source: source)
        let document = Document(parsing: source)
        let sourceByteCount = source.utf8.count
        var result: [LocatedMarker] = []

        func byteRange(of node: any Markup) -> Range<Int>? {
            guard let r = node.range,
                  let lo = mapper.utf8Offset(forLine: r.lowerBound.line, column: r.lowerBound.column),
                  let hi = mapper.utf8Offset(forLine: r.upperBound.line, column: r.upperBound.column),
                  lo <= hi else { return nil }
            return lo..<hi
        }

        func record(text: String, range: Range<Int>) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let marker = PlanAnnotationMarker.parse(trimmed) {
                result.append(LocatedMarker(byteRange: range, kind: .amx(marker)))
            } else if let (n, note) = parseLegacy(trimmed) {
                result.append(LocatedMarker(byteRange: range, kind: .legacy(number: n, note: note)))
            }
        }

        // An HTMLBlock's rawHTML drops container prefixes (a blockquote's
        // "> "), so byte positions come from re-finding the comment on each
        // SOURCE line the block spans, not from walking rawHTML offsets.
        func recordBlockLines(_ block: HTMLBlock) {
            guard let r = block.range else { return }
            for lineNumber in r.lowerBound.line...r.upperBound.line {
                guard let lineStart = mapper.utf8Offset(forLine: lineNumber, column: 1) else { continue }
                let lineEnd = mapper.utf8Offset(forLine: lineNumber + 1, column: 1).map { $0 - 1 }
                    ?? sourceByteCount
                let lineText = byteSlice(source, lineStart..<lineEnd)
                guard let lo = lineText.range(of: "<!--"),
                      let hi = lineText.range(of: "-->", options: .backwards),
                      lo.lowerBound < hi.upperBound else { continue }
                let comment = String(lineText[lo.lowerBound..<hi.upperBound])
                let start = lineStart + lineText[..<lo.lowerBound].utf8.count
                record(text: comment, range: start..<(start + comment.utf8.count))
            }
        }

        func visit(_ node: any Markup) {
            if let inline = node as? InlineHTML {
                if let range = byteRange(of: inline) {
                    record(text: inline.rawHTML, range: range)
                }
                return
            }
            if let block = node as? HTMLBlock {
                recordBlockLines(block)
                return
            }
            if node is CodeBlock || node is InlineCode { return }
            for child in node.children { visit(child) }
        }

        visit(document)
        return result.sorted { $0.byteRange.lowerBound < $1.byteRange.lowerBound }
    }

    // MARK: - Queries

    /// Every annotation id in `source` (AMX and legacy), for collision-free
    /// id generation.
    public static func existingIDs(in source: String) -> Set<String> {
        existingIDs(in: locatedMarkers(in: source))
    }

    /// Overload for callers that already paid for a `locatedMarkers` parse —
    /// each `locatedMarkers` call re-parses the whole document.
    static func existingIDs(in markers: [LocatedMarker]) -> Set<String> {
        var ids: Set<String> = []
        for marker in markers {
            switch marker.kind {
            case .amx(.annotation(let a)): ids.insert(a.id)
            case .legacy(let n, _): ids.insert(String(n))
            case .amx(.note): break
            }
        }
        return ids
    }

    // MARK: - Insert

    /// Wrap `span` (UTF-8 byte range) in `<mark>…</mark>` followed by a new
    /// AMX annotation marker. Returns the new source and the annotation id.
    public static func insertingAnnotation(
        in source: String,
        span: Range<Int>,
        author: PlanAnnotationAuthor,
        intent: PlanAnnotationIntent = .comment,
        payload: String,
        id: String? = nil
    ) -> (source: String, id: String)? {
        // Fail closed on an empty span: <mark></mark> stamps zero runs, so the
        // annotation would exist in the file with no pill and no highlight —
        // unreachable in the UI but counted as open.
        guard !span.isEmpty else { return nil }
        let existing = existingIDs(in: source)
        let newID = id ?? PlanAnnotationMarker.generateID(existing: existing)
        guard PlanAnnotationMarker.isToken(newID), !existing.contains(newID),
              let marker = PlanAnnotationMarker.annotation(.init(
                  id: newID, author: author, intent: intent, payload: payload
              )).serialized()
        else { return nil }
        let bytes = Array(source.utf8)
        let before = String(decoding: bytes[..<span.lowerBound], as: UTF8.self)
        let inner = String(decoding: bytes[span], as: UTF8.self)
        let after = span.upperBound == bytes.count
            ? ""
            : String(decoding: bytes[span.upperBound...], as: UTF8.self)
        return (before + "<mark>\(inner)</mark>" + marker + after, newID)
    }

    /// Append the document's single whole-document note at the end of the
    /// file, blank-line separated. Returns nil when a document note already
    /// exists.
    public static func appendingDocumentAnnotation(
        in source: String,
        author: PlanAnnotationAuthor,
        payload: String,
        id: String? = nil
    ) -> (source: String, id: String)? {
        guard AttributedMarkdownBuilder.build(source).documentNote == nil else { return nil }
        let existing = existingIDs(in: source)
        let newID = id ?? PlanAnnotationMarker.generateID(existing: existing)
        // Document-level intents are comment-only (span intents demote anyway).
        guard PlanAnnotationMarker.isToken(newID), !existing.contains(newID),
              let marker = PlanAnnotationMarker.annotation(.init(
                  id: newID, author: author, payload: payload
              )).serialized()
        else { return nil }
        return (appendingOwnLine(marker, to: source), newID)
    }

    // MARK: - Update

    /// Rewrite the marker for `id` after applying `mutate`. A legacy marker
    /// upgrades to the AMX form on this write, keeping its integer-string id
    /// (contract: upgrade-on-write, no bulk migration). Returns nil when the
    /// id is absent — or AMBIGUOUS: duplicate ids are refused fail-closed so
    /// a write can never land on the wrong marker.
    public static func updatingAnnotation(
        id: String,
        in source: String,
        mutate: (inout PlanAnnotationMarker.Annotation) -> Void
    ) -> String? {
        guard let target = uniqueAnnotation(id: id, in: locatedMarkers(in: source)) else { return nil }
        var updated = target.annotation
        mutate(&updated)
        if updated.payload != target.annotation.payload {
            updated.status = .open
        }
        guard let marker = PlanAnnotationMarker.annotation(updated).serialized() else { return nil }
        return byteSplice(
            source,
            replacing: target.byteRange,
            with: marker
        )
    }

    /// Append a thread note. It lands immediately after the annotation's
    /// marker — inline for span anchors, on its own next line when the marker
    /// occupies a whole line (two markers on one line would stop parsing as an
    /// annotation block). A legacy parent upgrades to the AMX form in the same
    /// write (contract: any write touching a legacy annotation upgrades it).
    /// Falls back to the end of the file if the marker is gone; returns nil
    /// when the id exists more than once (fail-closed on duplicates).
    public static func appendingNote(
        to id: String,
        in source: String,
        author: PlanAnnotationAuthor,
        payload: String
    ) -> String? {
        let markers = locatedMarkers(in: source)
        guard let noteMarker = PlanAnnotationMarker.note(.init(
            annotationID: id, author: author, payload: payload
        )).serialized() else { return nil }
        let occurrences = annotationOccurrences(id: id, in: markers)
        guard let target = occurrences.first else {
            return appendingOwnLine(noteMarker, to: source)
        }
        guard occurrences.count == 1 else { return nil }

        let notes = markers.compactMap { marker -> LocatedMarker? in
            guard case .amx(.note(let note)) = marker.kind, note.annotationID == id else { return nil }
            return marker
        }
        let insertionTarget = notes.last ?? LocatedMarker(byteRange: target.byteRange, kind: target.kind)
        let bytes = Array(source.utf8)
        let separator = isWholeLine(insertionTarget.byteRange, in: bytes) ? "\n" : ""
        var edits: [(range: Range<Int>, replacement: String)] = [
            (insertionTarget.byteRange.upperBound..<insertionTarget.byteRange.upperBound, separator + noteMarker)
        ]

        // A legacy parent is rewritten to AMX in the same write; an AMX parent
        // keeps its original bytes (preserving unknown-key order) — unless it
        // was resolved: a reply is review activity, so the parent reopens in
        // the same write and the thread can't land invisible behind the
        // resolved filter (review decision).
        switch target.kind {
        case .legacy:
            guard let parentText = PlanAnnotationMarker.annotation(target.annotation).serialized() else { return nil }
            edits.append((target.byteRange, parentText))
        case .amx:
            if target.annotation.status != .open {
                var reopened = target.annotation
                reopened.status = .open
                guard let parentText = PlanAnnotationMarker.annotation(reopened).serialized() else { return nil }
                edits.append((target.byteRange, parentText))
            }
        }
        return applyingEdits(edits, to: source)
    }

    // MARK: - Remove

    /// Hard removal: drop the marker (unwrapping `<mark>…</mark>` for span
    /// anchors) plus the annotation's thread notes, cleaning up own-line
    /// leftovers so no blank gaps accumulate. Returns nil when the id is
    /// absent or ambiguous (duplicates refuse, fail-closed).
    public static func removingAnnotation(id: String, in source: String) -> String? {
        let markers = locatedMarkers(in: source)
        guard let target = uniqueAnnotation(id: id, in: markers) else { return nil }
        let bytes = Array(source.utf8)

        var edits: [(range: Range<Int>, replacement: String)] = []
        if let unwrap = markUnwrapEdit(markerRange: target.byteRange, bytes: bytes) {
            edits.append(unwrap)
        } else {
            edits.append((expandedToWholeLine(target.byteRange, in: bytes), ""))
        }
        for marker in markers {
            if case .amx(.note(let note)) = marker.kind, note.annotationID == id {
                edits.append((expandedToWholeLine(marker.byteRange, in: bytes), ""))
            }
        }

        return applyingEdits(edits, to: source)
    }

    // MARK: - Marker resolution helpers

    struct ResolvedAnnotation {
        let byteRange: Range<Int>
        let annotation: PlanAnnotationMarker.Annotation
        let kind: LocatedMarker.Kind
    }

    private static func annotationOccurrences(
        id: String,
        in markers: [LocatedMarker]
    ) -> [ResolvedAnnotation] {
        markers.compactMap { marker in
            switch marker.kind {
            case .amx(.annotation(let a)) where a.id == id:
                return ResolvedAnnotation(byteRange: marker.byteRange, annotation: a, kind: marker.kind)
            case .legacy(let n, let note) where String(n) == id:
                return ResolvedAnnotation(
                    byteRange: marker.byteRange,
                    annotation: .init(id: id, author: .user, payload: note),
                    kind: marker.kind
                )
            default:
                return nil
            }
        }
    }

    private static func uniqueAnnotation(
        id: String,
        in markers: [LocatedMarker]
    ) -> ResolvedAnnotation? {
        let occurrences = annotationOccurrences(id: id, in: markers)
        guard occurrences.count == 1 else { return nil }
        return occurrences[0]
    }

    private static func parseLegacy(_ comment: String) -> (Int, String)? {
        guard comment.hasPrefix("<!--"), comment.hasSuffix("-->") else { return nil }
        let inner = comment.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.uppercased().hasPrefix("USER COMMENT") else { return nil }
        let after = inner.dropFirst("USER COMMENT".count).trimmingCharacters(in: .whitespaces)
        guard let colon = after.firstIndex(of: ":"),
              let n = Int(after[after.startIndex..<colon].trimmingCharacters(in: .whitespaces)),
              n > 0 else { return nil }
        let note = after[after.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\|", with: "|")
        return (n, note)
    }

    // MARK: - Byte helpers

    private static func byteSlice(_ source: String, _ range: Range<Int>) -> String {
        let bytes = Array(source.utf8)
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// Apply edits back-to-front against one shared byte buffer, so earlier
    /// ranges stay valid and the document is copied once per operation instead
    /// of once per edit.
    private static func applyingEdits(
        _ edits: [(range: Range<Int>, replacement: String)],
        to source: String
    ) -> String {
        var bytes = Array(source.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func byteSplice(
        _ source: String,
        replacing range: Range<Int>,
        with replacement: String
    ) -> String {
        let bytes = Array(source.utf8)
        let before = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
        let after = range.upperBound == bytes.count
            ? ""
            : String(decoding: bytes[range.upperBound...], as: UTF8.self)
        return before + replacement + after
    }

    /// True when `range` is the only non-whitespace content on its line.
    private static func isWholeLine(_ range: Range<Int>, in bytes: [UInt8]) -> Bool {
        var lineStart = range.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var lineEnd = range.upperBound
        while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
        let before = bytes[lineStart..<range.lowerBound].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        // 0x0D: in a CRLF file the \r before the \n is line-ending whitespace,
        // not content. Rejecting it made every own-line marker in a CRLF file
        // read as inline, so replies were appended without a separator and the
        // combined line stopped parsing as two markers.
        let after = bytes[range.upperBound..<lineEnd].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        return before && after
    }

    /// The removal range for a marker: the whole line (plus its newline) when
    /// the marker sits alone on it, else just the marker bytes.
    private static func expandedToWholeLine(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        guard isWholeLine(range, in: bytes) else { return range }
        var lineStart = range.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var lineEnd = range.upperBound
        while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
        if lineEnd < bytes.count { lineEnd += 1 }
        return lineStart..<lineEnd
    }

    /// Unwrap `<mark>inner</mark><marker>` to `inner` when the marker directly
    /// follows a close tag. The backward scan stops at any intervening
    /// `</mark>` so removal can never swallow an earlier annotation's mark.
    private static func markUnwrapEdit(
        markerRange: Range<Int>,
        bytes: [UInt8]
    ) -> (range: Range<Int>, replacement: String)? {
        let closeTag = Array("</mark>".utf8)
        let openTag = Array("<mark>".utf8)
        let closeEnd = markerRange.lowerBound
        guard closeEnd >= closeTag.count,
              bytes[(closeEnd - closeTag.count)..<closeEnd].elementsEqual(closeTag)
        else { return nil }
        let closeStart = closeEnd - closeTag.count

        var i = closeStart - openTag.count
        while i >= 0 {
            if bytes[i..<(i + openTag.count)].elementsEqual(openTag) {
                let inner = String(decoding: bytes[(i + openTag.count)..<closeStart], as: UTF8.self)
                return (i..<markerRange.upperBound, inner)
            }
            if i + closeTag.count <= closeStart,
               bytes[i..<(i + closeTag.count)].elementsEqual(closeTag) {
                return nil
            }
            i -= 1
        }
        return nil
    }

    /// Append `line` at the end of the file, blank-line separated, keeping a
    /// single trailing newline.
    private static func appendingOwnLine(_ line: String, to source: String) -> String {
        let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
        if trimmed.isEmpty { return line + "\n" }
        return trimmed + "\n\n" + line + "\n"
    }
}
