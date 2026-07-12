import Foundation

/// Pure byte-level line-splitting helper for the agent runtime event
/// side-channel. Lifted out of `AgentRuntimeEventBridge` so it can be
/// covered by AwesoMuxCore's unit tests — the bridge itself lives in the
/// app target where no test target exists.
///
/// Operates on raw `Data` (not `String`) because chunked reads from the
/// JSONL file routinely land in the middle of a UTF-8 codepoint, and
/// String(data:encoding:.utf8) returns nil for invalid sequences. Carry
/// partial bytes forward in the fragment until enough arrives.
public enum AgentRuntimeEventLineSplitter {
    private static let newlineByte: UInt8 = 0x0A

    /// Split `chunk` (prefixed by any leftover `trailingFragment` from a
    /// prior read) on `\n` byte boundaries. Returns the complete lines
    /// and any trailing partial line that should be carried into the
    /// next call.
    public static func extractCompleteLines(
        from chunk: Data,
        trailingFragment: Data
    ) -> (lines: [Data], remainder: Data) {
        var combined = trailingFragment
        combined.append(chunk)

        var lines: [Data] = []
        var lineStart = combined.startIndex

        for index in combined.indices where combined[index] == newlineByte {
            lines.append(combined.subdata(in: lineStart..<index))
            lineStart = combined.index(after: index)
        }

        let remainder = lineStart == combined.endIndex
            ? Data()
            : combined.subdata(in: lineStart..<combined.endIndex)

        return (lines, remainder)
    }
}
