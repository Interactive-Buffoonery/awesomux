// Sources/AwesoMuxCore/Markdown/CommentMarkerWriter.swift
import Foundation
public enum CommentMarkerWriter {
    private static let pattern = try! NSRegularExpression(pattern: "<!--\\s*USER COMMENT\\s+(\\d+)\\s*:")

    // Normalizes a note for storage inside a single-line inline HTML comment marker.
    // Three hazards:
    //  1. A pasted newline would make the marker span lines — the inline-HTML parser
    //     can drop it into an HTMLBlock (silently lost) and the edit regex (no
    //     dotMatchesLineSeparators) could no longer match it. Collapse CR/LF to spaces.
    //  2. A literal `-->` would prematurely close the comment — insert a zero-width
    //     space between `--` and `>`.
    //  3. A literal `|` inside a marker written into a GFM table row splits the row:
    //     cell delimiters are processed BEFORE inline parsing, so an unescaped pipe
    //     chops the marker into phantom columns, drops trailing cells, and the
    //     half-marker no longer parses as an HTML comment (comment vanishes while the
    //     corruption persists in the file). GFM honors `\|` everywhere, including
    //     inside raw HTML; the table parser strips the escape, and
    //     `parseCommentMarker` unescapes for non-table contexts.
    // Internal (not private): PlanAnnotationMarker serialization shares these
    // exact rules so AMX and legacy markers stay byte-compatible in tables.
    static func sanitizeNote(_ note: String) -> String {
        note
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "-->", with: "--\u{200B}>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    public static func nextCommentNumber(in source: String) -> Int {
        let ns = source as NSString
        let maxN = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
        return maxN + 1
    }
    public static func insertingComment(in source: String, span: Range<Int>, note: String) -> (source: String, number: Int) {
        let n = nextCommentNumber(in: source); let b = Array(source.utf8)
        let before = String(decoding: b[..<span.lowerBound], as: UTF8.self)
        let inner = String(decoding: b[span], as: UTF8.self)
        let after = String(decoding: b[span.upperBound...], as: UTF8.self)
        let safeNote = sanitizeNote(note)
        return (before + "<mark>\(inner)</mark><!-- USER COMMENT \(n): \(safeNote) -->" + after, n)
    }

    public static func editingComment(in source: String, number: Int, newNote: String) -> String? {
        let escapedNum = NSRegularExpression.escapedPattern(for: String(number))
        // Match the exact marker written by insertingComment; use \b after the number to
        // prevent "1" matching inside "11", "12", etc.
        guard let regex = try? NSRegularExpression(
            pattern: "<!-- USER COMMENT \(escapedNum)\\b: (.*?) -->",
            options: []
        ) else { return nil }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        let fullRange = match.range
        let safeNote = sanitizeNote(newNote)
        // NSString.replacingCharacters(in:with:) is used deliberately — a plain string swap.
        // Using NSRegularExpression.replacementString(for:in:offset:template:) here would
        // interpret `$1` / `\` in safeNote as backreferences, corrupting user text.
        let replacement = "<!-- USER COMMENT \(number): \(safeNote) -->"
        return (ns.replacingCharacters(in: fullRange, with: replacement))
    }

    public static func removingComment(in source: String, number: Int) -> String? {
        let escapedNum = NSRegularExpression.escapedPattern(for: String(number))
        // Match <mark>inner</mark><!-- USER COMMENT N: note --> and replace with inner.
        // \b prevents "1" matching inside "11", "12", etc.
        //
        // The inner capture is `(?:(?!</mark>).)*?` — a lazy match that can NOT cross a
        // `</mark>`. A bare `(.*?)` lets the engine backtrack across an earlier comment's
        // `</mark>` to reach marker N, so removing the *second* of two comments would
        // swallow the first one's mark and corrupt the source (Codex review). Anchoring
        // the capture to the nearest preceding `<mark>…</mark>` keeps removal local.
        guard let regex = try? NSRegularExpression(
            pattern: "<mark>((?:(?!</mark>).)*?)</mark><!-- USER COMMENT \(escapedNum)\\b:.*?-->",
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        let fullRange = match.range
        let innerRange = match.range(at: 1)
        let inner = ns.substring(with: innerRange)
        return (ns.replacingCharacters(in: fullRange, with: inner))
    }

    /// Returns `operation(onDisk)` when `onDisk == renderTimeSource`, else `nil`.
    ///
    /// The caller uses `nil` to detect stale-source conditions (the file was
    /// edited between the render and the write attempt). When the sources match,
    /// `onDisk` — not `renderTimeSource` — is forwarded to `operation` so the
    /// caller always writes against the freshest bytes on disk.
    public static func applyIfCurrent(
        renderTimeSource: String,
        onDisk: String,
        operation: (String) -> String?
    ) -> String? {
        guard onDisk == renderTimeSource else { return nil }
        return operation(onDisk)
    }
}
