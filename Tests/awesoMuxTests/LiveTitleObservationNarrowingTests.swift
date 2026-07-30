import AwesoMuxCore
import Foundation
import Observation
import Testing

@testable import awesoMux

/// Issue #315: a pane title bar must observe only its OWN pane's live title.
///
/// Observation tracks per property, so while every pane's title lived in one
/// dictionary a sibling pane's spinner frame re-ran every other pane's
/// `LiveTitleScope` — the child `.equatable()` gates rejected the work, but the
/// scope evaluation, the `LiveTitles` construction and the comparison were all
/// paid, O(P²) across P animating panes.
///
/// Every test here tracks `LiveTitles(box:reads:)` — the exact expression
/// `LiveTitleScope.body` evaluates — rather than a hand-rolled stand-in, so a
/// narrowing that only holds for a test-shaped read cannot pass.
@MainActor
@Suite("Live title observation narrowing (#315)")
struct LiveTitleObservationNarrowingTests {

    // MARK: - The narrowing itself

    @Test("a sibling pane's title report does not wake a pane-scoped read")
    func siblingPaneReportDoesNotWakePaneScope() throws {
        let fixture = try makeSplitFixture()
        // Both channels exist before tracking starts, so a wake can only come
        // from a title write and never from storage being seeded.
        #expect(fixture.box.paneTitles[fixture.paneA] != nil)
        #expect(fixture.box.paneTitles[fixture.paneB] != nil)

        let woken = TrackingFlag()
        var observed: LiveTitles?
        withObservationTracking {
            observed = LiveTitles(box: fixture.box, reads: .paneTitle(fixture.paneB))
        } onChange: {
            woken.set()
        }

        // Anti-vacuity: the scope must have resolved pane B's live title. An
        // implementation that resolves nothing falls back to the session struct
        // and yields an empty map — and would pass the wake assertion below by
        // observing nothing at all, which is exactly how #311's box shipped
        // shadowed by 17 green tests.
        #expect(observed?.panes[fixture.paneB] != nil)

        let published = TrackingFlag()
        withObservationTracking {
            _ = fixture.store.groups
        } onChange: {
            published.set()
        }

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneA,
            title: "cargo build"
        )

        // Anti-vacuity: the sibling write has to take the SILENT branch, or
        // this test is a tautology — a publishing write re-renders the whole
        // tree and wakes the scope through its parent whatever the box did.
        #expect(!published.value)
        #expect(fixture.box.paneTitles[fixture.paneA] == "cargo build")

