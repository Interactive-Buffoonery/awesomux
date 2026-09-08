// Sources/AwesoMuxCore/Markdown/SelectionSourceMapping.swift
import Foundation

public enum SelectionSourceMapping {
    public static func sourceSpan(forSelectedUTF16 sel: Range<Int>, in doc: RenderedDocument) -> Range<Int>? {
        guard !sel.isEmpty else { return nil }
        var cursor = 0
        var covered: [(run: RenderedRun, utf16InRun: Range<Int>)] = []
        var firstCoveredRunIndex: Int?
        var lastCoveredRunIndex: Int?
        for (index, run) in doc.runs.enumerated() {
            let len = run.text.utf16.count
            let runRange = cursor..<(cursor + len); cursor += len
            guard run.sourceRange != nil else { continue }
            let lo = max(runRange.lowerBound, sel.lowerBound), hi = min(runRange.upperBound, sel.upperBound)
            guard lo < hi else { continue }
            covered.append((run, (lo - runRange.lowerBound)..<(hi - runRange.lowerBound)))
            if firstCoveredRunIndex == nil { firstCoveredRunIndex = index }
            lastCoveredRunIndex = index
        }
        guard !covered.isEmpty else { return nil }
        // Reject invalid UTF-16 endpoints before markup fallback could widen them.
        guard let firstCovered = covered.first, let lastCovered = covered.last,
            let lowerByteOffset = utf8Len(firstCovered.run.text, upTo: firstCovered.utf16InRun.lowerBound),
            let upperByteOffset = utf8Len(lastCovered.run.text, upTo: lastCovered.utf16InRun.upperBound)
        else { return nil }

        // Cross-cell guard: a <mark> cannot span a table cell boundary (the `|`
        // delimiters are markup, not part of any cell's source). Table-cell runs
        // are joined by synthetic `\t`/`\n` separators (nil sourceRange, skipped
        // above), so the cross-block `"\n\n"` scan below never catches an
        // intra-row cross-column selection. Reject here if the covered runs touch
        // more than one distinct table cell.
        let touchedCells = Set(covered.compactMap { $0.run.style.tableCellPosition.map { "\($0.table).\($0.row).\($0.column)" } })
        if touchedCells.count > 1 { return nil }

        // Cross-block guard: a <mark> cannot span a block boundary in CommonMark — a blank line
        // terminates an inline-HTML run, so wrapping across one produces invalid markup and
        // corrupts the round-trip. Find every run whose rendered position falls STRICTLY BETWEEN
        // the first and last covered run; if any is a block separator with text "\n\n" (emitted
        // by emitSeparator() for paragraph/list-item boundaries), bail now.
        //
        // Soft breaks (" ") and hard line breaks ("\n") are within-paragraph and safe to span.
        // Thematic breaks emit NO run — they use emitSeparator(), so they appear as "\n\n"
        // separators in the run sequence and are caught by the separator scan below.
        //
        if covered.count >= 2 {
            if let first = firstCoveredRunIndex, let last = lastCoveredRunIndex, last > first {
                // Check the runs strictly between first and last for block boundaries.
                let between = doc.runs[(first + 1)..<last]
                if between.contains(where: { $0.text == "\n\n" }) { return nil }
            }
        }

        // Precise + contiguous path: a single precise run, or several precise runs whose source
        // ranges abut with no markup gap → wrap the exact union.
        let allPrecise = covered.allSatisfy { $0.run.preciseMapping }
        let contiguous = zip(covered, covered.dropFirst()).allSatisfy {
            $0.run.sourceRange!.upperBound == $1.run.sourceRange!.lowerBound
        }
        if allPrecise && contiguous {
            let lo = firstCovered.run.sourceRange!.lowerBound + lowerByteOffset
            let hi = lastCovered.run.sourceRange!.lowerBound + upperByteOffset
            return lo < hi ? lo..<hi : nil
        }
        // Markup-crossing or non-precise → snap to enclosing top-level constructs (markup-safe).
        let lo = covered.map { $0.run.enclosingRange?.lowerBound ?? $0.run.sourceRange!.lowerBound }.min()!
        let hi = covered.map { $0.run.enclosingRange?.upperBound ?? $0.run.sourceRange!.upperBound }.max()!
        return lo < hi ? lo..<hi : nil
    }

    /// True if the source span overlaps any run that already carries a comment markID,
    /// i.e. the selection touches already-commented text. Commenting such a span would
    /// nest `<mark>` inside `<mark>`, which causes the renderer to silently drop the
    /// original comment's highlight.
    public static func spanTouchesExistingMark(_ span: Range<Int>, in doc: RenderedDocument) -> Bool {
        for run in doc.runs {
            guard run.markID != nil, let sourceRange = run.sourceRange else { continue }
            if sourceRange.lowerBound < span.upperBound && span.lowerBound < sourceRange.upperBound {
                return true
            }
        }
        return false
    }

