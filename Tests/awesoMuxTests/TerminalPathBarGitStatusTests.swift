import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

// MARK: - Helpers

private actor RecordingGitStatusRunner {
    private(set) var callCount = 0
    private let response: Data?

    init(response: Data?) {
        self.response = response
    }

    func run(repoRoot: String) async -> Data? {
        callCount += 1
        return response
    }

    func count() -> Int { callCount }
}

private func porcelain(_ lines: String...) -> Data {
    Data(lines.joined(separator: "\n").utf8)
}

// MARK: - Parser

@Suite("Git status parsing")
struct GitStatusInfoParsingTests {
    @Test("a clean, in-sync repo parses to all-zero / isClean")
    func clean() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.oid abc123",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +0 -0"
            ))
        #expect(info.dirtyCount == 0)
        #expect(info.ahead == 0)
        #expect(info.behind == 0)
        #expect(info.isClean)
    }

    @Test("changed + untracked entries all count toward dirty")
    func dirtyCount() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.head main",
                "# branch.ab +0 -0",
                "1 .M N... 100644 100644 100644 aaa bbb file1.txt",
                "1 M. N... 100644 100644 100644 ccc ddd file2.txt",
                "? untracked.txt"
            ))
        #expect(info.dirtyCount == 3)
        #expect(!info.isClean)
    }

    @Test("a rename is a single dirty entry")
    func renameIsOneEntry() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.head main",
                "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\told.txt"
            ))
        #expect(info.dirtyCount == 1)
    }

    @Test("an unmerged path is a single dirty entry")
    func unmergedIsOneEntry() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.head main",
                "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt"
            ))
        #expect(info.dirtyCount == 1)
    }

    @Test("ahead and behind are read from the branch.ab header")
    func aheadBehind() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.head main",
                "# branch.ab +2 -3"
            ))
        #expect(info.ahead == 2)
        #expect(info.behind == 3)
        #expect(info.dirtyCount == 0)
        #expect(!info.isClean)
    }

    @Test("ahead-only suppresses the behind side")
    func aheadOnly() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.head main",
                "# branch.ab +5 -0"
            ))
        #expect(info.ahead == 5)
        #expect(info.behind == 0)
    }

    @Test("no upstream (no branch.ab line) yields zero ahead/behind")
    func noUpstream() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.oid abc123",
                "# branch.head my-feature"
            ))
        #expect(info.ahead == 0)
        #expect(info.behind == 0)
        #expect(info.isClean)
    }

    @Test("detached HEAD with dirty files still counts dirt, zero ahead/behind")
    func detachedDirty() {
        let info = GitStatusInfo(
            parsingPorcelainV2: porcelain(
                "# branch.oid abc123",
                "# branch.head (detached)",
                "1 .M N... 100644 100644 100644 aaa bbb file.txt"
            ))
        #expect(info.dirtyCount == 1)
        #expect(info.ahead == 0)
        #expect(info.behind == 0)
    }

    @Test("empty / malformed output parses to clean rather than crashing")
    func malformed() {
        #expect(GitStatusInfo(parsingPorcelainV2: Data()).isClean)
        #expect(GitStatusInfo(parsingPorcelainV2: Data("garbage no newlines".utf8)).dirtyCount == 1)
    }
}

// MARK: - Resolver

@Suite("Git status resolver")
struct GitStatusResolverTests {
    private static let dirtyOutput = porcelain(
        "# branch.head main",
        "# branch.ab +1 -0",
        "? new.txt"
    )

    @Test("a cache hit within TTL does not re-run git")
    func cacheHit() async {
        let runner = RecordingGitStatusRunner(response: Self.dirtyOutput)
        let resolver = GitStatusResolver(runner: { root, _ in await runner.run(repoRoot: root) })

        let first = await resolver.status(repoRoot: "/r", branch: "main")
        let second = await resolver.status(repoRoot: "/r", branch: "main")

        #expect(first?.dirtyCount == 1)
        #expect(first?.ahead == 1)
        #expect(second == first)
        #expect(await runner.count() == 1)
    }

