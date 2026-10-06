import AppKit

struct GhosttyNativeLinkState: Sendable {
    private var isPointer = false
    var isLink: Bool { isPointer || value != nil }
    private(set) var value: String?

    mutating func updatePointer(_ isPointer: Bool) {
        self.isPointer = isPointer
    }

    mutating func updateTarget(_ target: String?) {
        value = target.flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor
enum GhosttyMarkdownClickProbe {
    static func isCurrent(press: CGPoint, reported: CGPoint?, surface: UInt64?, reportedSurface: UInt64?) -> Bool {
        surface != nil && surface == reportedSurface && reported == press
    }

    static func filename(
        _ text: String, start: UInt64, length: UInt64, columns: UInt64, rows: UInt64, visible: Bool, hasNativeLink: Bool = false,
        readCell: (UInt64) -> String?
    ) -> String? {
        let value = MarkdownLinkIntercept.strippingTrailingSentencePunctuation(text)
        guard !hasNativeLink, !value.isEmpty,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                    || "._-/~".unicodeScalars.contains($0)
            }),
            !MarkdownLinkIntercept.containsUnsafePathScalars(value),
            RemoteMarkdownReference.isPotentialPayload(value),
            RemoteMarkdownReference.remotePath(from: value) == value
        else { return nil }
        let cells = columns * rows
        let end = start + length
        // Native offsets count grid cells, including wide cells and wrapped
        // rows. Clipped selections have unreliable offsets; fail closed.
        guard visible, columns > 0, rows > 0, length > 0, start > 0, start < cells, end + 1 < cells,
            let before = readCell(start - 1), let after = readCell(end + 1),
            isDelimiter(before), isDelimiter(after)
        else { return nil }
        return value
    }

    private static func isDelimiter(_ value: String) -> Bool {
        value.isEmpty
            || value.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || "'\"`;,()[]{}<>|".unicodeScalars.contains($0)
            }
    }
}
