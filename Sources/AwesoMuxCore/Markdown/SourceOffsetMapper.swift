/// Bridges swift-markdown's 1-based (line, byte-column) SourceLocations to absolute UTF-8 byte
/// offsets. SourceLocation exposes no offset of its own, so PR2 needs this to turn a node's range
/// into a sliceable span.
public struct SourceOffsetMapper: Sendable {
    private let lineStartOffsets: [Int]
    private let byteCount: Int
    public init(source: String) {
        var starts = [0]; var offset = 0
        for byte in source.utf8 { offset += 1; if byte == 0x0A { starts.append(offset) } }
        self.lineStartOffsets = starts; self.byteCount = offset
    }
    /// Maps a 1-based (line, byte-column) location to its absolute UTF-8 byte offset.
    ///
    /// Returns `nil` if `line` is outside the document, `column` is less than 1, or `column`
    /// exceeds the byte length of `line` plus one. The plus-one allowance preserves
    /// swift-markdown's valid *exclusive* upper-bound convention: a node whose last character
    /// is the final byte of a line has its end column reported as `lineLength + 1`.
    public func utf8Offset(forLine line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStartOffsets.count, column >= 1 else { return nil }
        // Upper-bound guard: reject a column past the end of its own line.
        // For non-final lines, the line occupies bytes [lineStart, nextLineStart); allow
        // column up to that span (inclusive). For the final line (no trailing newline
        // recorded), add +1 to accept swift-markdown's exclusive upper-bound convention
        // where an end column == lineLength + 1 is valid.
        let lineStart = lineStartOffsets[line - 1]
        let maxColumn = line < lineStartOffsets.count
            ? lineStartOffsets[line] - lineStart
            : byteCount - lineStart + 1
        guard column <= maxColumn else { return nil }
        let candidate = lineStart + (column - 1)
        return candidate <= byteCount ? candidate : nil
    }
}