    @Test("the status re-resolves after the TTL")
    func ttlExpiry() async {
        let clock = TestClock()
        let runner = RecordingGitStatusRunner(response: Self.dirtyOutput)
        let resolver = GitStatusResolver(runner: { root, _ in await runner.run(repoRoot: root) }, ttl: 8, now: { clock.now })

        _ = await resolver.status(repoRoot: "/r", branch: "main")
        clock.advance(by: 5)
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 1)  // still inside 8s

        clock.advance(by: 4)  // now 9s past resolution
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 2)
    }

    @Test("a branch switch in the same repo re-resolves ahead/behind")
    func branchKeyed() async {
        let runner = RecordingGitStatusRunner(response: Self.dirtyOutput)
        let resolver = GitStatusResolver(runner: { root, _ in await runner.run(repoRoot: root) })

        _ = await resolver.status(repoRoot: "/r", branch: "main")
        _ = await resolver.status(repoRoot: "/r", branch: "feature")
        #expect(await runner.count() == 2)
    }

    @Test("an absent git runner degrades to no status")
    func absentRunner() async {
        let runner = RecordingGitStatusRunner(response: nil)
        let resolver = GitStatusResolver(runner: { root, _ in await runner.run(repoRoot: root) })
        #expect(await resolver.status(repoRoot: "/r", branch: "main") == nil)
    }

    @Test("ahead/behind are dropped when git reports a different branch (TOCTOU)")
    func branchMismatchDropsAheadBehind() async {
        // git's HEAD moved between make() keying on `main` and status running, so
        // the output is for `feature-x`. Ahead/behind must not be painted under the
        // `main` chip; the dirty count (working-tree-wide) stays.
        let output = porcelain(
            "# branch.head feature-x",
            "# branch.ab +5 -2",
            "? new.txt"
        )
        let runner = RecordingGitStatusRunner(response: output)
        let resolver = GitStatusResolver(runner: { root, _ in await runner.run(repoRoot: root) })

        let info = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(info?.dirtyCount == 1)
        #expect(info?.ahead == 0)
        #expect(info?.behind == 0)
    }
}

// MARK: - Command runner drain

@MainActor
@Suite("Bounded command runner")
struct BoundedCommandRunnerTests {
    @Test("stdout larger than the pipe buffer is fully drained, not deadlocked")
    func drainsLargeStdout() async throws {
        let directory = NSTemporaryDirectory()
        let path = directory + "pathbar-large-\(UUID().uuidString).txt"
        // 200 KB — well past the ~64 KB pipe buffer that a read-after-exit would
        // deadlock on.
        let payload = String(repeating: "X", count: 200_000)
        try payload.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = BoundedCommandRunner(executableCandidates: ["/bin/cat"])
        let result = await runner.run(arguments: [path], inDirectory: directory)
        #expect(result == .complete(Data(repeating: UInt8(ascii: "X"), count: 200_000)))
    }

    @Test("a missing executable degrades to failed")
    func missingExecutable() async {
        let runner = BoundedCommandRunner(executableCandidates: ["/nonexistent/tool-\(UUID().uuidString)"])
        #expect(await runner.run(arguments: [], inDirectory: NSTemporaryDirectory()) == .failed)
    }

    @Test("output at the cap boundary reports complete vs truncated explicitly")
    func truncationIsExplicitAtCapBoundary() async throws {
        let directory = NSTemporaryDirectory()
        let underPath = directory + "pathbar-under-\(UUID().uuidString).txt"
        let exactPath = directory + "pathbar-exact-\(UUID().uuidString).txt"
        let overPath = directory + "pathbar-over-\(UUID().uuidString).txt"
        let cap = 64
        try String(repeating: "a", count: cap - 1).write(toFile: underPath, atomically: true, encoding: .utf8)
        try String(repeating: "b", count: cap).write(toFile: exactPath, atomically: true, encoding: .utf8)
        try String(repeating: "c", count: cap + 1).write(toFile: overPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: underPath)
            try? FileManager.default.removeItem(atPath: exactPath)
            try? FileManager.default.removeItem(atPath: overPath)
        }

