import Foundation
import Testing

/// Guard rail for awesomux#207: no test waits on a child process via
/// `waitUntilExit()`. That is narrower than "every child wait is bounded" —
/// a blocking pipe read before the wait can still hang, and those sites are
/// tracked separately on the pull request.
/// Foundation's `waitUntilExit()` returns only when it observes the
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
///
/// `script/check_test_waits.sh` enforces the same rule on changed lines so cheap
/// CI rejects a bare call before `swift test` starts. This suite is the
/// whole-tree regression net behind it.
///
/// Scope is `Tests/` only. `Sources/awesoMux/Services/BridgeGenerationRegistry`
/// keeps a bare wait on the app-quit path deliberately: its caller fans out
/// under a `DispatchGroup` with `group.wait(timeout:)`, so quit stays bounded
/// and killing the child mid-cleanup is explicitly not wanted there.
@Suite("Bounded process-wait guard (awesomux#207)")
struct ProcessWaitBoundedGuardTests {
    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // awesoMuxTests
        .deletingLastPathComponent()  // Tests

    /// Exempted by exact path, not basename: a second file sharing this name
    /// elsewhere under `Tests/` must still be scanned.
    private static let exemptPath = URL(fileURLWithPath: #filePath).standardized.path

    private static let scan: (sources: [(path: String, contents: String)], unreadable: [String]) = {
        let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: nil
        )
        var sources: [(String, String)] = []
        var unreadable: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                url.standardized.path != exemptPath
            else { continue }
            // A file that cannot be read must be reported, never skipped: a
            // guard that quietly shrinks its own input reports clean without
            // having looked.
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                sources.append((url.path, contents))
            } else {
                unreadable.append(url.path)
            }
        }
        return (sources, unreadable)
    }()

    @Test("no test spawns a child and waits on it unbounded")
    func noBareWaitUntilExit() throws {
        try #require(!Self.scan.sources.isEmpty, "source scan found no Swift files")
        try #require(
            Self.testsRoot.lastPathComponent == "Tests",
            "scan root drifted to \(Self.testsRoot.path); it must be the Tests directory"
        )
        #expect(Self.scan.unreadable.isEmpty, "unreadable sources: \(Self.scan.unreadable)")

        // No leading dot, so an implicit-self call inside a `Process` extension
        // is caught too — this module adds exactly such an extension, which
        // makes that the natural next thing to write. `waitUntilExitEventually`
        // cannot match: the bounded name has no `(` after `waitUntilExit`.
        //
        // Deliberately no `\b` and no lookbehind. `\b` does not match between
        // `.` and `w`, so it silently misses `process.waitUntilExit()` — the
        // primary case — and Swift Regex rejects lookbehind outright. The only
        // thing this over-matches is an identifier ending in a lowercase
        // `waitUntilExit`, which is not a name anyone writes.
        //
        // ponytail: line-at-a-time, so `waitUntilExit(\n)` and a stored method
        // reference (`let f = p.waitUntilExit`) both slip through, as they do in
        // `check_test_waits.sh`. Neither is a shape anyone writes by accident,
        // and closing them means a real Swift parser. Reach for SwiftSyntax only
        // if one ever actually lands on main.
        let bareCall = /waitUntilExit\s*\(\s*\)/

        var offenders: [String] = []
        for (path, contents) in Self.scan.sources {
            // Enumerate the real line sequence and filter inside the `where`,
            // so reported line numbers stay true to the file.
            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains(bareCall)
            {
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
