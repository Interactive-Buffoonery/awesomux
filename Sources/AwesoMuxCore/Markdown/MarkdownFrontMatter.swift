import Foundation

public struct MarkdownFrontMatter: Equatable, Sendable {
    public let fullRange: Range<Int>
    public let metadataText: String
    public let body: String

    public static func parse(_ source: String) -> MarkdownFrontMatter? {
        guard !source.isEmpty else { return nil }

        let firstLine = line(in: source, startingAt: source.startIndex, byteOffset: 0)
        guard isDelimiter(firstLine.text, allowBOM: true) else { return nil }

        var currentIndex = firstLine.nextIndex
        var currentOffset = firstLine.nextOffset
        let metadataStartIndex = currentIndex

        while currentIndex < source.endIndex {
            let candidate = line(in: source, startingAt: currentIndex, byteOffset: currentOffset)
            if isDelimiter(candidate.text, allowBOM: false) || isClosingDots(candidate.text) {
                let rawMetadata = String(source[metadataStartIndex..<candidate.startIndex])
                return MarkdownFrontMatter(
                    fullRange: 0..<candidate.nextOffset,
                    metadataText: trimmedTrailingNewlines(rawMetadata),
                    body: String(source[candidate.nextIndex...])
                )
            }
            currentIndex = candidate.nextIndex
            currentOffset = candidate.nextOffset
        }

        return nil
    }

    public static func bodySource(from source: String) -> String {
        parse(source)?.body ?? source
    }

    private static func line(
        in source: String,
        startingAt startIndex: String.Index,
        byteOffset: Int
    ) -> (startIndex: String.Index, text: String, nextIndex: String.Index, nextOffset: Int) {
        let lineEnd = source[startIndex...].firstIndex(of: "\n") ?? source.endIndex
        let textEnd: String.Index
        if lineEnd > startIndex, source[source.index(before: lineEnd)] == "\r" {
            textEnd = source.index(before: lineEnd)
        } else {
            textEnd = lineEnd
        }
        let nextIndex = lineEnd == source.endIndex ? source.endIndex : source.index(after: lineEnd)
        let nextOffset = byteOffset + source[startIndex..<nextIndex].utf8.count
        return (startIndex, String(source[startIndex..<textEnd]), nextIndex, nextOffset)
    }

    private static func isDelimiter(_ line: String, allowBOM: Bool) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if allowBOM, trimmed.first == "\u{FEFF}" {
            trimmed.removeFirst()
        }
        return trimmed == "---"
    }

    private static func isClosingDots(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "..."
    }

    private static func trimmedTrailingNewlines(_ text: String) -> String {
        var result = text
        while result.last == "\n" || result.last == "\r" {
            result.removeLast()
        }
        return result
    }
}
