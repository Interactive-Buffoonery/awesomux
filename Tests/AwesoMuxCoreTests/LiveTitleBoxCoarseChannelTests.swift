import Foundation
import Observation
import Testing

@testable import AwesoMuxCore

/// The coarse half of the live-title channel: the sidebar rows read a mirror
/// published only when the STORE's per-session coalescing gate fires
/// (`SessionStore.tickLiveTitle` — the same timestamp check that bumps
/// `liveTitleGeneration`, issue #327), while the pane title bars keep reading
/// the fine-grained properties on every report.
///
/// Every test drives a real `SessionStore` write rather than poking the box, and
/// every one passes an explicit `now`, so the coalescing window is crossed by
/// arithmetic and never by waiting.
///
/// The load-bearing case is `renameRefreshesCoarseMirrorOnAnAlreadyCreatedBox`.
/// The box SHADOWS storage — `LiveTitles.workspaceTitle(for:)` prefers it over
/// the session struct — so a coarse publish that never happens shows a
/// superseded title indefinitely, not for one frame. Issue #313 shipped that
/// exact bug past 17 green tests because they asserted the model struct instead
/// of the box; these assert the box's coarse properties directly.
@MainActor
@Suite("LiveTitleBox — coarse title channel")
struct LiveTitleBoxCoarseChannelTests {

    // MARK: - 1. The per-tick path coalesces on the STORE's gate

    @Test("a burst of display-only title writes publishes the coarse mirror once, with the generation bump")
    func burstPublishesCoarseMirrorOnce() throws {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Consume the leading edge, so the burst below is entirely inside one
        // window. Without this the first write would legitimately publish and the
        // test would be measuring the wrong thing.
        fixture.retitle("frame 0", now: base)
        #expect(box.coarseWorkspaceTitle == "frame 0")
        #expect(fixture.store.liveTitleGeneration == 1)

        // A spinner reports ~4x/sec. Five frames, all strictly inside the window
        // opened at `base` — the last lands at +0.5s, comfortably short of the
        // boundary, so nothing here is due on the coarse channel.
        for frame in 1...5 {
            fixture.retitle("frame \(frame)", now: base.addingTimeInterval(Double(frame) * 0.1))
        }

        // The fine channel moved on every single one — this is what keeps a pane
        // title bar's braille spinner smooth, and it is the control that proves
        // the coarse assertion below is coalescing rather than a dead write path.
        #expect(box.workspaceTitle == "frame 5")
        #expect(box.paneTitles[fixture.paneID] == "frame 5")

        // The coarse channel did not — and neither did the generation. One gate
        // means the two cannot fire separately (issue #327).
        #expect(box.coarseWorkspaceTitle == "frame 0")
        #expect(box.coarsePaneTitles[fixture.paneID] == "frame 0")
        #expect(fixture.store.liveTitleGeneration == 1)

        // Once the window elapses, the next report carries the latest title —
        // the mirror catches up wholesale, it does not replay the frames it
        // skipped — and the generation bumps on the same tick.
        fixture.retitle(
            "frame 6",
            now: base.addingTimeInterval(SessionStore.defaultLiveTitleGenerationInterval)
        )
        #expect(box.coarseWorkspaceTitle == "frame 6")
        #expect(box.coarsePaneTitles[fixture.paneID] == "frame 6")
        #expect(fixture.store.liveTitleGeneration == 2)
    }

    @Test("a backwards wall clock does not freeze the coarse mirror")
    func backwardsClockDoesNotFreezeCoarseMirror() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.retitle("before", now: base)

        // An NTP step backwards. Treating a negative elapsed as "not due" would
        // suppress every publish until the clock caught back up — for a jump of
        // an hour, an hour of sidebar rows naming the wrong workspace.
        fixture.retitle("after", now: base.addingTimeInterval(-3600))

