import Testing
@testable import AwesoMuxCore

@Suite("CommentResolutionTracker")
struct CommentResolutionTrackerTests {
    @Test("initial comment-free load does not start a settle window")
    func initialEmptyDoesNotFire() {
        var tracker = CommentResolutionTracker()
        #expect(tracker.observe(commentCount: 0) == false)
        #expect(tracker.confirmResolve() == false)
    }

    @Test("initial load with comments does not start a settle window")
    func initialWithCommentsDoesNotFire() {
        var tracker = CommentResolutionTracker()
        #expect(tracker.observe(commentCount: 3) == false)
        #expect(tracker.confirmResolve() == false)
    }

    @Test("dropping to zero starts a settle window and confirms once settled")
    func resolveTransitionFires() {
        var tracker = CommentResolutionTracker()
        #expect(tracker.observe(commentCount: 2) == false) // initial load
        #expect(tracker.observe(commentCount: 0) == true)  // settle window opens
        #expect(tracker.confirmResolve() == true)          // settled -> show
    }

    @Test("a 2 -> 0 -> 2 bounce inside the settle window produces no fire")
    func bounceInsideSettleWindowDoesNotFire() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 2)
        #expect(tracker.observe(commentCount: 0) == true)  // transient zero
        #expect(tracker.observe(commentCount: 2) == false) // comments are back
        // The settle timer firing after the bounce must not show the notice.
        #expect(tracker.confirmResolve() == false)
    }

    @Test("confirm is one-shot: a second timer fire cannot re-show")
    func confirmIsOneShot() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 1)
        _ = tracker.observe(commentCount: 0)
        #expect(tracker.confirmResolve() == true)
        #expect(tracker.confirmResolve() == false)
    }

    @Test("staying at zero after a resolve does not open another window")
    func staysAtZeroDoesNotRefire() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 1)
        #expect(tracker.observe(commentCount: 0) == true)
        #expect(tracker.confirmResolve() == true)
        // A later reload that is still comment-free must not re-announce.
        #expect(tracker.observe(commentCount: 0) == false)
        #expect(tracker.confirmResolve() == false)
    }

    @Test("repeated zero reloads inside the settle window keep it open")
    func repeatedZeroKeepsWindowOpen() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 2)
        #expect(tracker.observe(commentCount: 0) == true)
        // e.g. the watcher fires twice for one non-atomic write, both reads zero.
        #expect(tracker.observe(commentCount: 0) == false)
        #expect(tracker.confirmResolve() == true)
    }

    @Test("a partial reduction that does not reach zero does not fire")
    func partialReductionDoesNotFire() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 3)
        #expect(tracker.observe(commentCount: 1) == false)
        #expect(tracker.confirmResolve() == false)
    }

    @Test("comments reappearing then resolving again fires again")
    func reAddThenResolveFiresAgain() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 2)
        #expect(tracker.observe(commentCount: 0) == true)
        #expect(tracker.confirmResolve() == true)           // first resolve
        #expect(tracker.observe(commentCount: 1) == false)  // a new comment
        #expect(tracker.observe(commentCount: 0) == true)   // resolved again
        #expect(tracker.confirmResolve() == true)
    }

    @Test("going from zero up to comments never fires")
    func zeroToCommentsNeverFires() {
        var tracker = CommentResolutionTracker()
        _ = tracker.observe(commentCount: 0) // initial empty
        #expect(tracker.observe(commentCount: 2) == false)
        #expect(tracker.confirmResolve() == false)
    }
}
