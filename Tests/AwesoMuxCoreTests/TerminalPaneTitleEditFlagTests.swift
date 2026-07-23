import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct TerminalPaneTitleEditFlagTests {
    @Test
    func defaultsToFalse() {
        let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        #expect(pane.isTitleUserEdited == false)
    }

    @Test
    func roundTripsWhenTrue() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~", executionPlan: .local)
        pane.isTitleUserEdited = true

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        #expect(decoded.isTitleUserEdited == true)
        #expect(decoded.title == "My Backend")
    }

    @Test
    func decodesMissingKeyAsFalse() throws {
        // A pre-feature snapshot has no isTitleUserEdited key on the pane.
        // `agentKind` raw value is "Shell" (not "shell"); both it and
        // `agentExecutionState` decode tolerantly, so they're omitted here to
        // keep the test focused on the absent isTitleUserEdited key.
        let json = #"{"id":"\#(UUID().uuidString)","title":"shell","workingDirectory":"~","unreadNotificationCount":0}"#
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))
        #expect(decoded.isTitleUserEdited == false)
    }

    @Test
    func equalityDistinguishesFlag() {
        let a = TerminalPane(id: UUID(), title: "x", workingDirectory: "~", executionPlan: .local)
        var b = a
        b.isTitleUserEdited = true
        #expect(a != b)
    }

    /// A frozen pane (a user-renamed title) must survive the real restore path
    /// still frozen — the INT-504 dropped-field trap, applied to a *persisted*
    /// flag: any reconstruction site that fails to thread `isTitleUserEdited`
    /// would silently unfreeze the pane and let the next OSC tick clobber the
    /// custom name. Asserts the snapshot encode→decode→restore round-trip keeps
    /// the flag, plus a focused per-pane check through `SessionRestoreReducer`.
    @Test
    func frozenPaneSurvivesSnapshotRestoreStillFrozen() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        let session = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        // Persistence shape: encode the snapshot through Codable and decode it
        // back, then run the REAL restore path (`restoredComponents` →
        // `restoredSession`, the SessionRestoreReducer:183 reconstruction site).
        // If that site dropped `isTitleUserEdited`, the pane would come back
        // unfrozen and this assertion would fail.
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionRestoreReducer.restoredComponents(from: decoded)

        let restoredPane = try #require(
            restored.groups.first?.sessions.first?.layout.pane(id: pane.id)
        )
        #expect(restoredPane.isTitleUserEdited == true)
        #expect(restoredPane.title == "My Backend")
    }

    /// Adversarial-review coverage (lone-pane carve-out): a snapshot whose
    /// persisted SESSION title drifted from a lone pane's pin must restore with
    /// the pin as the workspace title — not sit on stale chrome until the first
    /// OSC tick re-syncs it. Mirrors `syncSessionChromeToActivePane`'s rule at
    /// the restore construction site.
    @Test
    func restoreAppliesLonePanePinToDriftedWorkspaceTitle() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        // Persisted session title disagrees with the pin (e.g. a pre-carve-out
        // snapshot where the live title owned the workspace name).
        let session = TerminalSession(title: "zsh", workingDirectory: "~", layout: .pane(pane))
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionRestoreReducer.restoredComponents(from: decoded)

        let restoredSession = try #require(restored.groups.first?.sessions.first)
        #expect(restoredSession.title == "My Backend")
    }

    /// The carve-out must NOT clobber a user-renamed workspace on restore.
    @Test
    func restoreKeepsUserRenamedWorkspaceTitleOverLonePanePin() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        var session = TerminalSession(title: "My Workspace", workingDirectory: "~", layout: .pane(pane))
        session.isTitleUserEdited = true
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionRestoreReducer.restoredComponents(from: decoded)

        let restoredSession = try #require(restored.groups.first?.sessions.first)
        #expect(restoredSession.title == "My Workspace")
        #expect(restoredSession.isTitleUserEdited == true)
    }

    /// The duplicate-pane-ID rebuild path (`SessionRestoreReducer` id-collision
    /// reconstruction, line ~299) is a SEPARATE construction site from the main
    /// restore path (line ~183). The colliding pane — the SECOND one to claim a
    /// shared UUID — is the one rebuilt with a fresh id. So the frozen pane must
    /// be the COLLIDER (second in traversal) for this test to actually exercise
    /// that site; if the frozen pane were first it would keep its id via the main
    /// path and the rebuild branch would go untested (a tautology Codex caught).
    @Test
    func frozenPaneSurvivesDuplicateIDRebuildStillFrozen() throws {
        let sharedID = UUID()
        // First pane (unfrozen) wins the shared id via the main path.
        let firstPane = TerminalPane(id: sharedID, title: "other", workingDirectory: "~", executionPlan: .local)
        // Second pane (frozen) collides → forced through the id-reassignment
        // rebuild. THIS is the site under test.
        var frozen = TerminalPane(
            id: sharedID,
            title: "My Backend",
            workingDirectory: "~/Development/awesomux",
            executionPlan: .local
        )
        frozen.isTitleUserEdited = true

        let sessionA = TerminalSession(title: "a", workingDirectory: "~", layout: .pane(firstPane))
        let sessionB = TerminalSession(title: "b", workingDirectory: "~", layout: .pane(frozen))
        let group = SessionGroup(name: "g", sessions: [sessionA, sessionB])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: sessionA.id)

        let restored = SessionRestoreReducer.restoredComponents(from: snapshot)
        let allPanes = restored.groups
            .flatMap { $0.sessions }
            .flatMap { $0.panes }
        #expect(Set(allPanes.map(\.id)).count == 2)

        // Find the rebuilt frozen pane by its title — it was reassigned a NEW id
        // (no longer sharedID) precisely because it went through the collision
        // rebuild. If that site dropped the flag, this assertion fails.
        let rebuiltFrozen = try #require(allPanes.first { $0.title == "My Backend" })
        #expect(rebuiltFrozen.id != sharedID)
        #expect(rebuiltFrozen.isTitleUserEdited == true)
    }

    /// The reopen-closed-workspace path rebuilds panes via
    /// `RecentlyClosedWorkspaceReducer.reidentifiedLayout` — a third distinct
    /// reconstruction site. A frozen pane must reopen still frozen, else the
    /// next OSC tick clobbers the user's pinned title.
    @Test
    func frozenPaneSurvivesReopenReidentifyStillFrozen() throws {
        var frozen = TerminalPane(
            id: UUID(),
            title: "My Backend",
            workingDirectory: "~/Development/awesomux",
            executionPlan: .local
        )
        frozen.isTitleUserEdited = true

        var seenTerminalSessionIDs: Set<TerminalSessionID> = []
        var seenPaneIDs: Set<TerminalPane.ID> = []
        let reidentified = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
            .pane(frozen),
            indexHint: 1,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            seenPaneIDs: &seenPaneIDs
        )

        let newID = try #require(reidentified.paneIDs.first)
        let reopenedPane = try #require(reidentified.pane(id: newID))
        #expect(reopenedPane.isTitleUserEdited == true)
        #expect(reopenedPane.title == "My Backend")
    }

    /// QA H1: a pinned title that sanitizes to EMPTY on restore falls back to a
    /// synthetic `"shell N"` name the user never chose. The freeze must NOT
    /// survive in that case — otherwise the pane comes back stuck on the
    /// synthetic name with the live OSC title locked out. `"\u{200B}\u{FEFF}"`
    /// (zero-width space + BOM) sanitizes to empty (see UnicodeHygieneTests).
    @Test
    func frozenPaneWithTitleSanitizedAwayUnpinsOnRestore() throws {
        var pane = TerminalPane(title: "\u{200B}\u{FEFF}", workingDirectory: "~", executionPlan: .local)
        pane.isTitleUserEdited = true
        let session = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        let restored = SessionRestoreReducer.restoredComponents(from: snapshot)
        let restoredPane = try #require(
            restored.groups.first?.sessions.first?.layout.pane(id: pane.id)
        )
        // Un-pinned: the live OSC title can reclaim the pane.
        #expect(restoredPane.isTitleUserEdited == false)
        // And the displayed title is the synthetic fallback, not the empty pin.
        #expect(restoredPane.title != "\u{200B}\u{FEFF}")
        #expect(!restoredPane.title.isEmpty)
    }

    /// H1 again, on the REOPEN path: a frozen pane whose title sanitizes to empty
    /// must also un-pin when reopened via `reidentifiedLayout` — the fix lives in
    /// both reconstruction sites, so both need a guarding test (Codex).
    @Test
    func frozenPaneWithTitleSanitizedAwayUnpinsOnReopen() throws {
        var frozen = TerminalPane(id: UUID(), title: "\u{200B}\u{FEFF}", workingDirectory: "~", executionPlan: .local)
        frozen.isTitleUserEdited = true

        var seenTerminalSessionIDs: Set<TerminalSessionID> = []
        var seenPaneIDs: Set<TerminalPane.ID> = []
        let reidentified = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
            .pane(frozen),
            indexHint: 1,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            seenPaneIDs: &seenPaneIDs
        )

        let newID = try #require(reidentified.paneIDs.first)
        let reopenedPane = try #require(reidentified.pane(id: newID))
        #expect(reopenedPane.isTitleUserEdited == false)
        #expect(reopenedPane.title != "\u{200B}\u{FEFF}")
        #expect(!reopenedPane.title.isEmpty)
    }

    /// In a split layout, the freeze flag must be threaded PER PANE through the
    /// recursive restore — a frozen child stays frozen while its unfrozen
    /// sibling stays unfrozen. Guards against one pane's flag being smeared
    /// across siblings during the layout-tree descent.
    @Test
    func splitLayoutThreadsFreezeFlagPerPane() throws {
        let frozenID = UUID()
        let liveID = UUID()
        var frozen = TerminalPane(id: frozenID, title: "Backend", workingDirectory: "~", executionPlan: .local)
        frozen.isTitleUserEdited = true
        let live = TerminalPane(id: liveID, title: "logs", workingDirectory: "~", executionPlan: .local)

        let split = TerminalSplit(
            orientation: .vertical,
            first: .pane(frozen),
            second: .pane(live)
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .split(split)
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        let restored = SessionRestoreReducer.restoredComponents(from: snapshot)
        let layout = try #require(restored.groups.first?.sessions.first?.layout)
        let restoredFrozen = try #require(layout.pane(id: frozenID))
        let restoredLive = try #require(layout.pane(id: liveID))

        #expect(restoredFrozen.isTitleUserEdited == true)
        #expect(restoredLive.isTitleUserEdited == false)
    }
}
