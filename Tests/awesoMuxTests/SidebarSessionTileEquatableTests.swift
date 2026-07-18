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
//   tintedHighContrast,
//   onSelect (closure), onNewSessionHere (closure), onAcknowledge (closure),
//   onMoveWithinGroup (closure), onMoveToGroup (closure), onClose (closure),
//   onClear (closure), onRename (closure), canMakeWorkspaceManaged,
//   onMakeWorkspaceManaged (closure), onToggleNotificationsMute (closure),
//   isPinned, onTogglePin (closure), pinnedOriginGroupName,
//   onDragStarted (closure), focusedRowTarget, isKeyboardNavigatingValue,
//   isKeyboardNavigating (@Binding), isHovered (@State), promotionPulseIsBright (@State),
//   promotionPulseTask (@State), isPeekVisible (@State), peekTask (@State),
//   tileFrame (@State), peekModel (@Environment), contrast (@Environment),
//   reduceMotion (@Environment), appSettingsStore (@Environment),
//   isCommandKeyHeld (@Environment).
//
// Every non-closure, non-@State, non-@Environment field above has a
// `RenderKey`/`PaneChromeKey`/`NeighborKey` field EXCEPT `focusedRowTarget`
// and `isKeyboardNavigating` (both `Binding`s — not comparable, write-only
// or already fully captured by a separately-supplied plain field:
// `isKeyboardFocused` for `focusedRowTarget`, `isKeyboardNavigatingValue`
// for `isKeyboardNavigating`). See the `RenderKey` doc comment in
// `SidebarSessionTile.swift` for the full exclusion rationale.
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
        notificationsMuted: Bool = false,
        workingDirectory: String = "~"
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
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
        // Defaults to an independent `.constant` per call, matching every
        // existing test's intent (fixed navigation state per tile). The
        // shared-binding production shape (one binding handed to every row)
        // is modeled explicitly in `isKeyboardNavigatingChangeRerenders`
        // below by passing a real `Binding` here.
        isKeyboardNavigatingBinding: Binding<Bool>? = nil,
        isPinned: Bool = false,
        pinnedOriginGroupName: String? = nil,
        activePaneID: TerminalPane.ID? = nil,
        previousNeighborGroup: SessionGroup? = nil,
        nextNeighborGroup: SessionGroup? = nil,
        otherGroups: [SessionGroup] = [],
        canMakeWorkspaceManaged: Bool = false,
        tintedHighContrast: Bool = false
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
            tintedHighContrast: tintedHighContrast,
            onSelect: {},
            onNewSessionHere: {},
            onAcknowledge: {},
            onMoveWithinGroup: { _ in },
            onMoveToGroup: { _ in },
            onClose: {},
            onClear: {},
            onRename: {},
            canMakeWorkspaceManaged: canMakeWorkspaceManaged,
            onMakeWorkspaceManaged: {},
            onToggleNotificationsMute: {},
            isPinned: isPinned,
            onTogglePin: {},
            pinnedOriginGroupName: pinnedOriginGroupName,
            onDragStarted: { UUID() },
            focusedRowTarget: focusState.projectedValue,
            isKeyboardNavigatingValue: isKeyboardNavigating,
            isKeyboardNavigating: isKeyboardNavigatingBinding ?? .constant(isKeyboardNavigating)
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

    @Test("isPinned difference compares NOT equal")
    func isPinnedChangeRerenders() {
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        let tileA = tile(session: sessionValue, isPinned: false)
        let tileB = tile(session: sessionValue, isPinned: true)

        #expect(tileA != tileB)
    }

    @Test("pinnedOriginGroupName difference compares NOT equal")
    func pinnedOriginGroupNameChangeRerenders() {
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        let tileA = tile(session: sessionValue, isPinned: true, pinnedOriginGroupName: "Group A")
        let tileB = tile(session: sessionValue, isPinned: true, pinnedOriginGroupName: "Group B")

        #expect(tileA != tileB)
    }

    @Test("isKeyboardNavigating snapshot difference compares NOT equal (shared binding, production shape)")
    func isKeyboardNavigatingChangeRerenders() {
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        // Production reality: `SidebarGroupView`/`SidebarPinnedSectionView`
        // hand ONE shared `@Binding` down to every row, so the OLD and NEW
        // tile instances compared by `==` observe the SAME backing storage —
        // not two independent bindings. Two `.constant` bindings (the
        // previous version of this test) can't catch a live-binding read in
        // `==`: each constant is permanently pinned to the value it was
        // built with, so the bug (reading through the binding at comparison
        // time instead of a captured snapshot) never surfaces. A single
        // mutable var behind one real `Binding` reproduces the sharing.
        var isKeyboardNavigating = false
        let sharedBinding = Binding<Bool>(
            get: { isKeyboardNavigating },
            set: { isKeyboardNavigating = $0 }
        )

        let tileA = tile(
            session: sessionValue,
            isKeyboardNavigating: isKeyboardNavigating,
            isKeyboardNavigatingBinding: sharedBinding
        )
        isKeyboardNavigating = true
        let tileB = tile(
            session: sessionValue,
            isKeyboardNavigating: isKeyboardNavigating,
            isKeyboardNavigatingBinding: sharedBinding
        )

        #expect(tileA != tileB)
    }

    @Test("per-pane agentKind difference compares NOT equal (rollup icon on priority ties)")
    func agentKindChangeRerenders() {
        let sharedID = UUID()
        let shellPane = pane(id: sharedID, kind: .shell)
        let claudePane = pane(id: sharedID, kind: .claudeCode)
        let otherPane = pane(title: "other")

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [shellPane, otherPane]))
        let tileB = tile(session: session(id: sessionID, panes: [claudePane, otherPane]))

        #expect(tileA != tileB)
    }

    @Test("attentionReason difference compares NOT equal")
    func attentionReasonChangeRerenders() {
        // Isolation fixture: a non-shell `agentKind` makes `effectiveChromeState`
        // return `agentState` unconditionally (TerminalPane.swift's
        // `guard agentKind == .shell else { return agentState }`), and
        // `.error` is a "dead pane" in `AgentDisplayState.init` — a lingering
        // low-priority `attentionReason` (`.bell`, priority 0) does not
        // outrank the recovery hint there, so both panes collapse to the same
        // `.error` chrome state despite differing `attentionReason`. That
        // isolates the assertion below to the `PaneChromeKey.attentionReason`
        // field alone, not `chromeState`.
        let id = UUID()
        let quiet = pane(id: id, kind: .claudeCode, execution: .error, attention: nil)
        let ringing = pane(id: id, kind: .claudeCode, execution: .error, attention: .bell)

        // Pin the isolation premise: both panes must render the same chrome
        // state before checking that the tile still distinguishes them.
        #expect(quiet.effectiveChromeState == ringing.effectiveChromeState)

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [quiet]))
        let tileB = tile(session: session(id: sessionID, panes: [ringing]))

        #expect(tileA != tileB)
    }

    @Test("unread count difference compares NOT equal")
    func unreadCountChangeRerenders() {
        let id = UUID()
        let quiet = pane(id: id, unread: 0)
        let loud = pane(id: id, unread: 3)

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [quiet]))
        let tileB = tile(session: session(id: sessionID, panes: [loud]))

        #expect(tileA != tileB)
    }

    @Test("tintedHighContrast difference compares NOT equal")
    func tintedHighContrastChangeRerenders() {
        // Pins INT-645's live-update path: the toggle flips in Settings while
        // the tile sits behind `.equatable()`, so the flag must be a compared
        // constructor snapshot — an in-tile store read would compare
        // permanently equal and leave the active border stale (PR #428).
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        let tileA = tile(session: sessionValue, isActive: true, tintedHighContrast: false)
        let tileB = tile(session: sessionValue, isActive: true, tintedHighContrast: true)

        #expect(tileA != tileB)
    }

    @Test("canMakeWorkspaceManaged difference compares NOT equal")
    func canMakeWorkspaceManagedChangeRerenders() {
        let onePane = pane()
        let sessionValue = session(panes: [onePane])

        let tileA = tile(session: sessionValue, canMakeWorkspaceManaged: false)
        let tileB = tile(session: sessionValue, canMakeWorkspaceManaged: true)

        #expect(tileA != tileB)
    }

    @Test("session-level workingDirectory difference compares NOT equal")
    func sessionWorkingDirectoryChangeRerenders() {
        // Pins A1: the active pane's own keyed cwd stays identical here — only
        // the session-level field (updated independently by a background
        // pane's cwd report) differs — so this can only fail if the render
        // key drops back to relying on the per-pane cwd alone.
        let onePane = pane()

        let sessionID = UUID()
        let tileA = tile(session: session(id: sessionID, panes: [onePane], workingDirectory: "~/project-a"))
        let tileB = tile(session: session(id: sessionID, panes: [onePane], workingDirectory: "~/project-b"))

        #expect(tileA != tileB)
    }
}
