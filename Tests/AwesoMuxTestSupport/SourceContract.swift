import Foundation

/// Reads declarations out of the repository's own Swift source.
///
/// Some invariants live in a place no runtime assertion can reach — the
/// observation dependencies of a SwiftUI `body` are only observable by hosting
/// the whole view, and this repository has a documented history of hosted-view
/// tests going vacuously green. Scraping the source keeps such a test honest at
/// the cost of coupling it to the file's shape, so the shape it couples to is a
/// brace-balanced declaration body rather than a slice between two incidental
/// sibling members: renaming or reordering an unrelated member cannot move the
/// region, and every failure names the anchor it could not find.
public enum SourceContract {

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// The repository root, derived from this file's location rather than the
    /// caller's, so callers cannot miscount directory levels.
    public static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AwesoMuxTestSupport
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    public static func source(at repositoryRelativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(repositoryRelativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(
                description: """
                    Could not read \(repositoryRelativePath) relative to \
                    \(repositoryRoot.path). If the file moved, update the path \
                    in the test that asked for it.
                    """
            )
        }
        return text
    }

    /// The body of the declaration introduced by `opener`: everything between the
    /// first `{` at or after `opener` and its matching `}`.
    ///
    /// Finding the brace rather than requiring `opener` to end with one keeps the
    /// anchor short enough to survive signature reformatting — `"static func f("`
    /// is enough for a declaration whose parameters span several lines. The scan
    /// does not model braces in string literals, comments, or closure default
    /// arguments between the anchor and the body.
    ///
    /// - Parameter opener: a substring unique to the declaration's header,
    ///   e.g. `"var body: some View {"` or `"static func updatePane("`.
    public static func declarationBody(
        after opener: String,
        in source: String,
        path: String
    ) throws -> String {
        let occurrences = source.ranges(of: opener)
        guard let anchor = occurrences.first else {
            throw Failure(
                description: """
                    \(path) no longer contains `\(opener)`. That anchor is the \
                    start of the region a source-contract test asserts against — \
                    if the declaration was renamed or reformatted, point the \
                    test at the new header; if it was deleted, the contract it \
                    encoded needs re-checking, not re-anchoring.
                    """
            )
        }
        guard occurrences.count == 1 else {
            throw Failure(
                description: """
                    \(path) contains `\(opener)` \(occurrences.count) times, so a \
                    source-contract test cannot tell which one it is asserting \
                    against. Make the anchor unique.
                    """
            )
        }

        guard let openingBrace = source[anchor.lowerBound...].firstIndex(of: "{") else {
            throw Failure(
                description: """
                    `\(opener)` in \(path) is not followed by an opening brace, so \
                    it does not introduce a body a source-contract test can read.
                    """
            )
        }

        var depth = 1
        var index = source.index(after: openingBrace)
        let bodyStart = index
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart..<index])
                }
            default: break
            }
            index = source.index(after: index)
        }

        throw Failure(
            description: """
                `\(opener)` in \(path) has no matching closing brace. Either the \
                file does not compile or it contains a brace inside a string \
                literal or comment, which this scan does not model.
                """
        )
    }
}
