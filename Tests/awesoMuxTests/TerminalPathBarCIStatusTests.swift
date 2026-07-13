import Foundation
import Testing
import AwesoMuxTestSupport
@testable import awesoMux

// MARK: - Helpers

private actor RecordingCIStatusRunner {
    private(set) var callCount = 0
    private let response: Data?

    init(response: Data?) {
        self.response = response
    }

    func run(repoRoot: String, branch: String) async -> Data? {
        callCount += 1
        return response
    }

    func count() -> Int { callCount }
}

/// One run object as `gh run list --json …` emits it (always wrapped in an array).
private func runJSON(
    status: String,
    conclusion: String?,
    databaseId: Int = 42,
    url: String? = nil,
    workflowName: String = "Swift CI"
) -> Data {
    // Default the URL to a well-formed github.com run URL whose id matches
    // databaseId, so the strict slug derivation succeeds unless a test overrides it.
    let runURL = url ?? "https://github.com/o/r/actions/runs/\(databaseId)"
    let conclusionField = conclusion.map { "\"\($0)\"" } ?? "null"
    let json = """
        [{"databaseId":\(databaseId),"status":"\(status)","conclusion":\(conclusionField),\
        "url":"\(runURL)","workflowName":"\(workflowName)"}]
        """
    return Data(json.utf8)
}

// MARK: - Parser

@Suite("CI status parsing")
struct CIStatusInfoParsingTests {
    @Test("an in-progress run parses to .running")
    func runningInProgress() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "in_progress", conclusion: ""))
        #expect(info?.state == .running)
    }

    @Test("a queued run parses to .running")
    func runningQueued() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "queued", conclusion: nil))
        #expect(info?.state == .running)
    }

    @Test("a waiting (deployment-gate) run parses to .running")
    func runningWaiting() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "waiting", conclusion: ""))
        #expect(info?.state == .running)
    }

    @Test("a requested run parses to .running")
    func runningRequested() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "requested", conclusion: ""))
        #expect(info?.state == .running)
    }

    @Test("an unknown / future status yields no chip rather than a guessed .running")
    func unknownStatusSilent() {
        #expect(CIStatusInfo(parsingGhJSON: runJSON(status: "teleported", conclusion: "")) == nil)
    }

    @Test("a null conclusion on a running run still parses (status gates first)")
    func runningNullConclusion() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "in_progress", conclusion: nil))
        #expect(info?.state == .running)
    }

    @Test("a completed failure parses to .failing")
    func failingFailure() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "failure"))
        #expect(info?.state == .failing)
    }

    @Test("a timed-out run parses to .failing")
    func failingTimedOut() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "timed_out"))
        #expect(info?.state == .failing)
    }

    @Test("a startup failure parses to .failing")
    func failingStartupFailure() {
        let info = CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "startup_failure"))
        #expect(info?.state == .failing)
    }

    @Test("a passing run yields no chip")
    func silentSuccess() {
        #expect(CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "success")) == nil)
    }

    @Test("a cancelled run yields no chip")
    func silentCancelled() {
        #expect(CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "cancelled")) == nil)
    }

    @Test("a skipped run yields no chip")
    func silentSkipped() {
        #expect(CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "skipped")) == nil)
    }

    @Test("an action-required run is deliberately silent (two-state design)")
    func silentActionRequired() {
        #expect(CIStatusInfo(parsingGhJSON: runJSON(status: "completed", conclusion: "action_required")) == nil)
    }

    @Test("an empty array (no runs for the branch) yields no chip")
    func silentEmptyArray() {
        #expect(CIStatusInfo(parsingGhJSON: Data("[]".utf8)) == nil)
    }

    @Test("malformed output yields no chip rather than crashing")
    func silentMalformed() {
        #expect(CIStatusInfo(parsingGhJSON: Data("not json".utf8)) == nil)
        #expect(CIStatusInfo(parsingGhJSON: Data()) == nil)
    }

    @Test("a non-https run url is rejected even when failing")
    func nonHTTPSRejected() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "file:///etc/passwd"
            ))
        #expect(info == nil)
    }

    @Test("a run missing databaseId is rejected (decode fails)")
    func missingDatabaseIdRejected() {
        let json = """
            [{"status":"completed","conclusion":"failure","url":"https://github.com/o/r/actions/runs/1"}]
            """
        #expect(CIStatusInfo(parsingGhJSON: Data(json.utf8)) == nil)
    }

    @Test("a large (Int64-scale) run id round-trips")
    func largeRunID() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "in_progress",
                conclusion: "",
                databaseId: 26_372_906_825
            ))
        #expect(info?.runDatabaseID == 26_372_906_825)
    }

    @Test("the workflow name is surfaced for help / a11y")
    func workflowNameParsed() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                workflowName: "Swift CI"
            ))
        #expect(info?.workflowName == "Swift CI")
    }

    @Test("owner/repo is derived from the run url for --repo scoping")
    func repoSlugDerived() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "https://github.com/Interactive-Buffoonery/awesomux/actions/runs/42"
            ))
        #expect(info?.repoSlug == "Interactive-Buffoonery/awesomux")
    }

    @Test("a run url with too few path segments yields a nil slug but still a chip")
    func repoSlugNilButChipShows() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "https://github.com/justone"
            ))
        #expect(info?.state == .failing)
        #expect(info?.repoSlug == nil)
    }

    @Test("an api.github.com url does not mis-derive a `repos/owner` slug")
    func repoSlugRejectsApiHost() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "https://api.github.com/repos/o/r/actions/runs/42"
            ))
        #expect(info?.state == .failing)
        #expect(info?.repoSlug == nil)
    }

    @Test("an enterprise host yields a nil slug (no silent cross-host --repo)")
    func repoSlugRejectsEnterpriseHost() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "https://github.example.com/o/r/actions/runs/42"
            ))
        #expect(info?.state == .failing)
        #expect(info?.repoSlug == nil)
    }

    @Test("a non-run github.com path (e.g. /pull/) yields a nil slug")
    func repoSlugRejectsOffShapePath() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                url: "https://github.com/o/r/pull/5"
            ))
        #expect(info?.state == .failing)
        #expect(info?.repoSlug == nil)
    }

    @Test("a run url whose id doesn't match databaseId yields a nil slug")
    func repoSlugRejectsIdMismatch() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                databaseId: 42,
                url: "https://github.com/o/r/actions/runs/99"
            ))
        #expect(info?.state == .failing)
        #expect(info?.repoSlug == nil)
    }

    @Test("a workflow name carrying a bidi override is sanitized")
    func workflowNameSanitized() {
        let info = CIStatusInfo(
            parsingGhJSON: runJSON(
                status: "completed",
                conclusion: "failure",
                workflowName: "Deploy\u{202E}gnp"
            ))
        #expect(info?.workflowName?.unicodeScalars.contains("\u{202E}") == false)
    }

    @Test("the first array element wins (newest run)")
    func firstElementWins() {
        let json = """
            [{"databaseId":1,"status":"completed","conclusion":"failure","url":"https://github.com/o/r/actions/runs/1","workflowName":"A"},
             {"databaseId":2,"status":"completed","conclusion":"success","url":"https://github.com/o/r/actions/runs/2","workflowName":"B"}]
            """
        let info = CIStatusInfo(parsingGhJSON: Data(json.utf8))
        #expect(info?.state == .failing)
        #expect(info?.runDatabaseID == 1)
    }
}