    private static func utf8Len(_ text: String, upTo utf16Index: Int) -> Int? {
        guard utf16Index >= 0,
            let index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Index, limitedBy: text.utf16.endIndex),
            let utf8Index = index.samePosition(in: text.utf8)
        else { return nil }
        return text.utf8.distance(from: text.utf8.startIndex, to: utf8Index)
    }

    // MARK: - Scroll-anchor mapping (INT-567)

    /// Maps a rendered UTF-16 offset (into the joined run text) to a UTF-8 byte
    /// offset in `doc.source`. ANCHOR-ONLY: for imprecise runs the result is
    /// approximate — never use this for selection/markup math (`sourceSpan` owns
    /// that, with markup-safe snapping).
    ///
    /// The intra-run walk runs over the DECODED run text, clamped into the run's
    /// source range. For precise runs (decoded == source bytes) that is exact.
    /// For imprecise runs (entity-bearing text, inline/fenced code) it drifts
    /// from the true source byte by the encode/decode delta accumulated before
    /// that point (a few bytes per entity; the whole fence/info-string delta for
    /// fenced code) — but `renderedUTF16Offset` inverts with the same walk, so
    /// round-trip on an unchanged document is exact, and the post-edit drift
    /// stays bounded by that delta. Snapping imprecise runs to their start
    /// would rethrow a long paragraph containing one entity — or a long fenced
    /// code block — back to its top, which is the INT-567 bug itself.
    ///
    /// A synthetic run (bullet, separator) anchors to the NEXT source-bearing
    /// run — the content the reader is actually looking at (a bullet's item
    /// text, the block after a separator). Nil only when nothing follows.
    public static func sourceOffset(forRenderedUTF16 target: Int, in doc: RenderedDocument) -> Int? {
        guard target >= 0 else { return nil }
        var cursor = 0
        for (index, run) in doc.runs.enumerated() {
            let start = cursor
            cursor += run.text.utf16.count
            guard target < cursor else { continue }
            guard let sr = run.sourceRange else {
                return doc.runs[(index + 1)...]
                    .first(where: { $0.sourceRange != nil })?
                    .sourceRange?.lowerBound
            }
            let intraRun = utf8Prefix(of: run.text, utf16Length: target - start)
            return max(sr.lowerBound, min(sr.lowerBound + intraRun, sr.upperBound - 1))
        }
        return nil
    }

    /// Reverse of `sourceOffset(forRenderedUTF16:in:)`: maps a UTF-8 byte offset
    /// in `doc.source` to a rendered UTF-16 offset.
    ///
    /// If no run's `sourceRange` contains the target (the offset fell in a markup
    /// gap, or the document was edited between capture and restore), falls back
    /// to the rendered END of the preceding run — the run whose source range ends
    /// closest before the target. A reader's position after an edit should bias
    /// toward what they were reading, not whatever follows. When that end sits on
    /// a block separator's newline, TextKit assigns it to the preceding
    /// paragraph's last line — still the intended bias.
    // ponytail: preceding-run bias only, no edit-distance smarts — revisit if
    // live-reload restore lands visibly wrong on heavily edited documents.
    public static func renderedUTF16Offset(forSourceOffset target: Int, in doc: RenderedDocument) -> Int? {
        guard target >= 0 else { return nil }
        var cursor = 0
        var preceding: (upper: Int, renderedEnd: Int)? = nil
        for run in doc.runs {
            let start = cursor
            let len = run.text.utf16.count
            cursor += len
            guard let sr = run.sourceRange else { continue }
            if sr.lowerBound <= target, target < sr.upperBound {
                return start + utf16Prefix(of: run.text, utf8Length: target - sr.lowerBound)
            }
            if sr.upperBound <= target, preceding.map({ sr.upperBound > $0.upper }) ?? true {
                preceding = (sr.upperBound, start + len)
            }
        }
        return preceding?.renderedEnd
    }

    // MARK: - Scalar-walk prefix converters (surrogate/mid-scalar safe)

    /// UTF-8 byte length of the longest scalar-aligned prefix of `text` whose
    /// UTF-16 length does not exceed `utf16Length`. A `utf16Length` that would
    /// split a surrogate pair floors to the preceding scalar boundary, so the
    /// result is always a valid byte offset in the source.
    private static func utf8Prefix(of text: String, utf16Length: Int) -> Int {
        var u16 = 0, bytes = 0
        for scalar in text.unicodeScalars {
            let w = UTF16.width(scalar)
            guard u16 + w <= utf16Length else { break }
            u16 += w
            bytes += UTF8.width(scalar)
        }
        return bytes
    }

    /// UTF-16 length of the longest scalar-aligned prefix of `text` whose
    /// UTF-8 byte length does not exceed `utf8Length`. A `utf8Length` that
    /// lands mid-scalar (stale anchor into a multi-byte character) floors to
    /// the preceding scalar boundary.
    private static func utf16Prefix(of text: String, utf8Length: Int) -> Int {
        var u16 = 0, bytes = 0
        for scalar in text.unicodeScalars {
            let w = UTF8.width(scalar)
            guard bytes + w <= utf8Length else { break }
            bytes += w
            u16 += UTF16.width(scalar)
        }
        return u16
    }
}
