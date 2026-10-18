// Sources/AwesoMuxCore/Markdown/CommentMarkerWriter.swift
import Foundation
public enum CommentMarkerWriter {
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
}
