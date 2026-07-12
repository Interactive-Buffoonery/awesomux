import Foundation
import Testing
@testable import awesoMux

// MARK: - Helpers

private func ghJSON(
    number: Int = 7,
    url: String = "https://github.com/owner/repo/pull/7",
    state: String = "OPEN",
    isDraft: Bool = false,
    reviewDecision: String? = ""
) -> Data {
    var object: [String: Any] = [
        "number": number,
        "url": url,
        "state": state,
        "isDraft": isDraft,
        "reviewDecision": reviewDecision as Any? ?? NSNull(),
    ]
    if reviewDecision == nil {
        object["reviewDecision"] = NSNull()
    }
    return try! JSONSerialization.data(withJSONObject: object)
}

/// Test clock with a mutable "now"; safe to read from the resolver's `@Sendable`
/// closure while a test advances it.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    var date: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); current += interval; lock.unlock()
    }
}

/// Records how many times it ran and returns a fixed payload, optionally after a
/// short delay so concurrent callers genuinely overlap.
private actor RecordingRunner {
    private(set) var callCount = 0
    private let response: Data?
    private let delay: Duration?

    init(response: Data?, delay: Duration? = nil) {
        self.response = response
        self.delay = delay
    }

    func run(repoRoot: String, branch: String) async -> Data? {
        callCount += 1
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return response
    }

    func count() -> Int { callCount }
}

/// Runs calls in order, returning a scripted response per call index, and lets a
/// test hold individual calls "in flight" until explicitly released — enough to
/// drive the evict-while-in-flight + refetch race deterministically.
private actor ScriptedRunner {
    private let responses: [Data?]
    private var callCount = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    init(responses: [Data?]) {
        self.responses = responses
    }

    func run(repoRoot: String, branch: String) async -> Data? {
        let index = callCount
        callCount += 1
        if !released.contains(index) {
            await withCheckedContinuation { gates[index] = $0 }
        }
        return index < responses.count ? responses[index] : nil
    }

    func release(call index: Int) {
        released.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }

    func count() -> Int { callCount }

    func waitUntilStarted(_ n: Int) async {
        while callCount < n {
            await Task.yield()
        }
    }
}

// MARK: - Parser

@Suite("Pull request parsing")
struct PullRequestInfoParsingTests {
    @Test("open PR with no review decision reads as open")
    func openPR() throws {
        let info = try #require(PullRequestInfo(parsingGhJSON: ghJSON(reviewDecision: "")))
        #expect(info.number == 7)
        #expect(info.url.absoluteString == "https://github.com/owner/repo/pull/7")
        #expect(info.state == .open)
    }

    @Test("draft PR reads as draft regardless of review decision")
    func draftPR() throws {
        let info = try #require(
            PullRequestInfo(parsingGhJSON: ghJSON(isDraft: true, reviewDecision: "REVIEW_REQUIRED"))
        )
        #expect(info.state == .draft)
    }

    @Test("review-required PR reads as in review")
    func reviewRequired() throws {
        let info = try #require(PullRequestInfo(parsingGhJSON: ghJSON(reviewDecision: "REVIEW_REQUIRED")))
        #expect(info.state == .inReview)
    }

    @Test("changes-requested PR reads as in review")
    func changesRequested() throws {
        let info = try #require(PullRequestInfo(parsingGhJSON: ghJSON(reviewDecision: "CHANGES_REQUESTED")))
        #expect(info.state == .inReview)
    }

    @Test("approved PR reads as open")
    func approved() throws {
        let info = try #require(PullRequestInfo(parsingGhJSON: ghJSON(reviewDecision: "APPROVED")))
        #expect(info.state == .open)
    }

    @Test("null review decision reads as open")
    func nullReviewDecision() throws {
        let info = try #require(PullRequestInfo(parsingGhJSON: ghJSON(reviewDecision: nil)))
        #expect(info.state == .open)
    }

    @Test("closed PR yields no chip")
    func closedPR() {
        #expect(PullRequestInfo(parsingGhJSON: ghJSON(state: "CLOSED")) == nil)
    }

    @Test("merged PR yields no chip")
    func mergedPR() {
        #expect(PullRequestInfo(parsingGhJSON: ghJSON(state: "MERGED")) == nil)
    }

    @Test("non-https URL is rejected")
    func nonHTTPSURL() {
        #expect(PullRequestInfo(parsingGhJSON: ghJSON(url: "file:///etc/passwd")) == nil)
        #expect(PullRequestInfo(parsingGhJSON: ghJSON(url: "javascript:alert(1)")) == nil)
        #expect(PullRequestInfo(parsingGhJSON: ghJSON(url: "http://github.com/o/r/pull/7")) == nil)
    }

    @Test("malformed JSON yields no chip")
    func malformedJSON() {
        #expect(PullRequestInfo(parsingGhJSON: Data("not json".utf8)) == nil)
        #expect(PullRequestInfo(parsingGhJSON: Data()) == nil)
    }
}

// MARK: - Resolver

