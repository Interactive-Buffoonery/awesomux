import Foundation
import Testing

/// Guard rail for awesomux#207: every test wait on a child process stays
/// bounded. Foundation's `waitUntilExit()` returns only when it observes the
/// child's termination event, and macOS drops that event under heavy fork/load
/// pressure — one run blocked for 15+ hours, pinning a core and holding the
/// `.build` lock so every later `swift test` queued behind it.
///
/// This has to be a source scan rather than a type-level guard. The bounded
/// helper cannot shadow `waitUntilExit()` into an error: an overload with a
/// defaulted parameter loses to the zero-argument original, so a bare call
/// still compiles and silently binds to the unbounded Foundation method — even
/// with `try` written in front of it, which only earns a warning. Nothing but a
/// scan stops the next call site from reintroducing the hang.
@Suite("Bounded process-wait guard (awesomux#207)")
struct ProcessWaitBoundedGuardTests {
    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // awesoMuxTests
        .deletingLastPathComponent()  // Tests

    /// This file necessarily spells the banned pattern, so it exempts itself.
    private static let exemptFileNames: Set<String> = [
        URL(fileURLWithPath: #filePath).lastPathComponent
    ]

    private static let swiftSources: [(path: String, contents: String)] = {
        let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: nil
        )
        var results: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                !exemptFileNames.contains(url.lastPathComponent),
                let contents = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            results.append((url.path, contents))
        }
        return results
    }()

    private static func codeLines(_ contents: String) -> [Substring] {
        contents.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("no test spawns a child and waits on it unbounded")
    func noBareWaitUntilExit() throws {
        try #require(!Self.swiftSources.isEmpty, "source scan found no Swift files")

        // Matches the zero-argument call specifically, so the bounded
        // `waitUntilExitEventually(deadline:)` and prose mentioning the API in
        // comments do not trip the guard. Local because `Regex` is not Sendable.
        let bareCall = /\.waitUntilExit\s*\(\s*\)/

        var offenders: [String] = []
        for (path, contents) in Self.swiftSources {
            for (index, line) in Self.codeLines(contents).enumerated()
            where line.contains(bareCall) {
                offenders.append("\(path):\(index + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Unbounded `waitUntilExit()` in tests (awesomux#207). Use \
            `try process.waitUntilExitEventually()` from AwesoMuxTestSupport, \
            which fails on a deadline instead of hanging the runner forever:
            \(offenders.joined(separator: "\n"))
            """
        )
    }
}
