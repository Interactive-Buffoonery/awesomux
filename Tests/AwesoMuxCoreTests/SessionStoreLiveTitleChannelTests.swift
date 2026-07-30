import Foundation
import Observation
import Testing

@testable import AwesoMuxCore

/// Issue #311: a display-only OSC title report writes group storage silently
/// and notifies the session's `LiveTitleBox` instead of publishing `groups`.
///
/// These are the binding acceptance gate for the change: a silent write is by
/// construction invisible to `withObservationTracking`, so a misclassified
/// write cannot be caught by reading the code — only by pinning both sides of
/// the classifier here.
@MainActor
@Suite("SessionStore — live title channel (#311)")
struct SessionStoreLiveTitleChannelTests {

    // MARK: - 1. Classifier: what publishes `groups`

    @Test("a display-only title write does not publish groups")
    func displayOnlyTitleWriteDoesNotPublishGroups() {
        let fixture = makeFixture()
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        #expect(!published.value)
        // Storage is still current — every reader off the struct sees the new
        // title, it just was not the thing that scheduled a render.
        #expect(fixture.store.session(id: fixture.sessionID)?.activePane?.title == "cargo build")
    }

    @Test("a title write that also moves the working directory publishes groups")
    func titleWriteWithWorkingDirectoryPublishesGroups() {
        let fixture = makeFixture()
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "cargo build",
            workingDirectory: NSHomeDirectory()
        )

