import Foundation
import Observation
import Testing

@testable import AwesoMuxCore

/// Title writes must reach already-created channels and survive persistence.
@MainActor
@Suite("SessionStore — live title channel (#311)")
struct SessionStoreLiveTitleChannelTests {

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

    @Test("a display-only retitle survives snapshot and restore")
    func displayOnlyRetitleSurvivesRoundTrip() throws {
        let fixture = makeFixture()
        fixture.store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build")

        let restored = SessionStore(restoring: fixture.store.snapshot())
        let session = try #require(restored.groups.first?.sessions.first)

        #expect(session.title == "cargo build")
        #expect(session.activePane?.title == "cargo build")
    }

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

    /// The property that matters, and the one a store-global timestamp got
    /// wrong: coalescing is PER SESSION. With one shared timestamp, a workspace
    /// whose agent spins at 10 Hz keeps the store permanently "not due", so a
    /// second workspace's single title change never bumps the counter — and its
    /// derived projections (sidebar search haystack, duplicate ordinals, rotor
    /// labels) never re-derive. Search then cannot find workspace B by the name
    /// B is displaying.
    @Test("one session's burst does not suppress another session's title")
    func aBurstInOneSessionDoesNotSuppressAnother() throws {
        let fixture = makeFixture()
        let other = try fixture.addSession(title: "second")
        let base = Date(timeIntervalSince1970: 1_000_000)
        let box = fixture.store.liveTitleBox(for: other.sessionID)

        // Session A saturates its own interval.
        for step in 0..<5 {
            fixture.store.updatePane(
                sessionID: fixture.sessionID,
                paneID: fixture.paneID,
                title: "a\(step)",
                now: base.addingTimeInterval(Double(step) * 0.1)
            )
        }

        // Session B's FIRST and only title change, well inside A's interval.
        fixture.store.updatePane(
            sessionID: other.sessionID,
            paneID: other.paneID,
            title: "release prep",
            now: base.addingTimeInterval(0.5)
        )

        #expect(fixture.store.session(id: other.sessionID)?.title == "release prep")
        #expect(box.coarseWorkspaceTitle == "release prep")
    }

    /// A backwards wall-clock step (NTP correction, manual clock change) must not
    /// suppress bumps until the clock catches up: a jump of hours would freeze
    /// every projection for hours.
    @Test("a wall-clock rollback still publishes coarse titles")
    func clockRollbackStillBumps() {
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)

        fixture.store.updatePane(
            sessionID: fixture.sessionID, paneID: fixture.paneID, title: "one", now: base
        )

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "two",
            now: base.addingTimeInterval(-3600)
        )
        #expect(box.coarseWorkspaceTitle == "two")

        // And the rolled-back stamp becomes the new baseline rather than leaving
        // a future timestamp behind that would suppress the next hour of writes.
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.paneID,
            title: "three",
            now: base.addingTimeInterval(-3600 + 1)
        )
        #expect(box.coarseWorkspaceTitle == "three")
    }


    enum Writer: CaseIterable, Sendable {
        case renameSession, renamePane, reset, publishingReport, publishingInactivePane, split, closePane, restore
    }

    @Test("every writer refreshes existing fine and coarse title channels", arguments: Writer.allCases)
    func writerRefreshesChannels(writer: Writer) throws {
        let fixture = makeFixture()
        let store = fixture.store
        let box = store.liveTitleBox(for: fixture.sessionID)
        #expect(box.workspaceTitle == "workspace")
        #expect(box.coarseWorkspaceTitle == "workspace")
        #expect(box.paneTitles[fixture.paneID] == "pane")
        #expect(box.coarsePaneTitles == box.paneTitles)
        let base = Date(timeIntervalSince1970: 1_000_000)
        store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "frame 0", now: base)
        store.updatePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "frame 1", now: base.addingTimeInterval(0.2))
        let paneWake = TrackingFlag()
        switch writer {
        case .renameSession:
            store.renameSession(id: fixture.sessionID, title: "release prep")
            #expect(box.workspaceTitle == "release prep")
        case .renamePane, .reset, .publishingInactivePane:
            _ = try #require(store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
            if writer == .reset {
                #expect(store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "pinned"))
                store.updatePane(
                    sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build", now: base.addingTimeInterval(0.3))
                #expect(box.coarsePaneTitles[fixture.paneID] == "pinned")
                #expect(store.resetPaneTitle(sessionID: fixture.sessionID, paneID: fixture.paneID))
                #expect(box.paneTitles[fixture.paneID] == "cargo build")
            } else if writer == .renamePane {
                #expect(store.renamePane(sessionID: fixture.sessionID, paneID: fixture.paneID, title: "logs"))
                #expect(box.paneTitles[fixture.paneID] == "logs")
            } else {
                withObservationTracking {
                    _ = box.paneTitle(for: fixture.paneID)
                } onChange: {
                    paneWake.set()
                }
                store.updatePane(
                    sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build", workingDirectory: NSHomeDirectory())
                #expect(paneWake.value)
                #expect(box.paneTitle(for: fixture.paneID) == "cargo build")
            }
        case .publishingReport:
            store.updatePane(
                sessionID: fixture.sessionID, paneID: fixture.paneID, title: "cargo build", workingDirectory: NSHomeDirectory())
            #expect(box.workspaceTitle == "cargo build")
            #expect(box.paneTitles[fixture.paneID] == "cargo build")
        case .split:
            let added = try #require(store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
            #expect(box.paneTitles[added] != nil)
            #expect(box.coarsePaneTitles.count == 2)
        case .closePane:
            let added = try #require(store.splitActivePane(orientation: .horizontal, in: fixture.sessionID))
            #expect(box.paneTitles.count == 2)
            _ = try #require(store.closePane(id: added, in: fixture.sessionID))
            #expect(box.paneTitle(for: added) == nil)
            #expect(box.paneTitles.count == 1)
            #expect(box.paneTitle(for: fixture.paneID) == "frame 1")
        case .restore:
            var survivor = try #require(store.session(id: fixture.sessionID))
            let doomed = store.addSession(title: "second", groupName: "main")
            let doomedBox = store.liveTitleBox(for: doomed)
            survivor.title = "restored"
            store.replaceState(
                restoring: SessionSnapshot(groups: [SessionGroup(name: "main", sessions: [survivor])], selectedSessionID: survivor.id))
            #expect(box.workspaceTitle == "restored")
            #expect(store.liveTitleBox(for: doomed) !== doomedBox)
        }
        let current = try #require(store.session(id: fixture.sessionID))
        let titles = Dictionary(uniqueKeysWithValues: current.panes.map { ($0.id, $0.title) })
        #expect(box.workspaceTitle == current.title)
        #expect(box.paneTitles == titles)
        #expect(box.coarseWorkspaceTitle == current.title)
        #expect(box.coarsePaneTitles == titles)
    }

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
        pendingRemoteSSHTarget: String? = nil
    ) -> Fixture {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: "~",
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
            groups: [SessionGroup(name: "main", sessions: [session])]
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
