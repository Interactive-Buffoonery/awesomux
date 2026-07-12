import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct SidebarPinnedProjectionTests {
    private func entry(_ group: SessionGroup, index: Int) -> SidebarGroupEntry {
        SidebarGroupEntry(
            group: group,
            unfilteredIndex: index,
            sessions: group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    }

    @Test func extractsPinnedInPinOrderAndHidesFromGroups() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g1 = SessionGroup(name: "One", sessions: [a, b])
        let g2 = SessionGroup(name: "Two", sessions: [c])
        let output = SidebarPinnedProjection.apply(
            entries: [entry(g1, index: 0), entry(g2, index: 1)],
            pinnedSessionIDs: [c.id, a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.pinned.map(\.entry.session.id) == [c.id, a.id])
        #expect(output.pinned[0].originGroup.id == g2.id)
        #expect(output.pinned[0].originGroupUnfilteredIndex == 1)
        #expect(output.entries.map { $0.sessions.map(\.session.id) } == [[b.id], []])
    }

    @Test func unfilteredKeepsEmptiedGroupsFilteringDropsThem() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let unfiltered = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(unfiltered.entries.count == 1)
        let filtering = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [a.id],
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(filtering.entries.isEmpty)
    }

    @Test func staleAndUnmatchedPinnedIDsAreSkipped() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [UUID(), a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.pinned.map(\.entry.session.id) == [a.id])
    }

    @Test func topMatchPrefersFirstPinnedMatchWhileFiltering() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a, b])
        let output = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [b.id],
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(output.topMatch == b.id)
    }

    @Test func topMatchFallsBackWhenNoPinnedMatch() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [UUID()],
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(output.topMatch == a.id)
        #expect(output.pinned.isEmpty)
    }

    @Test func topMatchNilWhenNotFiltering() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.topMatch == nil)
    }
}
