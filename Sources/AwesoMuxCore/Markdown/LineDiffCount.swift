public struct LineDiffCount: Equatable, Sendable {
    public let added: Int
    public let removed: Int

    public var isEmpty: Bool {
        added == 0 && removed == 0
    }

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public static func between(_ old: String, _ new: String) -> LineDiffCount {
        // An empty document is zero lines, not one empty line: the first write
        // into a fresh plan file must read as pure additions, not "+N / -1".
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        // ponytail: a gutter-diff upgrade should return this CollectionDifference
        // instead of flattening it into count-only UI. Lines compare as raw
        // substrings, so a CRLF<->LF-normalizing editor counts every line as
        // changed; normalize here if that ever bites a real workflow.
        let difference = newLines.difference(from: oldLines)
        let added = difference.insertions.count
        let removed = difference.removals.count
        return LineDiffCount(added: added, removed: removed)
    }

    /// Inputs past this size skip the indicator: `difference(from:)` is
    /// Myers-family (near-quadratic on a full rewrite) and the watcher's disk
    /// read is not bounded by the document loader's file-size cap, so a huge
    /// or hostile file must not buy an expensive diff on every save.
    public static let maxDiffBytes = 2 * 1024 * 1024

    public static func forExternalEdit(
        old: String?,
        new: String,
        isSelfWrite: Bool
    ) -> LineDiffCount? {
        guard !isSelfWrite, let old, old != new else {
            return nil
        }
        guard old.utf8.count <= maxDiffBytes, new.utf8.count <= maxDiffBytes else {
            return nil
        }
        let count = between(old, new)
        return count.isEmpty ? nil : count
    }
}