// MARK: - Resolver

@Suite("CI status resolver")
struct CIStatusResolverTests {
    private static let failing = runJSON(status: "completed", conclusion: "failure")
    private static let running = runJSON(status: "in_progress", conclusion: "")

    @Test("a cache hit within TTL does not re-run gh")
    func cacheHit() async {
        let runner = RecordingCIStatusRunner(response: Self.failing)
        let resolver = CIStatusResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })

        let first = await resolver.status(repoRoot: "/r", branch: "main")
        let second = await resolver.status(repoRoot: "/r", branch: "main")

        #expect(first?.state == .failing)
        #expect(second == first)
        #expect(await runner.count() == 1)
    }

    @Test("a running run re-resolves after the short running TTL (15s)")
    func runningTTLExpiry() async {
        let clock = TestClock()
        let runner = RecordingCIStatusRunner(response: Self.running)
        let resolver = CIStatusResolver(runner: { await runner.run(repoRoot: $0, branch: $1) }, now: { clock.now })

        _ = await resolver.status(repoRoot: "/r", branch: "main")
        clock.advance(by: 10)
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 1)  // still inside 15s

        clock.advance(by: 6)  // now 16s past resolution
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 2)
    }

    @Test("a failing run holds longer than running but still expires at 20s")
    func failingTTLExpiry() async {
        let clock = TestClock()
        let runner = RecordingCIStatusRunner(response: Self.failing)
        let resolver = CIStatusResolver(runner: { await runner.run(repoRoot: $0, branch: $1) }, now: { clock.now })

        _ = await resolver.status(repoRoot: "/r", branch: "main")
        clock.advance(by: 16)  // past running's 15s, inside failing's 20s
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 1)

        clock.advance(by: 5)  // now 21s past resolution
        _ = await resolver.status(repoRoot: "/r", branch: "main")
        #expect(await runner.count() == 2)
    }

    @Test("a branch switch in the same repo re-resolves")
    func branchKeyed() async {
        let runner = RecordingCIStatusRunner(response: Self.failing)
        let resolver = CIStatusResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })

        _ = await resolver.status(repoRoot: "/r", branch: "main")
        _ = await resolver.status(repoRoot: "/r", branch: "feature")
        #expect(await runner.count() == 2)
    }

    @Test("an absent gh runner degrades to no status")
    func absentRunner() async {
        let runner = RecordingCIStatusRunner(response: nil)
        let resolver = CIStatusResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })
        #expect(await resolver.status(repoRoot: "/r", branch: "main") == nil)
    }
}
