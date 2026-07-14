import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

// Full non-closure stored-property enumeration of `SidebarSessionTile`
// (mirrors the doc comment on `SidebarSessionTile.RenderKey` — kept here too
// so a reviewer can diff key fields against stored properties without
// jumping files):
//   session, match, tint, isActive, displayMode, isKeyboardFocused,
//   jumpIndex, hasBackgroundedFloatingWork, isPromotedInsertion,
//   isPromotionPulseActive, isFiltering, duplicateDisambiguation,
//   indexInGroup, sessionCountInGroup, ownerGroupIndex,
//   previousNeighborGroup, nextNeighborGroup, otherGroups, verticalPadding,
//   onSelect (closure), onNewSessionHere (closure), onAcknowledge (closure),
//   onMoveWithinGroup (closure), onMoveToGroup (closure), onClose (closure),
//   onClear (closure), onRename (closure), canMakeWorkspaceManaged,
//   onMakeWorkspaceManaged (closure), onToggleNotificationsMute (closure),
//   isPinned, onTogglePin (closure), pinnedOriginGroupName,
//   onDragStarted (closure), focusedRowTarget, isKeyboardNavigating
//   (@Binding), isHovered (@State), promotionPulseIsBright (@State),
//   promotionPulseTask (@State), isPeekVisible (@State), peekTask (@State),
//   tileFrame (@State), peekModel (@Environment), contrast (@Environment),
//   reduceMotion (@Environment), appSettingsStore (@Environment),
//   isCommandKeyHeld (@Environment).
//
// Every non-closure, non-@State, non-@Environment field above has a
// `RenderKey`/`PaneChromeKey`/`NeighborKey` field EXCEPT `focusedRowTarget`
// (a `Binding` — not comparable, and its rendered effect is already fully
// captured by the separately-supplied `isKeyboardFocused`). See the
// `RenderKey` doc comment in `SidebarSessionTile.swift` for the full
// exclusion rationale.
@MainActor
@Suite("SidebarSessionTile render-key equality")
struct SidebarSessionTileEquatableTests {
    // MARK: - Fixtures

    private func pane(
        id: UUID = UUID(),
        title: String = "pane",
        cwd: String = "~",
        kind: AgentKind = .shell,
        execution: AgentExecutionState = .idle,
        attention: AttentionReason? = nil,
        shellActivity: ShellActivity = .idle,
        progress: TerminalProgressReport? = nil,
        unread: Int = 0,
        remoteHost: String? = nil
    ) -> TerminalPane {
        TerminalPane(
            id: id,
            title: title,
            workingDirectory: cwd,
            remoteHost: remoteHost,
            agentKind: kind,
            agentExecutionState: execution,
            attentionReason: attention,
            shellActivity: shellActivity,
            progressReport: progress,
            unreadNotificationCount: unread,
            executionPlan: .local
        )
    }

    /// Right-leaning split so tree-traversal order matches array order — the
    /// same helper shape `PanePeekItemTests` uses.
    private func layout(_ panes: [TerminalPane]) -> TerminalPaneLayout {
        guard panes.count > 1 else {
            return .pane(panes[0])
        }
        var result = TerminalPaneLayout.pane(panes[panes.count - 1])
        for pane in panes.dropLast().reversed() {
            result = .split(TerminalSplit(orientation: .vertical, first: .pane(pane), second: result))
        }
        return result
    }