        let runner = BoundedCommandRunner(
            executableCandidates: ["/bin/cat"],
            maxOutputBytes: cap
        )

        #expect(
            await runner.run(arguments: [underPath], inDirectory: directory)
                == .complete(Data(repeating: UInt8(ascii: "a"), count: cap - 1))
        )
        #expect(
            await runner.run(arguments: [exactPath], inDirectory: directory)
                == .complete(Data(repeating: UInt8(ascii: "b"), count: cap))
        )
        let over = await runner.run(arguments: [overPath], inDirectory: directory)
        #expect(over == .truncated(prefix: Data(repeating: UInt8(ascii: "c"), count: cap)))
        #expect(over.completeData == nil)
        #expect(over.dataAllowingTruncation?.count == cap)
    }

    @Test("a child that exits while a descendant holds stdout resolves bounded to failed")
    func descendantHoldingStdoutDoesNotHang() async {
        // `sh` exits immediately but backgrounds a short `sleep`, which inherits
        // stdout and holds the pipe open, so EOF never arrives. The runner must
        // resolve via its post-exit grace (not block on the sleep) — and to
        // `.failed`, since without EOF the output can't be confirmed complete.
        // The sleep is kept short so the test leaves nothing meaningful behind.
        let scheduler = TestScheduler()
        let runner = BoundedCommandRunner(
            executableCandidates: ["/bin/sh"],
            delay: { duration in
                await scheduler.wait(for: duration)
                try Task.checkCancellation()
            }
        )
        let run = Task {
            await runner.run(arguments: ["-c", "sleep 3 &"], inDirectory: NSTemporaryDirectory())
        }

        #expect(await waitUntil { scheduler.requestedDurations.contains(.milliseconds(500)) })
        scheduler.advanceOneCycle()
        #expect(await run.value == .failed)  // undrained → unknown, not a partial result
    }

    @Test("cancellation resolves the run as failed")
    func cancellationResolvesFailed() async {
        // `sleep` dies on the cancel-path SIGTERM; advance any pending
        // timeout/grace waits so a slow exit cannot hang the suite. The
        // SIGTERM→SIGKILL escalation for a TERM-ignoring child is covered by
        // the production `Task.detached` grace path and is not asserted here —
        // staging a reliable ignore-TERM child races the trap setup under the
        // test scheduler.
        let scheduler = TestScheduler()
        let runner = BoundedCommandRunner(
            executableCandidates: ["/bin/sleep"],
            timeout: .seconds(60),
            delay: { duration in
                await scheduler.wait(for: duration)
                try Task.checkCancellation()
            }
        )
        let run = Task {
            await runner.run(arguments: ["30"], inDirectory: NSTemporaryDirectory())
        }

        #expect(await waitUntil { scheduler.requestedDurations.first == .seconds(60) })
        run.cancel()
        for _ in 0..<4 { scheduler.advanceOneCycle() }
        #expect(await run.value == .failed)
    }

    @Test("a child that outlives the timeout is killed and yields failed")
    func timeoutTerminatesChild() async {
        // `sleep 30` never exits on its own; the 1s timeout must SIGTERM/SIGKILL it
        // and resolve `.failed` well before the sleep would end.
        let scheduler = TestScheduler()
        let runner = BoundedCommandRunner(
            executableCandidates: ["/bin/sleep"],
            timeout: .seconds(1),
            delay: { duration in
                await scheduler.wait(for: duration)
                try Task.checkCancellation()
            }
        )
        let run = Task {
            await runner.run(arguments: ["30"], inDirectory: NSTemporaryDirectory())
        }

        #expect(await waitUntil { scheduler.requestedDurations.first == .seconds(1) })
        scheduler.advanceOneCycle()
        #expect(await run.value == .failed)
        scheduler.advanceOneCycle()
    }
}
