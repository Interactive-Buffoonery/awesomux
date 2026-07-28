import Foundation

enum AwesoMuxLocalizationTestSupport {
    static var bundle: Bundle? {
        Bundle(url: fixtureURL.appending(path: "zz.lproj", directoryHint: .isDirectory))
    }

    static let pseudoLocale = Locale(identifier: "zz")

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/INT612Localization.bundle", directoryHint: .isDirectory)
    }
}

// MARK: - String catalog coverage

/// `Resources/Localizable.xcstrings` is not a declared SwiftPM resource
/// (`Package.swift` bundles only `Resources/Fonts`; the catalog is compiled into
/// the `.app` by `script/build_and_run.sh`). So under `swift test` there is no
/// catalog to miss, and `String(localized:)` always falls back to formatting the
/// source literal — which means an assertion on the *rendered* string cannot
/// fail when a hand-grafted catalog entry is wrong, misordered, or absent.
///
/// These read the catalog file directly instead, which is the only way a test
/// here can actually observe the source and the catalog disagreeing.
enum AwesoMuxStringCatalog {
    /// Resolves from this file, which sits at the same depth as its callers.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func keys() throws -> Set<String> {
        let data = try Data(
            contentsOf: repositoryRoot.appending(path: "Resources/Localizable.xcstrings"))
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = catalog["strings"] as? [String: Any]
        else {
            throw CatalogError.malformed
        }
        return Set(strings.keys)
    }

    /// Extracts `String(localized: "…"` literals and rewrites each Swift
    /// interpolation to the `%arg` marker the catalog keys use — the same
    /// normalization `xcstringstool` applies when it extracts them.
    static func localizedLiterals(in relativePath: String) throws -> [String] {
        let source = try String(
            contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8)
        let literal = try Regex(#"String\(\s*localized:\s*"((?:[^"\\]|\\[^(]|\\\([^)]*\))*)""#)
        let interpolation = try Regex(#"\\\([^)]*\)"#)
        return source.matches(of: literal).map {
            unescape(String($0[1].substring ?? "").replacing(interpolation, with: "%arg"))
        }
    }

    /// The compiler resolves escapes before `xcstringstool` ever sees the
    /// literal, so a source that writes `\u{201C}` and a catalog key holding a
    /// real curly quote are the *same* key. Reading the source text back means
    /// undoing that ourselves, or every escaped literal reports false drift.
    ///
    /// Today only `DocumentPaneView`'s read-error string needs this, and the
    /// two curly quotes there could just as well be written literally — eight
    /// other files already do. It stays because the escapes that will actually
    /// need it are the *invisible* ones: `GhosttyRuntimeCallbacks` localizes
    /// with `\u{2068}`/`\u{2069}` (FSI/PDI) bidi isolates, which cannot be
    /// written literally without becoming unreadable source. Any sweep that
    /// grows to cover those files needs this to already work.
    private static func unescape(_ literal: String) -> String {
        var result = ""
        var rest = Substring(literal)
        while let slash = rest.firstIndex(of: "\\") {
            result += rest[rest.startIndex..<slash]
            let afterSlash = rest.index(after: slash)
            guard afterSlash < rest.endIndex else {
                result += rest[slash...]
                return result
            }
            switch rest[afterSlash] {
            case "u":
                // `\u` must be followed IMMEDIATELY by `{`. Anchoring `open`
                // rather than searching for the next brace anywhere matters:
                // an unanchored search walks past this escape into a later
                // one, and `\u and later {41} here` silently became `A here`.
                let open = rest.index(after: afterSlash)
                guard
                    open < rest.endIndex, rest[open] == "{",
                    let close = rest[open...].firstIndex(of: "}"),
                    let scalar = UInt32(rest[rest.index(after: open)..<close], radix: 16)
                        .flatMap(Unicode.Scalar.init)
                else {
                    result += rest[slash...afterSlash]
                    rest = rest[rest.index(after: afterSlash)...]
                    continue
                }
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: close)...]
            case "n": result += "\n"; rest = rest[rest.index(after: afterSlash)...]
            case "t": result += "\t"; rest = rest[rest.index(after: afterSlash)...]
            case "r": result += "\r"; rest = rest[rest.index(after: afterSlash)...]
            case "0": result += "\0"; rest = rest[rest.index(after: afterSlash)...]
            case let other: result.append(other); rest = rest[rest.index(after: afterSlash)...]
            }
        }
        return result + rest
    }

    enum CatalogError: Error {
        case malformed
    }
}
