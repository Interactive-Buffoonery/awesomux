import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct SidebarVisibleRowsAttentionTests {
    private func lifted(_ session: TerminalSession, from group: SessionGroup) -> LiftedSessionEntry {
        LiftedSessionEntry(
            entry: SidebarSessionEntry(session: session, match: nil),
            originGroup: group,
            originGroupUnfilteredIndex: 0
        )
    }

    private func entry(_ group: SessionGroup, index: Int) -> SidebarGroupEntry {
        SidebarGroupEntry(
            group: group,
            unfilteredIndex: index,
            sessions: group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    }

    @Test func attentionRowsPrecedePinnedAndGroupRows() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [c])
        let rows = SidebarVisibleRows.rows(
            attention: [lifted(a, from: g)],
            pinned: [lifted(b, from: g)],
            for: [entry(g, index: 0)],
            collapsedGroupIDs: [],
            isFiltering: false
        )
        #expect(rows.map(\.target) == [.session(a.id), .session(b.id), .group(g.id), .session(c.id)])
    }

    @Test func attentionRowsHaveNoHeaderTarget() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [])
        let rows = SidebarVisibleRows.rows(
            attention: [lifted(a, from: g)],
            for: [],
            collapsedGroupIDs: [],
            isFiltering: false
        )
        #expect(rows.map(\.target) == [.session(a.id)])
    }

    @Test func attentionRowsSurviveGroupCollapse() {
        // A lifted row renders outside its group, so collapsing the origin group
        // must not remove it from the walk.
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [c])
        let rows = SidebarVisibleRows.rows(
            attention: [lifted(a, from: g)],
            for: [entry(g, index: 0)],
            collapsedGroupIDs: [g.id],
            isFiltering: false
        )
        #expect(rows.map(\.target) == [.session(a.id), .group(g.id)])
    }

    @Test func rotorListsAttentionFirst() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [c])
        let entries = SidebarVisibleRows.rotorEntries(
            attention: [lifted(a, from: g)],
            pinned: [lifted(b, from: g)],
            for: [entry(g, index: 0)]
        )
        #expect(entries.map(\.id) == [a.id, b.id, c.id])
    }

    /// A lifted row sits above its group for a reason the rotor used to keep to
    /// itself. The two synthetic sections lift for DIFFERENT reasons, so the
    /// labels must differ — announcing a pinned row as needing input would be a
    /// worse regression than the original silence.
    @Test func rotorNamesWhyEachRowIsLifted() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~", agentKind: .shell)
        let b = TerminalSession(title: "beta", workingDirectory: "~", agentKind: .shell)
        let c = TerminalSession(title: "gamma", workingDirectory: "~", agentKind: .shell)
        let g = SessionGroup(name: "One", sessions: [c])
        let entries = SidebarVisibleRows.rotorEntries(
            attention: [lifted(a, from: g)],
            pinned: [lifted(b, from: g)],
            for: [entry(g, index: 0)]
        )

        #expect(
            entries.map(\.label) == [
                "alpha, Shell, Idle, Needs input, from One",
                "beta, Shell, Idle, Pinned, from One",
                "gamma, Shell, Idle",
            ])
    }
}
