import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

/// Issue #311, root cause A: a display-only OSC title write updates store
/// storage without publishing `groups`, so everything `SidebarView.body`
/// *derives* — the search haystack, duplicate ordinals, VoiceOver rotor labels,
/// the agent panel's invalidation key, the group roster peek's inputs — froze at
/// the last publish while the rows beside them repainted through their own
/// `LiveTitleScope`s.
///
/// The fix is one dependency: `body` reads `sessionStore.liveTitleGeneration`,
/// a coalesced ~1 Hz tick. These tests split that into the two halves that can
/// actually be checked:
///
/// 1. `sidebarBodyReadsTheLiveTitleGeneration` — the wiring is present. Deleting
///    the read from `SidebarView.body` fails this test. Source-scraped like
///    `SidebarAttentionCuePolicyTests.edgeTabSourceContract`, because a SwiftUI
///    `body`'s observation dependencies are not otherwise reachable without
///    hosting the whole sidebar — see the note on the test itself.
/// 2. everything else — once the body DOES re-run, each derived value genuinely
///    re-derives to the silently-written title. Each carries its own
///    before-the-write control, so a passing assertion is the write's doing.
@MainActor
@Suite("Sidebar projections after a display-only title write (#311)")
struct SidebarLiveTitleProjectionTests {

    // MARK: - 1. The dependency is wired

