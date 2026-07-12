import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct SidebarVisibleRowsPinnedTests {
    private func fixtures() -> (pinned: [PinnedSessionEntry], entries: [SidebarGroupEntry], pinnedSession: TerminalSession, groupSession: TerminalSession, group: SessionGroup) {
        let pinnedSession = TerminalSession(title: "pinned", workingDirectory: "~")
        let groupSession = TerminalSession(title: "normal", workingDirectory: "~")
        let origin = SessionGroup(name: "Origin", sessions: [pinnedSession])
        let group = SessionGroup(name: "One", sessions: [groupSession])
        let pinned = [PinnedSessionEntry(
            entry: SidebarSessionEntry(session: pinnedSession, match: nil),
            originGroup: origin,
            originGroupUnfilteredIndex: 0
        )]
        let entries = [SidebarGroupEntry(
            group: group,
            unfilteredIndex: 1,
            sessions: [SidebarSessionEntry(session: groupSession, match: nil)]
        )]
        return (pinned, entries, pinnedSession, groupSession, group)
    }

    @Test func pinnedRowsComeFirstWithNoHeaderRow() {
        let f = fixtures()
        let rows = SidebarVisibleRows.rows(
            pinned: f.pinned,
            for: f.entries,
            collapsedGroupIDs: [],
            isFiltering: false
        )
        #expect(rows.map(\.target) == [
            .session(f.pinnedSession.id),
            .group(f.group.id),
            .session(f.groupSession.id)
        ])
    }

    @Test func pinnedRowsIgnoreGroupCollapse() {
        let f = fixtures()
        let rows = SidebarVisibleRows.rows(
            pinned: f.pinned,
            for: f.entries,
            collapsedGroupIDs: [f.group.id],
            isFiltering: false
        )
        #expect(rows.map(\.target) == [
            .session(f.pinnedSession.id),
            .group(f.group.id)
        ])
    }

    @Test func emptyPinnedKeepsExistingBehavior() {
        let f = fixtures()
        let rows = SidebarVisibleRows.rows(
            for: f.entries,
            collapsedGroupIDs: [],
            isFiltering: false
        )
        #expect(rows.first?.target == .group(f.group.id))
    }

    @Test func rotorListsPinnedFirst() {
        let f = fixtures()
        let rotor = SidebarVisibleRows.rotorEntries(pinned: f.pinned, for: f.entries)
        #expect(rotor.map(\.id) == [f.pinnedSession.id, f.groupSession.id])
    }
}
