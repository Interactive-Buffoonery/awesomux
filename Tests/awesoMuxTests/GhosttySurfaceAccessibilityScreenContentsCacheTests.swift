import Foundation
import Testing
@testable import awesoMux

@Suite("GhosttySurfaceAccessibilityScreenContentsCache")
@MainActor
struct GhosttySurfaceAccessibilityScreenContentsCacheTests {
    @Test("first get() always fetches")
    func firstGetFetches() {
        var cache = GhosttySurfaceAccessibilityScreenContentsCache()
        var fetchCount = 0

        let result = cache.get {
            fetchCount += 1
            return "hello"
        }

        #expect(result == "hello")
        #expect(fetchCount == 1)
    }

    @Test("a second get() within the expiry window reuses the cached value")
    func withinWindowReusesCachedValue() {
        var cache = GhosttySurfaceAccessibilityScreenContentsCache()
        var fetchCount = 0
        let start = ContinuousClock.now

        _ = cache.get(now: start) {
            fetchCount += 1
            return "first read"
        }

        // Simulate a burst of accessor calls (numberOfCharacters,
        // visibleCharacterRange, line(for:), string(for:)) landing within
        // one VoiceOver navigation step, well inside the 500ms window.
        let secondResult = cache.get(now: start + .milliseconds(50)) {
            fetchCount += 1
            return "second read"
        }
        let thirdResult = cache.get(now: start + .milliseconds(400)) {
            fetchCount += 1
            return "third read"
        }

        #expect(secondResult == "first read")
        #expect(thirdResult == "first read")
        #expect(fetchCount == 1)
    }

    @Test("get() after the expiry window re-fetches")
    func afterWindowRefetches() {
        var cache = GhosttySurfaceAccessibilityScreenContentsCache()
        var fetchCount = 0
        let start = ContinuousClock.now

        _ = cache.get(now: start) {
            fetchCount += 1
            return "first read"
        }

        let result = cache.get(now: start + GhosttySurfaceAccessibilityScreenContentsCache.duration + .milliseconds(1)) {
            fetchCount += 1
            return "second read"
        }

        #expect(result == "second read")
        #expect(fetchCount == 2)
    }

    @Test("invalidate() forces the next get() to re-fetch even inside the window")
    func invalidateForcesRefetch() {
        var cache = GhosttySurfaceAccessibilityScreenContentsCache()
        var fetchCount = 0
        let start = ContinuousClock.now

        _ = cache.get(now: start) {
            fetchCount += 1
            return "first read"
        }

        cache.invalidate()

        let result = cache.get(now: start + .milliseconds(10)) {
            fetchCount += 1
            return "second read"
        }

        #expect(result == "second read")
        #expect(fetchCount == 2)
    }
}