    /// Source-scraped on purpose, and staying that way. A SwiftUI `body`'s
    /// observation dependencies are not reachable without hosting the whole
    /// sidebar, and hosted sidebar tests in this repository have a documented
    /// history of going vacuously green — passing while asserting nothing. A
    /// hosted replacement here would be less trustworthy than this, not more.
    ///
    /// `SourceContract.declarationBody` brace-balances the region instead of
    /// slicing between two incidental sibling members, so renaming or reordering
    /// an unrelated member cannot silently widen or narrow what is asserted, and
    /// a missing anchor names itself in the failure.
    @Test("SidebarView.body reads the live-title generation")
    func sidebarBodyReadsTheLiveTitleGeneration() throws {
        let path = "Sources/awesoMux/Views/SidebarView.swift"
        let source = try SourceContract.source(at: path)
        // Two steps because the file declares three `body`s; this pins the read to
        // `SidebarView`'s own, not a nested helper view's.
        let type = try SourceContract.declarationBody(
            after: "struct SidebarView: View {",
            in: source,
            path: path
        )
        let body = try SourceContract.declarationBody(
            after: "var body: some View {",
            in: type,
            path: "\(path) (SidebarView)"
        )

        #expect(
            body.contains("sessionStore.liveTitleGeneration"),
            """
            `SidebarView.body` no longer reads `sessionStore.liveTitleGeneration`. \
            That read is the body's only dependency on a display-only title write, \
            so without it everything `body` derives — the search haystack, \
            duplicate ordinals, VoiceOver rotor labels, the agent panel's \
            invalidation key — freezes at the last `groups` publish while the rows \
            beside it keep repainting through their own `LiveTitleScope`s (#311). \
            Moving the read into a helper called from `body` is fine; this test \
            then needs to follow it there.
            """
        )
    }

    @Test("the pop-up terminal's corner tab reads the live-title generation")
    func cornerTabReadsTheLiveTitleGeneration() throws {
        // Different `SessionStore` instance (`PopUpTerminalStoreFactory`), same
        // class — so the same channel, and the same freeze without it. The tab
        // names itself after the active pane's title.
        let path = "Sources/awesoMux/Views/PopUpTerminalCornerTabView.swift"
        let source = try SourceContract.source(at: path)
        let state = try SourceContract.declarationBody(
            after: "private var state: CornerTabState {",
            in: source,
            path: path
        )

        #expect(
            state.contains("sessionStore.liveTitleGeneration"),
            """
            `CornerTabState`'s computed `state` no longer reads \
            `sessionStore.liveTitleGeneration`, so the pop-up terminal's corner \
            tab keeps showing the active pane's title as of the last `groups` \
            publish (#311).
            """
        )
    }

    // MARK: - 2. Search

    @Test("search finds a workspace by a title written display-only")
    func searchFindsSilentlyWrittenTitle() {
        let fixture = Fixture()

        // Control: nothing matches the new name yet, so the match below can only
        // come from the write.
        #expect(Self.matchedIDs(in: fixture.store, query: "release").isEmpty)

        fixture.retitle("release prep", now: Date())

        // The write was silent — but it ticked the generation, which is what
        // re-runs the body that rebuilds this haystack…
        #expect(fixture.store.liveTitleGeneration == 1)
        // …and the haystack, rebuilt from the store's own `groups`, matches.
        #expect(Self.matchedIDs(in: fixture.store, query: "release") == [fixture.sessionID])
    }

    @Test("search no longer matches the superseded title")
    func searchDropsSupersededTitle() {
        let fixture = Fixture()
        #expect(Self.matchedIDs(in: fixture.store, query: "workspace") == [fixture.sessionID])

        fixture.retitle("release prep", now: Date())

        #expect(Self.matchedIDs(in: fixture.store, query: "workspace").isEmpty)
    }

    // MARK: - 3. VoiceOver: the rotor and the row must name the same workspace

    @Test("the rotor label and the row's own label agree on a silently-written title")
    func rotorAndRowLabelsAgree() throws {
        let fixture = Fixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        // Captured BEFORE the write and deliberately reused: this stale struct is
        // exactly what a frozen body would keep handing the rotor.
        let staleSession = try #require(fixture.store.session(id: fixture.sessionID))

        fixture.retitle("release prep", now: Date())

        // The row speaks the LIVE title (it renders inside a `LiveTitleScope`).
        let rowLabel = SidebarSessionTile.workspaceIdentityAccessibilityLabel(
            session: staleSession,
            rollup: staleSession.agentRollup(),
            // The channel the ROW reads. Asserting the fine property here would
            // compare the rotor against a string no sidebar row renders, which
            // is what this test exists to rule out.
            title: LiveTitles(box: box, reads: .everything).workspace
        )

        // The bug: a rotor built from the stale projection names it differently
        // from the row you land on (WCAG 4.1.2).
        #expect(Self.rotorLabel(for: staleSession) != rowLabel)

        // The fix: the generation re-runs the body, so the rotor is rebuilt from
        // the store's current `groups` and the two agree again.
        let freshSession = try #require(fixture.store.session(id: fixture.sessionID))
        #expect(Self.rotorLabel(for: freshSession) == rowLabel)
    }

    // MARK: - 4. Duplicate "N of M" ordinals

    @Test("duplicate ordinals see a silently-written title")
    func duplicateOrdinalsSeeSilentlyWrittenTitle() throws {
        let fixture = Fixture(secondSessionTitle: "release prep")

        // Control: the two workspaces have different titles, so neither is a
        // duplicate of the other.
        #expect(Self.ordinals(in: fixture.store).isEmpty)

        // A display-only write collides the first workspace's title with the
        // second's. Both share the group and the cwd, so this is a real duplicate.
        fixture.retitle("release prep", now: Date())

        let ordinals = Self.ordinals(in: fixture.store)
        #expect(ordinals.count == 2)
        #expect(ordinals[fixture.sessionID]?.total == 2)
    }

    // MARK: - 5. The agent activity panel's `.equatable()` gate

    @Test("the activity invalidation key moves on a display-only title write")
    func activityInvalidationKeyMovesOnSilentWrite() {
        let fixture = Fixture()
        let before = Self.activityKey(for: fixture.store)

        fixture.retitle("release prep", now: Date())

        // The key folds `groups`, so a body re-run rebuilds it from current
        // storage and the panel's gate opens. (Without the body re-run the key is
        // never rebuilt at all — that is the half check 1 above covers.)
        #expect(Self.activityKey(for: fixture.store) != before)
    }

    // MARK: - 6. The session peek card's header

    @Test("the peek card header follows the live channel, not the session struct")
    func peekCardHeaderFollowsLiveChannel() throws {
        let fixture = Fixture()
        let model = SidebarPeekModel()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let staleSession = try #require(fixture.store.session(id: fixture.sessionID))
        // The peek is shown from a sidebar row's scope, which reads
        // `LiveTitleReads.everything` — the coarse channel. The two writes below
        // are therefore spaced across the coalescing window on purpose: this
        // test is about `show`/`refresh` carrying the channel's title through to
        // the header, and back-to-back writes would coalesce into one and make
        // the second assertion prove nothing about `refresh`.
        let base = Date(timeIntervalSince1970: 1_000_000)

        fixture.retitle("release prep", now: base)

        // The hovering tile re-shows from its (stale) struct plus the live
        // channel — the pane rows were already wired this way; the header read
        // `session.title` and named the workspace by the superseded title.
        model.show(
            session: staleSession,
            location: .local("~"),
            tint: ProjectTint(groupName: "main", color: nil, index: 0),
            frame: .zero,
            liveTitles: LiveTitles(box: box, reads: .everything)
        )
        #expect(model.workspaceTitle == "release prep")
        #expect(staleSession.title == "workspace")

        // `refresh` is the path a title tick actually takes while the pointer
        // rests on the row, so it has to carry the title too.
        fixture.retitle(
            "ship it",
            now: base.addingTimeInterval(LiveTitleBox.coarseCoalescingInterval)
        )
        model.refresh(
            session: staleSession,
            location: .local("~"),
            tint: ProjectTint(groupName: "main", color: nil, index: 0),
            liveTitles: LiveTitles(box: box, reads: .everything)
        )
        #expect(model.workspaceTitle == "ship it")
    }

    // MARK: - Helpers

    /// One store holding real workspaces, so every projection below runs against
    /// the same silent `updatePane` path production uses.
    @MainActor
    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let paneID: TerminalPane.ID
        let secondSessionID: TerminalSession.ID

        init(secondSessionTitle: String = "other") {
            let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
            let session = TerminalSession(
                title: "workspace",
                workingDirectory: "~",
                layout: .pane(pane),
                activePaneID: pane.id
            )
            let secondPane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
            let second = TerminalSession(
                title: secondSessionTitle,
                workingDirectory: "~",
                layout: .pane(secondPane),
                activePaneID: secondPane.id
            )
            store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session, second])])
            sessionID = session.id
            paneID = pane.id
            secondSessionID = second.id
        }

        /// A display-only OSC title report: storage moves, `groups` does not
        /// publish, the generation ticks.
        /// `now` is required, not defaulted. The sidebar renders these titles
        /// through the coarse channel, so two writes that share a coalescing
        /// window collapse into one — a defaulted `Date()` would let a future
        /// test do that silently and assert against a stale title.
        func retitle(_ title: String, now: Date) {
            store.updatePane(sessionID: sessionID, paneID: paneID, title: title, now: now)
        }
    }

    private static func entries(in store: SessionStore, query: String = "") -> [SidebarGroupEntry] {
        SidebarView.searchProjection(groups: store.groups, query: query).entries
    }

    private static func matchedIDs(in store: SessionStore, query: String) -> [TerminalSession.ID] {
        entries(in: store, query: query).flatMap { $0.sessions.map(\.session.id) }
    }

    private static func ordinals(
        in store: SessionStore
    ) -> [TerminalSession.ID: SidebarDuplicateDisambiguation] {
        SidebarDuplicateDisambiguator.disambiguationBySessionID(for: entries(in: store))
    }

    private static func rotorLabel(for session: TerminalSession) -> String {
        SidebarVisibleRows.rotorEntries(
            for: [
                SidebarGroupEntry(
                    group: SessionGroup(name: "main", sessions: [session]),
                    unfilteredIndex: 0,
                    sessions: [SidebarSessionEntry(session: session, match: nil)]
                )
            ]
        )[0].label
    }

    private static func activityKey(for store: SessionStore) -> SidebarActivityInvalidationKey {
        SidebarActivityInvalidationKey(
            groups: store.groups,
            pinnedSessionIDs: store.pinnedSessionIDs,
            selectedSessionID: store.selectedSessionID,
            displayMode: .expanded,
            reduceMotion: false
        )
    }

}