        #expect(!woken.value)
    }

    @Test("a pane's own title report wakes its pane-scoped read")
    func ownPaneReportWakesPaneScope() throws {
        let fixture = try makeSplitFixture()
        #expect(fixture.box.paneTitles[fixture.paneB] != nil)

        let woken = TrackingFlag()
        var observed: LiveTitles?
        withObservationTracking {
            observed = LiveTitles(box: fixture.box, reads: .paneTitle(fixture.paneB))
        } onChange: {
            woken.set()
        }
        #expect(observed?.panes[fixture.paneB] != nil)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneB,
            title: "cargo build"
        )

        #expect(woken.value)
        #expect(fixture.box.paneTitles[fixture.paneB] == "cargo build")
    }

    // MARK: - The narrowing did not overshoot

    @Test("an everything-scoped read is still woken by any pane's report")
    func everythingScopeIsWokenByAnyPaneReport() throws {
        let fixture = try makeSplitFixture()

        let woken = TrackingFlag()
        var observed: LiveTitles?
        withObservationTracking {
            observed = LiveTitles(box: fixture.box, reads: .everything)
        } onChange: {
            woken.set()
        }
        // A sidebar row keys every pane, so it has to see them all.
        #expect(observed?.panes.count == 2)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneA,
            title: "cargo build"
        )

        #expect(woken.value)
    }

    @Test("a workspace-scoped read is not woken by an inactive pane's report")
    func workspaceScopeIsNotWokenByInactivePaneReport() throws {
        let fixture = try makeSplitFixture()

        let woken = TrackingFlag()
        withObservationTracking {
            _ = LiveTitles(box: fixture.box, reads: .workspaceTitle)
        } onChange: {
            woken.set()
        }

        // Pane A is inactive after the split, so the workspace title does not
        // follow its live title.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneA,
            title: "cargo build"
        )

        #expect(!woken.value)
    }

    // MARK: - Freeze gates

    /// Per-pane storage only pays off while a pane keeps the SAME observable
    /// across refreshes. If a refresh replaced it, every already-registered
    /// scope would be invalidated and re-register on the replacement — no
    /// freeze, because the roster itself is observable, but the entire
    /// narrowing would be silently undone with every correctness test still
    /// green. This is the only gate that catches that.
    @Test("a publishing mutation that moves no title does not wake a pane-scoped read")
    func publishingMutationWithoutTitleMoveDoesNotWakePaneScope() throws {
        let fixture = try makeSplitFixture()

        let woken = TrackingFlag()
        withObservationTracking {
            _ = LiveTitles(box: fixture.box, reads: .paneTitle(fixture.paneB))
        } onChange: {
            woken.set()
        }

        let published = TrackingFlag()
        withObservationTracking {
            _ = fixture.store.groups
        } onChange: {
            published.set()
        }

        // A pane colour change publishes `groups`, so the full re-seed runs
        // over every channel — and it cannot move a title under any future
        // reducer change, which a working-directory report could.
        #expect(
            fixture.store.setPaneColor(
                sessionID: fixture.sessionID,
                paneID: fixture.paneA,
                color: .palette(.teal)
            )
        )

        #expect(published.value)
        #expect(!woken.value)
    }

    /// A pane-scoped read that resolves nothing renders from the session struct
    /// and must still hold a dependency, or it can never learn that live titles
    /// became available for it — a permanently frozen title bar rather than a
    /// one-frame lag, because the channel is preferred over the struct wherever
    /// one exists.
    @Test("a pane-scoped read that resolved nothing is woken when THAT pane's channel appears")
    func paneScopeWithoutStoredTitleIsWokenWhenItsOwnChannelAppears() throws {
        let fixture = try makeSplitFixture()
        // A restore is the one path that names a pane the box has never seen
        // while keeping the session — and therefore the box, and therefore any
        // scope already registered on it — alive. It is also the only way this
        // test can know the future pane's ID in advance, which is what makes it
        // a gate on the REQUESTED pane rather than on "some dictionary write
        // woke a missing-key reader".
        let arriving = TerminalPane(title: "restored pane", workingDirectory: "~", executionPlan: .local)

        let woken = TrackingFlag()
        var observed: LiveTitles?
        withObservationTracking {
            observed = LiveTitles(box: fixture.box, reads: .paneTitle(arriving.id))
        } onChange: {
            woken.set()
        }
        #expect(observed?.panes.isEmpty == true)

        var session = try #require(fixture.store.session(id: fixture.sessionID))
        session.layout = .pane(arriving)
        session.activePaneID = arriving.id
        _ = fixture.store.replaceState(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id,
                recentlyClosed: [],
                pinnedSessionIDs: []
            )
        )

        #expect(woken.value)
        // …and the read now resolves that pane's own title, so the scope has
        // actually moved off the struct fallback and onto its channel.
        #expect(
            LiveTitles(box: fixture.box, reads: .paneTitle(arriving.id)).panes[arriving.id]
                == "restored pane"
        )
    }

    // MARK: - Helpers

    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        /// Inactive after the split, so its reports move nothing but its own
        /// pane title — which is what makes it a clean sibling.
        let paneA: TerminalPane.ID
        let paneB: TerminalPane.ID
        let box: LiveTitleBox
    }

    /// Stable IDs throughout: a fixture that mints a fresh UUID per lookup keeps
    /// every keyed assertion green with the field under test deleted.
    private func makeSplitFixture() throws -> Fixture {
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let paneB = try #require(store.splitActivePane(orientation: .horizontal, in: session.id))
        return Fixture(
            store: store,
            sessionID: session.id,
            paneA: pane.id,
            paneB: paneB,
            box: store.liveTitleBox(for: session.id)
        )
    }
}

private final class TrackingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}
