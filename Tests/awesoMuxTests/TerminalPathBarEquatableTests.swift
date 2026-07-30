import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing

@testable import awesoMux

/// Issue #311 / INT-523: the path bar's render gate.
///
/// The bar mounts inside a `LiveTitleScope`, so a display-only title write
/// rebuilds its view value on every tick of every pane in the workspace. This
/// gate decides which of those ticks are allowed to re-diff its ~30-node
/// accessibility-heavy tree and re-key its filesystem+git resolve:
///
/// - the ACTIVE pane's title must pass. It is the ONLY signal by which an
///   in-place `git checkout` (cwd unchanged, prompt-embedded title changed)
///   reaches the branch chip. Freezing it is silent.
/// - a BACKGROUND pane's title must NOT. That is the cost this gate removes.
@MainActor
@Suite("TerminalPathBarView render gate (#311 / INT-523)")
struct TerminalPathBarEquatableTests {

    // MARK: - The live-title half

    @Test("an ACTIVE-pane display-only title move compares NOT equal")
    func activePaneLiveTitleMoveRerenders() throws {
        // The workspace title is USER-FROZEN first, so
        // `syncSessionChromeToActivePane` stops promoting the active pane's title
        // into it. Without that freeze the promotion moves BOTH key fields and
        // this test passes even with `activePaneTitle` removed entirely — the
        // exact vacuous-green shape the review found in
        // `SidebarSessionTileEquatableTests.swift:482`.
        let fixture = try Fixture(split: true, frozenWorkspaceTitle: "release prep")
        // Reused for BOTH bars on purpose: a display-only write doesn't publish
        // `groups`, so this stale struct is exactly what the scope rebuilds the
        // bar from. Only the box can tell the two apart.
        let staleSession = fixture.session
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let before = fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box))

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: staleSession.activePaneID,
            title: "~/repo (release/1.2)"
        )

        // Premise: ONLY the active pane's entry moved.
        #expect(box.paneTitles[staleSession.activePaneID] == "~/repo (release/1.2)")
        #expect(box.workspaceTitle == "release prep")

        let after = fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box))
        #expect(before != after)

        // Control, and the exact failure this half exists to prevent: with no
        // channel wired the same two renders compare EQUAL, `resolveKey` never
        // moves, and the branch chip keeps naming the pre-checkout branch.
        #expect(
            fixture.bar(session: staleSession) == fixture.bar(session: staleSession)
        )
    }

    @Test("an INACTIVE pane's display-only title move compares EQUAL")
    func inactivePaneLiveTitleMoveIsIgnored() throws {
        let fixture = try Fixture(split: true)
        let staleSession = fixture.session
        let inactivePaneID = try #require(
            staleSession.panes.first { $0.id != staleSession.activePaneID }?.id
        )
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let before = fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box))

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: inactivePaneID,
            title: "vim"
        )

        // Premise: the box really did move — the assertion below is the gate
        // filtering it out, not the write failing to land.
        #expect(box.paneTitles[inactivePaneID] == "vim")
        // An inactive pane is not promoted into the workspace title either, so
        // this isolates the per-pane half.
        #expect(box.workspaceTitle == staleSession.title)
        #expect(fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box)) == before)
    }

    @Test("a workspace-title move compares NOT equal")
    func workspaceTitleMoveRerenders() throws {
        // `resolveKey.fallbackProject` is the workspace title, so a rename that
        // leaves every pane title alone still has to re-key the resolve.
        let fixture = try Fixture(split: true)
        let staleSession = fixture.session
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)
        let before = fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box))

        fixture.store.renameSession(id: fixture.sessionID, title: "release prep")

        #expect(box.workspaceTitle == "release prep")
        #expect(fixture.bar(session: staleSession, liveTitles: LiveTitles(box: box)) != before)
    }

    // MARK: - Everything else the body renders but does not own as @State

    @Test("an active-pane switch compares NOT equal")
    func activePaneSwitchRerenders() throws {
        let fixture = try Fixture(split: true)
        let session = fixture.session
        let otherPaneID = try #require(session.panes.first { $0.id != session.activePaneID }?.id)
        var switched = session
        switched.activePaneID = otherPaneID

        #expect(fixture.bar(session: session) != fixture.bar(session: switched))
    }

    @Test("an active-pane cwd move compares NOT equal")
    func activePaneWorkingDirectoryMoveRerenders() throws {
        let fixture = try Fixture()
        let session = fixture.session
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: session.activePaneID,
            workingDirectory: NSHomeDirectory()
        )
        let moved = try #require(fixture.store.session(id: fixture.sessionID))

        #expect(fixture.bar(session: session) != fixture.bar(session: moved))
    }

    @Test("a session-level cwd move compares NOT equal")
    func sessionWorkingDirectoryMoveRerenders() throws {
        // The fallback every key uses when the active pane has no cwd of its own.
        let fixture = try Fixture()
        var moved = fixture.session
        moved.workingDirectory = NSHomeDirectory()

        #expect(fixture.bar(session: fixture.session) != fixture.bar(session: moved))
    }

    @Test("a remote flip compares NOT equal")
    func remoteFlipRerenders() throws {
        let fixture = try Fixture()
        // Identity pinned across the pair — see `Fixture.session`. Without this
        // the assertion is carried by three fresh UUIDs and passes with
        // `remoteHost` deleted from the key.
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let local = Fixture.session(id: id, paneID: paneID, terminalSessionID: amx)
        let remote = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx, remoteHost: "devbox"
        )

        #expect(fixture.bar(session: local) != fixture.bar(session: remote))
    }

    @Test("a remote connection health change compares NOT equal")
    func remoteHealthChangeRerenders() throws {
        // Drives both the indicator's icon/copy and the spoken
        // `PathBarExecutionAnnouncement` transition.
        let fixture = try Fixture()
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let active = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx,
            remoteHost: "devbox", health: .active
        )
        let stale = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx,
            remoteHost: "devbox", health: .possiblyStale
        )

        #expect(fixture.bar(session: active) != fixture.bar(session: stale))
    }

    @Test("a declared SSH execution plan compares NOT equal")
    func executionPlanChangeRerenders() throws {
        // Declared SSH identity, with the presentation host UNCHANGED — so this
        // can only fail if `executionPlan` itself is dropped from the key. The
        // plan is what suppresses every local chip and gates Reveal / Copy Path.
        let fixture = try Fixture()
        let target = try #require(RemoteTarget(parsing: "devbox"))
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let declared = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx,
            remoteHost: "devbox",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let sniffed = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx, remoteHost: "devbox"
        )

        #expect(sniffed.activePane?.remotePresentationHost == declared.activePane?.remotePresentationHost)
        #expect(fixture.bar(session: sniffed) != fixture.bar(session: declared))
    }

    @Test("an agent-kind change compares NOT equal")
    func agentKindChangeRerenders() throws {
        // Gates whether the PR / CI / branch foldouts may TYPE a command into the
        // pane. A shell→agent transition behind the gate would keep offering to
        // inject into an agent's stdin.
        let fixture = try Fixture()
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let shell = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx, agentKind: .shell
        )
        let agent = Fixture.session(
            id: id, paneID: paneID, terminalSessionID: amx, agentKind: .claudeCode
        )

        #expect(fixture.bar(session: shell) != fixture.bar(session: agent))
    }

    // MARK: - The bridge cwd poll's task id

    @Test("an empty→established bridge metadata flip re-keys the poll task")
    func bridgeEstablishmentRestartsThePoll() throws {
        // A surface renders FIRST with `.empty` metadata and publishes
        // `established` only after spawning, so this flip is the only moment the
        // poll can begin. Both keys must move: `bridgePollKey` because it is the
        // task's id, and `renderKey` because `body` — which is what evaluates
        // `.task(id:)` — does not re-run behind `.equatable()` otherwise.
        let fixture = try Fixture()
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let spawning = Fixture.session(id: id, paneID: paneID, terminalSessionID: amx)
        let established = Fixture.session(
            id: id,
            paneID: paneID,
            terminalSessionID: amx,
            terminalBackendMetadata: AmxBackend.establishedSessionMetadata
        )

        // Premise: only the metadata moved.
        #expect(spawning.activePane?.terminalBackendMetadata == .empty)
        #expect(spawning.activePaneID == established.activePaneID)
        let spawningBar = fixture.bar(session: spawning, isCommandBridgeEnabled: true)
        let establishedBar = fixture.bar(session: established, isCommandBridgeEnabled: true)
        #expect(spawningBar.bridgePollKey != establishedBar.bridgePollKey)
        #expect(spawningBar != establishedBar)
    }

    @Test("a same-pane AMX session replacement re-keys the poll task")
    func terminalSessionReplacementRestartsThePoll() throws {
        // A recycle/respawn keeps the pane's UI identity and swaps the durable
        // AMX session id. The poll captures that id ONCE at task start, so a key
        // that ignores it keeps querying `amx cwd` against the retired session.
        let fixture = try Fixture()
        let id = UUID()
        let paneID = UUID()
        let before = Fixture.session(
            id: id,
            paneID: paneID,
            terminalSessionID: .generate(),
            terminalBackendMetadata: AmxBackend.establishedSessionMetadata
        )
        let after = Fixture.session(
            id: id,
            paneID: paneID,
            terminalSessionID: .generate(),
            terminalBackendMetadata: AmxBackend.establishedSessionMetadata
        )

        #expect(before.activePaneID == after.activePaneID)
        #expect(
            fixture.bar(session: before).bridgePollKey
                != fixture.bar(session: after).bridgePollKey
        )
        #expect(fixture.bar(session: before) != fixture.bar(session: after))
    }

    @Test("a bridge cwd write-back does NOT re-key the poll task")
    func cwdWriteBackDoesNotRestartThePoll() throws {
        // The spin loop the key's `workingDirectory` omission exists to prevent:
        // a bridge pane never emits OSC 7, so the poll writing cwd back into the
        // store is the ONLY thing that moves it. Re-keying on that would cancel
        // and restart the poll on every successful query, forever.
        let fixture = try Fixture()
        let id = UUID()
        let paneID = UUID()
        let amx = TerminalSessionID.generate()
        let before = Fixture.session(
            id: id,
            paneID: paneID,
            terminalSessionID: amx,
            terminalBackendMetadata: AmxBackend.establishedSessionMetadata
        )
        var after = before
        var pane = try #require(after.activePane)
        pane.workingDirectory = NSHomeDirectory()
        after.layout = .pane(pane)

        #expect(
            fixture.bar(session: before).bridgePollKey
                == fixture.bar(session: after).bridgePollKey
        )
        // The RENDER key still moves — the bar displays that path.
        #expect(fixture.bar(session: before) != fixture.bar(session: after))
    }

    @Test("the presented menu compares NOT equal")
    func presentedMenuChangeRerenders() throws {
        // The parent owns this as `@State` and hands it down as a `@Binding`, so
        // the gate has to compare its VALUE — otherwise the parent's re-render
        // finds the bar equal, `body` never re-runs, and no foldout ever opens.
        let fixture = try Fixture()

        #expect(
            fixture.bar(session: fixture.session, presentedMenu: nil)
                != fixture.bar(session: fixture.session, presentedMenu: .branches)
        )
    }

    @Test("window activation compares NOT equal")
    func windowActivationRerenders() throws {
        // Re-resolving on window-active is what catches a `git checkout` made
        // while the window was in the background. It is an `@Environment` read at
        // the mount site precisely because a read inside the gate would stale
        // (PR #428).
        let fixture = try Fixture()

        #expect(
            fixture.bar(session: fixture.session, isWindowActive: false)
                != fixture.bar(session: fixture.session, isWindowActive: true)
        )
    }

    @Test("an accent change compares NOT equal")
    func accentChangeRerenders() throws {
        let fixture = try Fixture()

        #expect(
            fixture.bar(session: fixture.session, accent: .peach)
                != fixture.bar(session: fixture.session, accent: .mauve)
        )
    }

    @Test("the command-bridge and IDE settings compare NOT equal")
    func settingSnapshotsRerender() throws {
        let fixture = try Fixture()
        let baseline = fixture.bar(session: fixture.session)

        #expect(fixture.bar(session: fixture.session, isCommandBridgeEnabled: true) != baseline)
        #expect(fixture.bar(session: fixture.session, isOpenInIDEEnabled: true) != baseline)
        #expect(fixture.bar(session: fixture.session, idePriority: ["com.example.ide"]) != baseline)
    }

    @Test("an unrelated pane field compares EQUAL")
    func unrelatedFieldIsIgnored() throws {
        // The bar renders no agent state, so a heartbeat or an unread badge must
        // not re-diff it.
        let fixture = try Fixture()
        var noisy = fixture.session
        var pane = try #require(noisy.activePane)
        pane.unreadNotificationCount = 7
        pane.lastAgentStateChangeAt = pane.lastAgentStateChangeAt.addingTimeInterval(120)
        noisy.layout = .pane(pane)

        #expect(fixture.bar(session: fixture.session) == fixture.bar(session: noisy))
    }

    // MARK: - Helpers

    @MainActor
    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        /// Snapshot taken at construction — the stale struct a display-only write
        /// leaves the scope rebuilding from.
        let session: TerminalSession

        init(split: Bool = false, frozenWorkspaceTitle: String? = nil) throws {
            let value = Self.session()
            store = SessionStore(groups: [SessionGroup(name: "main", sessions: [value])])
            sessionID = value.id
            if split {
                _ = try #require(store.splitActivePane(orientation: .horizontal, in: value.id))
            }
            if let frozenWorkspaceTitle {
                store.renameSession(id: value.id, title: frozenWorkspaceTitle)
            }
            session = try #require(store.session(id: value.id))
        }

        /// `id:` / `paneID:` / `terminalSessionID:` exist so a pair of sessions
        /// built for an equality assertion can be pinned to ONE identity. Left
        /// defaulted, every call mints fresh UUIDs — and `sessionID`,
        /// `activePaneID`, and `activePaneTerminalSessionID` are all `RenderKey`
        /// fields, so a `!=` assertion between two unpinned calls is carried
        /// entirely by identity and stays green with the field under test deleted
        /// from the key. Four tests in this file shipped in exactly that shape.
        static func session(
            id: TerminalSession.ID = UUID(),
            paneID: TerminalPane.ID = UUID(),
            terminalSessionID: TerminalSessionID = .generate(),
            terminalBackendMetadata: TerminalBackendMetadata = .empty,
            remoteHost: String? = nil,
            health: RemoteConnectionHealth = .active,
            agentKind: AgentKind = .shell,
            executionPlan: PaneExecutionPlan = .local
        ) -> TerminalSession {
            let pane = TerminalPane(
                id: paneID,
                terminalSessionID: terminalSessionID,
                terminalBackendMetadata: terminalBackendMetadata,
                title: "pane",
                workingDirectory: "/tmp/repo",
                remoteHost: remoteHost,
                remoteConnectionHealth: health,
                agentKind: agentKind,
                executionPlan: executionPlan
            )
            return TerminalSession(
                id: id,
                title: "workspace",
                workingDirectory: "/tmp/repo",
                layout: .pane(pane),
                activePaneID: pane.id
            )
        }

        /// A bar with every rendered input pinned to a fixed baseline, so each
        /// test varies exactly one thing.
        func bar(
            session: TerminalSession,
            liveTitles: LiveTitles = .unavailable,
            presentedMenu: PathBarMenu? = nil,
            isWindowActive: Bool = true,
            accent: AwAccent = .peach,
            isCommandBridgeEnabled: Bool = false,
            isOpenInIDEEnabled: Bool = false,
            idePriority: [String] = []
        ) -> TerminalPathBarView {
            TerminalPathBarView(
                session: session,
                sendTextToActivePane: { _ in },
                sessionStore: store,
                isCommandBridgeEnabled: isCommandBridgeEnabled,
                openInIDE: nil,
                openInIDEWithApp: nil,
                isOpenInIDEEnabled: isOpenInIDEEnabled,
                idePriority: idePriority,
                isWindowActive: isWindowActive,
                accent: accent,
                liveTitles: liveTitles,
                presentedMenu: .constant(presentedMenu)
            )
        }
    }
}