        #expect(box.coarseWorkspaceTitle == "after")
    }

    // MARK: - 2. `adopt` — the non-tick path — is never throttled

    /// The #313 shape, and the reason this suite exists. The box is created
    /// first and the write lands on it afterwards, which is the arrangement in
    /// which a forgotten refresh shows a superseded title forever.
    @Test("a rename refreshes the coarse mirror on an already-created box")
    func renameRefreshesCoarseMirrorOnAnAlreadyCreatedBox() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.coarseWorkspaceTitle == "workspace")

        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        #expect(box.coarseWorkspaceTitle == "release prep")
        #expect(box.workspaceTitle == "release prep")
    }

    /// A rename is exactly the case a coalesced mirror would ruin: the user
    /// typed a name and nothing else is guaranteed to publish afterwards, so a
    /// held-back publish is not a late row, it is a permanently wrong one.
    @Test("a rename inside the coalescing window publishes the coarse mirror immediately")
    func renameInsideTheWindowIsUnthrottled() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Arm the window, then confirm it really is armed: this display-only
        // write is suppressed on the coarse channel.
        fixture.retitle("frame 0", now: base)
        fixture.retitle("frame 1", now: base.addingTimeInterval(0.2))
        #expect(box.coarseWorkspaceTitle == "frame 0")

        // Same window. A rename publishes `groups`, which routes through
        // `adopt`, which does not consult the clock at all.
        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        #expect(box.coarseWorkspaceTitle == "release prep")
    }

    @Test("a title reset inside the coalescing window publishes the coarse mirror immediately")
    func resetInsideTheWindowIsUnthrottled() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Arms the coalescing window at `base`, and nothing below advances it:
        // `adopt` takes no clock, and a report against a user-edited pane moves
        // only the undisplayed live title so it never reaches the coarse path.
        fixture.retitle("frame 0", now: base)
        fixture.store.renamePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "pinned name"
        )
        #expect(box.coarsePaneTitles[fixture.paneID] == "pinned name")

        // Frozen out of the displayed title, but it is what reset re-adopts.
        fixture.retitle("cargo build", now: base.addingTimeInterval(0.2))
        #expect(box.coarsePaneTitles[fixture.paneID] == "pinned name")

        // Still inside the window armed at `base`.
        fixture.store.resetPaneTitle(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID
        )

        #expect(box.coarsePaneTitles[fixture.paneID] == "cargo build")
        #expect(box.coarsePaneTitles[fixture.paneID] == box.paneTitles[fixture.paneID])
    }

    /// A structural mutation reaches the box through the same `_groups`
    /// accessors, so a new pane must appear on the coarse channel too — a
    /// sidebar row keys every pane it renders, and a missing key renders the
    /// struct's title forever.
    @Test("a split publishes the new pane on the coarse mirror immediately")
    func splitIsUnthrottled() throws {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.retitle("frame 0", now: base)
        #expect(box.coarsePaneTitles.count == 1)

        _ = try #require(
            fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID)
        )

        #expect(box.coarsePaneTitles.count == 2)
        #expect(box.coarsePaneTitles == box.paneTitles)
    }

    // MARK: - 3. Both channels agree once the dust settles

    @Test("a box created from storage seeds both channels")
    func boxCreationSeedsBothChannels() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)

        #expect(box.coarseWorkspaceTitle == box.workspaceTitle)
        #expect(box.coarsePaneTitles == box.paneTitles)
        #expect(box.coarsePaneTitles[fixture.paneID] == "pane")
    }

    /// `adopt` must leave the store's coalescing stamp exactly as it found it —
    /// neither ADVANCING it (which would cost the next second of ticks their
    /// publish) nor CLEARING it (which would hand every rename a free leading
    /// edge and defeat the coalescing).
    ///
    /// Both halves are asserted, because either one alone is satisfiable by a
    /// broken implementation. `now` runs forward from the CURRENT clock rather
    /// than from an epoch constant on purpose: with a 1970 base, an `adopt` that
    /// stamped `Date()` would produce an elapsed of about minus fifty-six years,
    /// the backwards-clock branch would call it due, and the publish would go
    /// through — leaving this test green against the exact mutation it names.
    @Test("an unthrottled publish leaves the coalescing window exactly as it found it")
    func adoptLeavesTheCoalescingWindowIntact() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date()

        // Opens the window at `base`.
        fixture.retitle("frame 0", now: base)
        #expect(box.coarsePaneTitles[fixture.paneID] == "frame 0")

        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        // Did not CLEAR the stamp: still inside the window opened at `base`.
        fixture.retitle("frame 1", now: base.addingTimeInterval(0.2))
        #expect(box.coarsePaneTitles[fixture.paneID] == "frame 0")

        // Did not ADVANCE the stamp: the window still expires one interval after
        // `base`, not one interval after the rename.
        fixture.retitle(
            "frame 2",
            now: base.addingTimeInterval(SessionStore.defaultLiveTitleGenerationInterval)
        )
        #expect(box.coarsePaneTitles[fixture.paneID] == "frame 2")
    }

    /// `interval` reaches `SessionStore` from a public initializer. NaN makes
    /// every comparison false; positive infinity makes every finite elapsed
    /// time stay inside the window forever. Neither may freeze the generation.
    @Test("a non-finite interval does not freeze the live-title generation")
    func nonFiniteIntervalDoesNotFreezeTheGeneration() {
        for interval in [TimeInterval.nan, .infinity, -.infinity] {
            let fixture = makeFixture(liveTitleGenerationInterval: interval)
            let base = Date(timeIntervalSince1970: 1_000_000)

            fixture.retitle("one", now: base)
            fixture.retitle("two", now: base.addingTimeInterval(0.1))
            fixture.retitle("three", now: base.addingTimeInterval(0.2))

            #expect(fixture.store.liveTitleGeneration == 3)
        }
    }

    // MARK: - 4. A restore is a new lifetime for the coalescing window

    /// A bulk restore can reuse a session ID with entirely different content.
    /// The surviving box keeps no coalescing state of its own (the stamp lives
    /// in the store, and `replaceState` clears the session's entry there), so
    /// the restored pane's FIRST title report cannot be suppressed by a window
    /// the previous occupant opened — indefinitely, if it were that pane's
    /// only report.
    @Test("a restore reusing a session ID starts a fresh coalescing window")
    func restoreReusingASessionIDResetsTheWindow() throws {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let base = Date()

        // Opens a window on the OUTGOING content.
        fixture.retitle("outgoing", now: base)
        #expect(box.coarseWorkspaceTitle == "outgoing")

        // Same session ID, different content.
        let restoredPane = TerminalPane(
            title: "restored pane",
            workingDirectory: "~",
            executionPlan: .local
        )
        let restored = TerminalSession(
            id: fixture.sessionID,
            title: "restored workspace",
            workingDirectory: "~",
            layout: .pane(restoredPane),
            activePaneID: restoredPane.id
        )
        _ = fixture.store.replaceState(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [restored])],
                selectedSessionID: fixture.sessionID
            )
        )

        let restoredBox = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(restoredBox.coarseWorkspaceTitle == "restored workspace")

        // Well inside the window the outgoing session opened at `base`. It must
        // publish anyway: this is the restored pane's first report.
        let generationBefore = fixture.store.liveTitleGeneration
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: restoredPane.id,
            title: "first report",
            now: base.addingTimeInterval(0.2)
        )
        #expect(restoredBox.coarsePaneTitles[restoredPane.id] == "first report")

        // One gate, one stamp: the same cleared window that released the coarse
        // publish above also let the generation bump — under two clocks this
        // pair drifted, moving the row while leaving every title-derived
        // projection un-rebuilt.
        #expect(fixture.store.liveTitleGeneration > generationBefore)
    }

    // MARK: - 5. A box created mid-window joins the session's existing cadence

    /// `tickLiveTitle` gates on the STORE's per-session stamp, which exists
    /// whether or not a box does. When a box appears later — the sidebar's
    /// resolved-title map creates it — `adopt` seeds the coarse mirror from
    /// current storage unthrottled, so the new surface starts CORRECT, and the
    /// running window then governs its per-tick publishes. The alternative
    /// (a fresh leading edge at box creation) would let a mid-window box strobe
    /// the row open exactly when nothing else was moving.
    @Test("a box created mid-window starts at storage and waits for the next due tick")
    func boxCreatedMidWindowStartsAtStorage() {
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Opens the session's window with NO box attached. The generation bumps
        // even without one — projections cover the whole roster.
        fixture.retitle("one", now: base)
        #expect(fixture.store.liveTitleGeneration == 1)
        fixture.retitle("two", now: base.addingTimeInterval(0.4))
        #expect(fixture.store.liveTitleGeneration == 1)

        // The box appears: coarse == current storage via the seeding adopt.
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.coarseWorkspaceTitle == "two")

        // Still inside the window opened at `base`: the fine channel moves, the
        // coarse mirror and the generation both hold.
        fixture.retitle("three", now: base.addingTimeInterval(0.7))
        #expect(box.workspaceTitle == "three")
        #expect(box.coarseWorkspaceTitle == "two")
        #expect(fixture.store.liveTitleGeneration == 1)

        // The next due tick publishes and bumps together.
        fixture.retitle("four", now: base.addingTimeInterval(1))
        #expect(box.coarseWorkspaceTitle == "four")
        #expect(fixture.store.liveTitleGeneration == 2)
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID

        @MainActor
        func retitle(_ title: String, now: Date) {
            store.updatePane(sessionID: sessionID, paneID: paneID, title: title, now: now)
        }
    }

    /// Session and pane IDs are captured from the values the store was built
    /// with, so every assertion keys off the same identities for the whole test
    /// rather than minting fresh UUIDs that would make a lookup vacuously agree
    /// with itself.
    private func makeFixture(
        liveTitleGenerationInterval: TimeInterval = SessionStore.defaultLiveTitleGenerationInterval
    ) -> Fixture {
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
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            liveTitleGenerationInterval: liveTitleGenerationInterval
        )
        store.localHostnames = ["local"]
        return Fixture(store: store, sessionID: session.id, paneID: pane.id)
    }
}
