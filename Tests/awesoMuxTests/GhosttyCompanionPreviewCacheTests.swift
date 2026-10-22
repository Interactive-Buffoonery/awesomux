import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Companion native preview cache")
struct GhosttyCompanionPreviewCacheTests {
    @Test func coalescesBurstsAndExpiresAt500Milliseconds() {
        var cache = GhosttyCompanionPreviewCache()
        let now = ContinuousClock.now
        var reads = 0
        func read() -> String? { reads += 1; return "old\nlast\u{202E}" }
        #expect(cache.get(source: 1, now: now, readScreen: read) == "last")
        #expect(cache.get(source: 1, now: now + .milliseconds(499), readScreen: read) == "last")
        #expect(reads == 1)
        #expect(cache.get(source: 1, now: now + .milliseconds(500), readScreen: read) == "last")
        #expect(reads == 2)
    }

    @Test func coalescesNilSamplesAndRetainsOnlyBoundedPreview() {
        var cache = GhosttyCompanionPreviewCache()
        let now = ContinuousClock.now
        var reads = 0
        #expect(
            cache.get(source: 1, now: now) {
                reads += 1; return nil
            } == nil)
        #expect(
            cache.get(source: 1, now: now + .milliseconds(499)) {
                reads += 1; return "unexpected"
            } == nil)
        #expect(reads == 1)
        let preview = cache.get(source: 1, now: now + .milliseconds(500)) { "history\n" + String(repeating: "x", count: 1000) }
        #expect(preview == String(repeating: "x", count: 512))
    }

    @Test func replacementAndTeardownDiscardPreviousContent() {
        var cache = GhosttyCompanionPreviewCache()
        let now = ContinuousClock.now
        #expect(cache.get(source: 1, now: now) { "old" } == "old")
        #expect(cache.get(source: 2, now: now) { "replacement" } == "replacement")
        #expect(
            cache.get(source: nil, now: now) {
                Issue.record("Detached surface must not read"); return "unexpected"
            } == nil)
        #expect(cache.get(source: 2, now: now) { "reattached" } == "reattached")
        cache.invalidate()
        #expect(cache.get(source: 2, now: now) { "after teardown" } == "after teardown")
        let replacementViewCache = GhosttyCompanionPreviewCache()
        var other = replacementViewCache
        #expect(other.get(source: 2, now: now) { "other view" } == "other view")
    }
}