@Suite("Pull request resolver")
struct PullRequestResolverTests {
    @Test("a cache hit within TTL does not re-run the lookup")
    func cacheHit() async {
        let runner = RecordingRunner(response: ghJSON())
        let resolver = PullRequestResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })

        let first = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        let second = await resolver.pullRequest(repoRoot: "/repo", branch: "main")

        #expect(first?.number == 7)
        #expect(second?.number == 7)
        #expect(await runner.count() == 1)
    }

    @Test("concurrent callers for the same branch coalesce onto one lookup")
    func coalescesInFlight() async {
        let runner = RecordingRunner(response: ghJSON(), delay: .milliseconds(50))
        let resolver = PullRequestResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })

        async let a = resolver.pullRequest(repoRoot: "/repo", branch: "main")
        async let b = resolver.pullRequest(repoRoot: "/repo", branch: "main")
        _ = await (a, b)

        #expect(await runner.count() == 1)
    }

    @Test("a positive result re-resolves after the positive TTL")
    func positiveTTLExpiry() async {
        let clock = MutableClock()
        let runner = RecordingRunner(response: ghJSON())
        let resolver = PullRequestResolver(
            runner: { await runner.run(repoRoot: $0, branch: $1) },
            positiveTTL: 90,
            negativeTTL: 20,
            now: { clock.date }
        )

        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        clock.advance(by: 60)
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        #expect(await runner.count() == 1) // still inside 90s

        clock.advance(by: 31) // now 91s past resolution
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        #expect(await runner.count() == 2)
    }

    @Test("a negative result re-resolves on the shorter negative TTL")
    func negativeTTLExpiry() async {
        let clock = MutableClock()
        let runner = RecordingRunner(response: nil)
        let resolver = PullRequestResolver(
            runner: { await runner.run(repoRoot: $0, branch: $1) },
            positiveTTL: 90,
            negativeTTL: 20,
            now: { clock.date }
        )

        #expect(await resolver.pullRequest(repoRoot: "/repo", branch: "main") == nil)
        clock.advance(by: 10)
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        #expect(await runner.count() == 1) // inside 20s

        clock.advance(by: 11) // 21s — negative entry expired sooner than positive would
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "main")
        #expect(await runner.count() == 2)
    }

    @Test("an absent gh runner degrades to no chip")
    func absentRunner() async {
        let runner = RecordingRunner(response: nil)
        let resolver = PullRequestResolver(runner: { await runner.run(repoRoot: $0, branch: $1) })
        #expect(await resolver.pullRequest(repoRoot: "/repo", branch: "main") == nil)
    }

    @Test("the production gh runner degrades to nil for an invalid repo")
    func productionRunnerDegradesGracefully() async {
        // Exercises the real Process path end to end. With a nonexistent cwd the
        // spawn fails fast (or gh exits non-zero / is absent) — every branch must
        // resolve to nil rather than throw or hang.
        let runner = GhPullRequestCommandRunner()
        let result = await runner.run(
            repoRoot: "/nonexistent-\(UUID().uuidString)",
            branch: "main"
        )
        #expect(result == nil)
    }

    @Test("an evicted in-flight lookup cannot clobber a refetched entry's TTL")
    func evictedInFlightDoesNotClobber() async {
        let clock = MutableClock()
        // call 0 = A1 (positive, held in flight), 1 = B (negative), 2 = A2
        // (negative, held in flight), 3 = A re-lookup (negative).
        let runner = ScriptedRunner(responses: [ghJSON(), nil, nil, nil])
        let resolver = PullRequestResolver(
            runner: { await runner.run(repoRoot: $0, branch: $1) },
            positiveTTL: 90,
            negativeTTL: 20,
            cacheCap: 1,
            now: { clock.date }
        )

        // A1 in flight.
        let a1 = Task { await resolver.pullRequest(repoRoot: "/r", branch: "a") }
        await runner.waitUntilStarted(1)

        // B fills the single cache slot, evicting in-flight A1.
        await runner.release(call: 1)
        _ = await resolver.pullRequest(repoRoot: "/r", branch: "b")

        // A2 (a fresh entry for the same key) goes in flight.
        let a2 = Task { await resolver.pullRequest(repoRoot: "/r", branch: "a") }
        await runner.waitUntilStarted(3)

        // A1 completes now — its (positive) result targets the key that A2 owns.
        // The identity guard must reject it so A2 keeps its own (negative) polarity.
        await runner.release(call: 0)
        _ = await a1.value
        await runner.release(call: 2)
        _ = await a2.value

        // A2 is negative → expires on the 20s negative TTL. If A1's positive had
        // clobbered it, the entry would carry the 90s positive TTL and survive.
        await runner.release(call: 3) // let the re-fetch complete
        clock.advance(by: 30)
        _ = await resolver.pullRequest(repoRoot: "/r", branch: "a")
        #expect(await runner.count() == 4) // re-fetched → guard held
    }

    @Test("least-recently-used entries are evicted past the cap")
    func lruEviction() async {
        let runner = RecordingRunner(response: ghJSON())
        let resolver = PullRequestResolver(runner: { await runner.run(repoRoot: $0, branch: $1) }, cacheCap: 2)

        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "a") // count 1
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "b") // count 2
        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "c") // count 3, evicts "a"
        #expect(await runner.count() == 3)

        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "a") // re-fetch, count 4
        #expect(await runner.count() == 4)

        _ = await resolver.pullRequest(repoRoot: "/repo", branch: "c") // still cached, no new run
        #expect(await runner.count() == 4)
    }
}