        #expect(published.value)
    }

    @Test("a title write that also moves progress publishes groups")
    func titleWriteWithProgressPublishesGroups() {
        let fixture = makeFixture()
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "cargo build",
            progressReport: TerminalProgressReport(state: .set, progress: 40)
        )

        #expect(published.value)
    }

    @Test("a rejected report still costs nothing")
    func rejectedReportWritesNothing() {
        let fixture = makeFixture()
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.paneTitles[fixture.paneID] == "cargo build")

        let published = TrackingFlag()
        track(fixture.store, published)
        let boxPublished = TrackingFlag()
        withObservationTracking {
            _ = box.paneTitles
            _ = box.workspaceTitle
        } onChange: {
            boxPublished.set()
        }

        // Identical repeat report: the reducer returns nil and nothing moves.
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        #expect(!published.value)
        #expect(!boxPublished.value)
    }

    // MARK: - 2. The box receives display-only writes

    @Test("a display-only title write reaches the session's live title box")
    func displayOnlyTitleWriteReachesBox() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.workspaceTitle == "workspace")
        #expect(box.paneTitles[fixture.paneID] == "pane")

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        // Promoted workspace title (active pane) and the per-pane entry.
        #expect(box.workspaceTitle == "cargo build")
        #expect(box.paneTitles[fixture.paneID] == "cargo build")
    }

    @Test("the box is seeded from restored storage before any report")
    func boxSeedsFromStorage() throws {
        let fixture = makeFixture()
        let snapshot = fixture.store.snapshot()
        let restored = SessionStore(restoring: snapshot)
        let sessionID = try #require(restored.groups.first?.sessions.first?.id)
        let paneID = try #require(restored.session(id: sessionID)?.activePaneID)

        let box = restored.liveTitleBox(for: sessionID)

        #expect(box.workspaceTitle == "workspace")
        #expect(box.paneTitles[paneID] == "pane")
    }

    // MARK: - 3. Split sessions

    @Test("split panes keep independent live titles and inactive entries survive")
    func splitPanesKeepIndependentTitles() throws {
        let fixture = makeFixture()
        let store = fixture.store
        _ = try #require(store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        let activePaneID = try #require(store.session(id: fixture.sessionID)?.activePaneID)
        let inactivePaneID = try #require(
            store.session(id: fixture.sessionID)?.panes.first { $0.id != activePaneID }?.id
        )

        let box = store.liveTitleBox(for: fixture.sessionID)

        store.updatePane(sessionID: fixture.sessionID, paneID: inactivePaneID, title: "vim")
        store.updatePane(sessionID: fixture.sessionID, paneID: activePaneID, title: "cargo build")

        #expect(box.paneTitles[inactivePaneID] == "vim")
        #expect(box.paneTitles[activePaneID] == "cargo build")
        // The active pane is what the workspace title follows.
        #expect(box.workspaceTitle == "cargo build")

        // A further report on the active pane must not drop the inactive
        // pane's entry — `resetPaneTitle` re-adopts the latest live title.
        store.updatePane(sessionID: fixture.sessionID, paneID: activePaneID, title: "cargo test")
        #expect(box.paneTitles[inactivePaneID] == "vim")
        #expect(box.paneTitles[activePaneID] == "cargo test")
    }

    // MARK: - 4. Persistence round trip

    @Test("a display-only retitle survives snapshot and restore")
    func displayOnlyRetitleSurvivesRoundTrip() throws {
        let fixture = makeFixture()
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        let restored = SessionStore(restoring: fixture.store.snapshot())
        let session = try #require(restored.groups.first?.sessions.first)

        #expect(session.title == "cargo build")
        #expect(session.activePane?.title == "cargo build")
    }

    // MARK: - 5. Remote identity still derives from a title report

    @Test("a title that trips the remote detector publishes and consumes the pending target")
    func remoteTitlePublishesAndConsumesPendingTarget() throws {
        let fixture = makeFixture(pendingRemoteSSHTarget: "host-a")
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "alice@host-a: ~"
        )

        let pane = try #require(fixture.store.session(id: fixture.sessionID)?.activePane)
        #expect(pane.remoteHost == "host-a")
        #expect(pane.remoteSSHTarget == "host-a")
        #expect(pane.pendingRemoteSSHTarget == nil)
        #expect(published.value)
        #expect(fixture.store.index.remotePaneIDs.contains(fixture.paneID))
    }

    // MARK: - 6. The remote-membership trap

    @Test("repeated title writes on an already-remote pane do not publish")
    func repeatedTitlesOnRemotePaneDoNotPublish() {
        let fixture = makeFixture(remoteHost: "host-a", remoteSSHTarget: "host-a")
        #expect(fixture.store.index.remotePaneIDs.contains(fixture.paneID))
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "alice@host-a: one")
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "alice@host-a: two")

        #expect(!published.value)
        // Membership was not re-emitted, but it is also not stale.
        #expect(fixture.store.index.remotePaneIDs.contains(fixture.paneID))
        #expect(
            fixture.store.index.remotePaneIDs
                == SessionStoreIndex.build(from: fixture.store.groups).remotePaneIDs
        )
    }

    @Test("leaving remote via a working directory report clears membership and publishes")
    func leavingRemotePublishes() {
        let fixture = makeFixture(remoteHost: "host-a", remoteSSHTarget: "host-a")
        let published = TrackingFlag()
        track(fixture.store, published)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            workingDirectory: NSHomeDirectory()
        )

        #expect(published.value)
        #expect(!fixture.store.index.remotePaneIDs.contains(fixture.paneID))
        #expect(
            fixture.store.index.remotePaneIDs
                == SessionStoreIndex.build(from: fixture.store.groups).remotePaneIDs
        )
    }

    // MARK: - 7. User-edit freeze and reset

    @Test("a user-edited pane title stays frozen and the box does not move")
    func userEditedTitleStaysFrozen() throws {
        let fixture = makeFixture()
        // Two panes: the lone-pane carve-out promotes a pinned title into the
        // workspace bar, which would muddy what the box is being asserted on.
        _ = try #require(fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        #expect(fixture.store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "pinned"))

        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let boxPublished = TrackingFlag()
        withObservationTracking {
            _ = box.paneTitles
        } onChange: {
            boxPublished.set()
        }

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        let pane = try #require(fixture.store.session(id: fixture.sessionID)?.layout.pane(id: fixture.paneID))
        #expect(pane.title == "pinned")
        #expect(pane.liveTerminalTitle == "cargo build")
        #expect(box.paneTitles[fixture.paneID] == "pinned")
        // Only the undisplayed live title moved, so nothing needed repainting.
        #expect(!boxPublished.value)
    }

    @Test("resetPaneTitle re-adopts the latest silently written live title")
    func resetPaneTitleReadoptsLiveTitle() throws {
        let fixture = makeFixture()
        _ = try #require(fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        #expect(fixture.store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "pinned"))
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        #expect(fixture.store.resetPaneTitle(sessionID: fixture.sessionID, paneID: fixture.paneID))

        let pane = try #require(fixture.store.session(id: fixture.sessionID)?.layout.pane(id: fixture.paneID))
        #expect(pane.title == "cargo build")
        #expect(!pane.isTitleUserEdited)
    }

    // MARK: - Box lifetime

    @Test("a closed session's box is pruned")
    func closedSessionPrunesBox() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)

        fixture.store.closeSession(id: fixture.sessionID)

        // A pruned box cannot be handed back; re-requesting mints a new one.
        #expect(fixture.store.liveTitleBox(for: fixture.sessionID) !== box)
    }

    // MARK: - Title-triggered save signal

    /// A silent write fires no `groups` observer, so the save it still needs
    /// rides `onDisplayOnlyTitleWrite` instead — synchronously, so the handler
    /// sees the title it is being asked to persist.
    @Test("a display-only title write calls the save handler once per write")
    func displayOnlyWriteCallsSaveHandler() {
        let fixture = makeFixture()
        let saves = CallCounter()
        fixture.store.onDisplayOnlyTitleWrite = { saves.increment() }

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "one")
        #expect(saves.count == 1)
        #expect(fixture.store.session(id: fixture.sessionID)?.activePane?.title == "one")

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "two")
        #expect(saves.count == 2)
    }

    @Test("a publishing title write leaves the save handler alone")
    func publishingWriteSkipsSaveHandler() {
        let fixture = makeFixture()
        let saves = CallCounter()
        fixture.store.onDisplayOnlyTitleWrite = { saves.increment() }

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "cargo build",
            workingDirectory: NSHomeDirectory()
        )

        // `groups` published, so the Scene's own save observer covers this one.
        #expect(saves.count == 0)
    }

    @Test("a rejected report does not call the save handler")
    func rejectedReportSkipsSaveHandler() {
        let fixture = makeFixture()
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        let saves = CallCounter()
        fixture.store.onDisplayOnlyTitleWrite = { saves.increment() }

        // Identical repeat report: the reducer returns nil and nothing moves.
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        #expect(saves.count == 0)
    }

    // MARK: - Every writer refreshes an ALREADY-CREATED box

    /// The box is preferred over the struct wherever one exists
    /// (`LiveTitles.workspaceTitle(for:)` is `workspace ?? session.title`), so a
    /// writer that moves a displayed title without refreshing the channel does
    /// not lag by a frame — it shadows the fresher value indefinitely.
    ///
    /// Every assertion here reads the BOX, not the struct, against a box created
    /// BEFORE the write. Asserting the struct is what let the original bug ship:
    /// storage is current on every path by construction, so a struct-side
    /// assertion passes whether or not the channel was told.

    @Test("renameSession refreshes an existing box")
    func renameSessionRefreshesBox() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.workspaceTitle == "workspace")

        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        #expect(box.workspaceTitle == "release prep")
    }

    @Test("renamePane refreshes an existing box")
    func renamePaneRefreshesBox() throws {
        let fixture = makeFixture()
        // Two panes so the lone-pane carve-out does not also move the workspace
        // title: this has to fail if only the workspace field is refreshed.
        _ = try #require(fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.paneTitles[fixture.paneID] == "pane")

        #expect(fixture.store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "logs"))

        #expect(box.paneTitles[fixture.paneID] == "logs")
    }

    @Test("resetPaneTitle refreshes an existing box")
    func resetPaneTitleRefreshesBox() throws {
        let fixture = makeFixture()
        _ = try #require(fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        #expect(fixture.store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "pinned"))
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.paneTitles[fixture.paneID] == "pinned")

        #expect(fixture.store.resetPaneTitle(sessionID: fixture.sessionID, paneID: fixture.paneID))

        #expect(box.paneTitles[fixture.paneID] == "cargo build")
    }

    @Test("a publishing title report refreshes an existing box")
    func publishingReportRefreshesBox() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        #expect(box.workspaceTitle == "workspace")

        // Title and cwd in one report — an ordinary `cd` in a prompt hook. This
        // takes the publishing branch, which never touched the channel.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "cargo build",
            workingDirectory: NSHomeDirectory()
        )

        #expect(box.workspaceTitle == "cargo build")
        #expect(box.paneTitles[fixture.paneID] == "cargo build")
    }

    @Test("a structural mutation refreshes an existing box's pane roster")
    func structuralMutationRefreshesBox() throws {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)

        let addedPaneID = try #require(
            fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID)
        )

        #expect(box.paneTitles[addedPaneID] != nil)
    }

    /// The refresh rides `_groups`' accessors, which run BEFORE `commit`
    /// rebuilds the index — so a bulk restore reaches it with an index still
    /// naming the pre-restore tree, at positions the new tree may not have.
    /// Bounds and session identity are checked there; this pins that a shrinking
    /// restore neither traps nor leaves a surviving box on a stale value.
    @Test("a bulk restore with a live box survives the pre-commit index and lands current")
    func bulkRestoreRefreshesBoxes() throws {
        let fixture = makeFixture()
        let survivor = try #require(fixture.store.groups.first?.sessions.first)
        let doomed = fixture.store.addSession(title: "second", groupName: "main")
        let survivorBox = fixture.store.liveTitleBox(for: fixture.sessionID)
        let doomedBox = fixture.store.liveTitleBox(for: doomed)

        var renamed = survivor
        renamed.title = "restored"
        _ = fixture.store.replaceState(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [renamed])],
                selectedSessionID: renamed.id,
                recentlyClosed: [],
                pinnedSessionIDs: []
            )
        )

        #expect(survivorBox.workspaceTitle == "restored")
        // The doomed session's box is pruned, so a re-request mints a new one.
        #expect(fixture.store.liveTitleBox(for: doomed) !== doomedBox)
    }

    // MARK: - Coalesced live-title generation

    @Test("ONE session's burst bumps the generation at most once per interval")
    func generationBumpsLeadingEdgeOncePerIntervalWithinOneSession() {
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_000_000)
        #expect(fixture.store.liveTitleGeneration == 0)

        fixture.store.updatePane(
            sessionID: fixture.sessionID, paneID: fixture.paneID, title: "one", now: base
        )
        #expect(fixture.store.liveTitleGeneration == 1)

        // Inside the interval: the write lands and the projections do not
        // re-derive. This is the documented ceiling on `liveTitleGeneration`, not
        // a property worth relying on — if "two" were this session's LAST event
        // ever, its projections would name it "one" until something else
        // published. What is pinned here is only that the throttle throttles.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "two",
            now: base.addingTimeInterval(0.5)
        )
        #expect(fixture.store.liveTitleGeneration == 1)
        #expect(fixture.store.session(id: fixture.sessionID)?.title == "two")

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "three",
            now: base.addingTimeInterval(1)
        )
        #expect(fixture.store.liveTitleGeneration == 2)
    }

    /// The property that matters, and the one a store-global timestamp got
    /// wrong: coalescing is PER SESSION. With one shared timestamp, a workspace
    /// whose agent spins at 10 Hz keeps the store permanently "not due", so a
    /// second workspace's single title change never bumps the counter — and its
    /// derived projections (sidebar search haystack, duplicate ordinals, rotor
    /// labels) never re-derive. Search then cannot find workspace B by the name
    /// B is displaying.
    @Test("one session's burst does not suppress another session's first bump")
    func aBurstInOneSessionDoesNotSuppressAnother() throws {
        let fixture = makeFixture()
        let other = try fixture.addSession(title: "second")
        let base = Date(timeIntervalSince1970: 1_000_000)

        // Session A saturates its own interval.
        for step in 0..<5 {
            fixture.store.updatePane(
                sessionID: fixture.sessionID,
                paneID: fixture.paneID,
                title: "a\(step)",
                now: base.addingTimeInterval(Double(step) * 0.1)
            )
        }
        #expect(fixture.store.liveTitleGeneration == 1)

        // Session B's FIRST and only title change, well inside A's interval.
        fixture.store.updatePane(
            sessionID: other.sessionID,
            paneID: other.paneID,
            title: "release prep",
            now: base.addingTimeInterval(0.5)
        )

        #expect(fixture.store.liveTitleGeneration == 2)
        #expect(fixture.store.session(id: other.sessionID)?.title == "release prep")
    }

    /// A backwards wall-clock step (NTP correction, manual clock change) must not
    /// suppress bumps until the clock catches up: a jump of hours would freeze
    /// every projection for hours.
    @Test("a wall-clock rollback still bumps the generation")
    func clockRollbackStillBumps() {
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.store.updatePane(
            sessionID: fixture.sessionID, paneID: fixture.paneID, title: "one", now: base
        )
        #expect(fixture.store.liveTitleGeneration == 1)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "two",
            now: base.addingTimeInterval(-3600)
        )
        #expect(fixture.store.liveTitleGeneration == 2)

        // And the rolled-back stamp becomes the new baseline rather than leaving
        // a future timestamp behind that would suppress the next hour of writes.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "three",
            now: base.addingTimeInterval(-3600 + 1)
        )
        #expect(fixture.store.liveTitleGeneration == 3)
    }

    @Test("the generation interval is injectable")
    func generationIntervalIsInjectable() {
        let fixture = makeFixture(liveTitleGenerationInterval: 0)
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.store.updatePane(
            sessionID: fixture.sessionID, paneID: fixture.paneID, title: "one", now: base
        )
        fixture.store.updatePane(
            sessionID: fixture.sessionID, paneID: fixture.paneID, title: "two", now: base
        )

        #expect(fixture.store.liveTitleGeneration == 2)
    }

    @Test("a publishing title write leaves the generation alone")
    func publishingWriteSkipsGeneration() {
        let fixture = makeFixture()

        // Publishing wakes every `groups` observer, so the bodies that derive
        // from titles re-run anyway; a bump would be a second invalidation.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "cargo build",
            workingDirectory: NSHomeDirectory()
        )

        #expect(fixture.store.liveTitleGeneration == 0)
    }

    // MARK: - A report that displays nothing costs nothing

    @Test("a report against an inactive user-edited pane notifies nobody but still records the live title")
    func inactiveUserEditedReportSkipsNotificationAndSave() throws {
        let fixture = makeFixture()
        // Splitting makes the original pane inactive, so the workspace title
        // does not follow its live title either.
        _ = try #require(fixture.store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
        #expect(fixture.store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "pinned"))
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let saves = CallCounter()
        fixture.store.onDisplayOnlyTitleWrite = { saves.increment() }
        let boxPublished = TrackingFlag()
        withObservationTracking {
            _ = box.paneTitles
            _ = box.workspaceTitle
        } onChange: {
            boxPublished.set()
        }

        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        #expect(!boxPublished.value)
        #expect(saves.count == 0)
        #expect(fixture.store.liveTitleGeneration == 0)
        // Storage still took it: `resetPaneTitle` is the one reader of
        // `liveTerminalTitle` and has to find the latest value there.
        let pane = try #require(fixture.store.session(id: fixture.sessionID)?.layout.pane(id: fixture.paneID))
        #expect(pane.liveTerminalTitle == "cargo build")
        #expect(fixture.store.resetPaneTitle(sessionID: fixture.sessionID, paneID: fixture.paneID))
        #expect(box.paneTitles[fixture.paneID] == "cargo build")
    }

    // MARK: - Helpers

    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID

        /// A second workspace in the SAME store, so the coalescing tests below
        /// exercise the real cross-session path rather than two stores that
        /// could not interfere in the first place.
        @MainActor
        func addSession(title: String) throws -> Fixture {
            let id = store.addSession(title: title, groupName: "main")
            let paneID = try #require(store.session(id: id)?.activePaneID)
            return Fixture(store: store, sessionID: id, paneID: paneID)
        }
    }

    private func makeFixture(
        remoteHost: String? = nil,
        remoteSSHTarget: String? = nil,
        pendingRemoteSSHTarget: String? = nil,
        liveTitleGenerationInterval: TimeInterval = SessionStore.defaultLiveTitleGenerationInterval
    ) -> Fixture {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: "~",
            remoteHost: remoteHost,
            remoteSSHTarget: remoteSSHTarget,
            pendingRemoteSSHTarget: pendingRemoteSSHTarget,
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

    private func track(_ store: SessionStore, _ flag: TrackingFlag) {
        withObservationTracking {
            _ = store.groups
        } onChange: {
            flag.set()
        }
    }
}

@MainActor
private final class CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
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
