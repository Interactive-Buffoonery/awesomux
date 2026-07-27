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
            String($0[1].substring ?? "").replacing(interpolation, with: "%arg")
        }
    }

    enum CatalogError: Error {
        case malformed
    }
}
