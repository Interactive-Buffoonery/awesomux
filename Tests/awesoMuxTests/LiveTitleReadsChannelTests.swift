import AwesoMuxCore
import Foundation
import Observation
import Testing

@testable import awesoMux

/// `LiveTitleReads` picks the observation CHANNEL, not just which fields get
/// copied out: `.paneTitle` registers a dependency on the fine-grained
/// properties and repaints on every OSC report, while `.everything` — the
/// sidebar rows — registers on the ~1 Hz coarse mirror and does not.
///
/// Asserted with `withObservationTracking` because that is the only place the
/// distinction is real. Copying the right *value* out would still repaint the
/// sidebar at spinner rate if the read registered the wrong property, and no
/// value assertion can tell those apart.
@MainActor
@Suite("LiveTitleReads — fine and coarse channels")
struct LiveTitleReadsChannelTests {

    @Test("a coalesced title tick wakes .paneTitle but not .everything")
    func coalescedTickWakesFineChannelOnly() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Consume the coarse leading edge. Without this the tick below is a
        // legitimate coarse publish and the test asserts nothing.
        fixture.retitle("frame 0", now: base)

        let everythingWoke = Flag()
        let paneTitleWoke = Flag()
        withObservationTracking {
            _ = LiveTitles(box: box, reads: .everything)
        } onChange: {
            everythingWoke.set()
        }
        withObservationTracking {
            _ = LiveTitles(box: box, reads: .paneTitle(fixture.paneID))
        } onChange: {
            paneTitleWoke.set()
        }

        fixture.retitle("frame 1", now: base.addingTimeInterval(0.2))

        // The pane title bar repaints — an agent spinner has to animate.
        #expect(paneTitleWoke.value)
        // The sidebar row does not. This is the recovered work.
        #expect(!everythingWoke.value)
    }

    @Test("a tick past the coalescing window wakes .everything")
    func tickPastTheWindowWakesTheCoarseChannel() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.retitle("frame 0", now: base)

        let everythingWoke = Flag()
        withObservationTracking {
            _ = LiveTitles(box: box, reads: .everything)
        } onChange: {
            everythingWoke.set()
        }

        fixture.retitle(
            "frame 1",
            now: base.addingTimeInterval(LiveTitleBox.coarseCoalescingInterval)
        )

        // The control for the test above: `.everything` is throttled, not
        // unsubscribed.
        #expect(everythingWoke.value)
    }

    @Test("a rename wakes .everything from inside the coalescing window")
    func renameWakesTheCoarseChannelInsideTheWindow() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.retitle("frame 0", now: base)

        let everythingWoke = Flag()
        withObservationTracking {
            _ = LiveTitles(box: box, reads: .everything)
        } onChange: {
            everythingWoke.set()
        }

        // Same window as `frame 0`, so a coalesced rename would leave the
        // sidebar naming the workspace by its old title until something else
        // happened to publish — which nothing is obliged to do.
        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        #expect(everythingWoke.value)
        #expect(LiveTitles(box: box, reads: .everything).workspace == "release prep")
    }

    // MARK: - Fixture

    /// Lock-guarded rather than a bare `var` behind `@unchecked Sendable`:
    /// `withObservationTracking`'s `onChange` is `@Sendable`, so the promise has
    /// to be earned. Same shape as `TrackingFlag` in `AwesoMuxCoreTests`.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.withLock { storage } }
        func set() { lock.withLock { storage = true } }
    }

    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID

        @MainActor
        func retitle(_ title: String, now: Date) {
            store.updatePane(sessionID: sessionID, paneID: paneID, title: title, now: now)
        }
    }

    /// IDs come from the values the store was built with, so the pane the
    /// assertions key off is the pane the writes land on.
    private func makeFixture() -> Fixture {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: "~",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        return Fixture(store: store, sessionID: session.id, paneID: pane.id)
    }
}