    private func session(
        id: UUID = UUID(),
        title: String = "workspace",
        panes: [TerminalPane],
        activePaneID: TerminalPane.ID? = nil,
        notificationsMuted: Bool = false
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: "~",
            notificationsMuted: notificationsMuted,
            layout: layout(panes),
            activePaneID: activePaneID ?? panes[0].id
        )
    }

    private let groupA = SessionGroup(name: "Group A", sessions: [])
    private let groupB = SessionGroup(name: "Group B", sessions: [])

    /// Builds a tile from a session, with every other rendered input pinned
    /// to a fixed baseline so tests vary exactly one thing. Closures are
    /// no-ops; `focusedRowTarget` gets a fresh, unmounted `FocusState` (safe
    /// because the render key deliberately excludes it — see the doc
    /// comment).
    private func tile(
        session: TerminalSession,
        isActive: Bool = false,
        isKeyboardFocused: Bool = false,
        isKeyboardNavigating: Bool = false,
        isPinned: Bool = false,
        pinnedOriginGroupName: String? = nil,
        activePaneID: TerminalPane.ID? = nil,
        previousNeighborGroup: SessionGroup? = nil,
        nextNeighborGroup: SessionGroup? = nil,
        otherGroups: [SessionGroup] = []
    ) -> SidebarSessionTile {
        let focusState = FocusState<SidebarVisibleRowTarget?>()
        return SidebarSessionTile(
            session: session,
            match: nil,
            tint: ProjectTint(groupName: "Test", color: nil, index: 0),
            isActive: isActive,
            displayMode: .expanded,
            isKeyboardFocused: isKeyboardFocused,
            jumpIndex: nil,
            hasBackgroundedFloatingWork: false,
            isPromotedInsertion: false,
            isPromotionPulseActive: false,
            isFiltering: false,
            duplicateDisambiguation: nil,
            indexInGroup: 0,
            sessionCountInGroup: 1,
            ownerGroupIndex: 0,
            previousNeighborGroup: previousNeighborGroup,
            nextNeighborGroup: nextNeighborGroup,
            otherGroups: otherGroups,
            verticalPadding: 9,
            onSelect: {},
            onNewSessionHere: {},
            onAcknowledge: {},
            onMoveWithinGroup: { _ in },
            onMoveToGroup: { _ in },
            onClose: {},
            onClear: {},
            onRename: {},
            canMakeWorkspaceManaged: false,
            onMakeWorkspaceManaged: {},
            onToggleNotificationsMute: {},
            isPinned: isPinned,
            onTogglePin: {},
            pinnedOriginGroupName: pinnedOriginGroupName,
            onDragStarted: { UUID() },
            focusedRowTarget: focusState.projectedValue,
            isKeyboardNavigating: .constant(isKeyboardNavigating)
        )
    }

    // MARK: - Tests

    @Test("timestamp-only difference compares equal")
    func heartbeatOnlyChangeIsEqual() {
        let sessionID = UUID()
        let paneID = UUID()
        let paneA = pane(id: paneID, execution: .running)
        var paneB = paneA
        paneB.lastAgentStateChangeAt = paneA.lastAgentStateChangeAt.addingTimeInterval(120)

        let tileA = tile(session: session(id: sessionID, panes: [paneA]))
        let tileB = tile(session: session(id: sessionID, panes: [paneB]))

        #expect(tileA == tileB)
    }

    @Test("shellActivity difference compares NOT equal")
    func shellActivityChangeRerenders() {
        let id = UUID()
        let idle = pane(id: id, kind: .shell, shellActivity: .idle)
        let busy = pane(id: id, kind: .shell, shellActivity: .busy)

        // Pin the premise: raw `TerminalPane.==` would call these equal…
        #expect(idle == busy)

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [idle]))
        let tileB = tile(session: session(id: sessionID, panes: [busy]))

        // …but the render key folds `effectiveChromeState`, so it must not.
        #expect(tileA != tileB)
    }

    @Test("progress report difference compares NOT equal")
    func progressChangeRerenders() {
        let id = UUID()
        let paneA = pane(id: id, progress: nil)
        let paneB = pane(id: id, progress: TerminalProgressReport(state: .set, progress: 50))

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [paneA]))
        let tileB = tile(session: session(id: sessionID, panes: [paneB]))

        #expect(tileA != tileB)
    }

    @Test("mute toggle compares NOT equal")
    func muteChangeRerenders() {
        let onePane = pane()
        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [onePane], notificationsMuted: false))
        let tileB = tile(session: session(id: sessionID, panes: [onePane], notificationsMuted: true))

        #expect(tileA != tileB)
    }

    @Test("active-pane change compares NOT equal")
    func activePaneChangeRerenders() {
        let paneA = pane(title: "a")
        let paneB = pane(title: "b")
        let sessionID = UUID()

        let tileA = tile(session: session(id: sessionID, panes: [paneA, paneB], activePaneID: paneA.id))
        let tileB = tile(session: session(id: sessionID, panes: [paneA, paneB], activePaneID: paneB.id))

        #expect(tileA != tileB)
    }

    @Test("pane reorder compares NOT equal")
    func paneReorderRerenders() {
        let paneA = pane(title: "a")
        let paneB = pane(title: "b")
        let sessionID = UUID()

        let forward = session(id: sessionID, panes: [paneA, paneB], activePaneID: paneA.id)
        let reversed = session(id: sessionID, panes: [paneB, paneA], activePaneID: paneA.id)

        #expect(tile(session: forward) != tile(session: reversed))
    }

    @Test("active pane remoteHost / cwd change compares NOT equal")
    func locationChangeRerenders() {
        let id = UUID()
        let local = pane(id: id, cwd: "~/project")
        let remote = pane(id: id, cwd: "~/project", remoteHost: "devbox")

        let hostSessionID = UUID()
        #expect(
            tile(session: session(id: hostSessionID, panes: [local]))
                != tile(session: session(id: hostSessionID, panes: [remote]))
        )

        let cwdA = pane(id: id, cwd: "~/project-a")
        let cwdB = pane(id: id, cwd: "~/project-b")

        let cwdSessionID = UUID()
        #expect(
            tile(session: session(id: cwdSessionID, panes: [cwdA]))
                != tile(session: session(id: cwdSessionID, panes: [cwdB]))
        )
    }

    @Test("unrelated other-group rename compares NOT equal (menu content)")
    func otherGroupRenameRerenders() {
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        var renamedGroupB = groupB
        renamedGroupB.name = "Group B renamed"

        let tileA = tile(session: sessionValue, otherGroups: [groupA, groupB])
        let tileB = tile(session: sessionValue, otherGroups: [groupA, renamedGroupB])

        #expect(tileA != tileB)
    }
}
