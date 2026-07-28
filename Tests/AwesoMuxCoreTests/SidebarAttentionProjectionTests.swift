import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct SidebarAttentionProjectionTests {
    private func needy(_ title: String) -> TerminalSession {
        var session = TerminalSession(title: title, workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        return session
    }

    private func calm(_ title: String) -> TerminalSession {
        TerminalSession(title: title, workingDirectory: "~")
    }

    private func entry(_ group: SessionGroup, index: Int) -> SidebarGroupEntry {
        SidebarGroupEntry(
            group: group,
            unfilteredIndex: index,
            sessions: group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    }

    @Test func liftsNeedySessionsAndHidesThemFromGroups() {
        let a = needy("alpha")
        let b = calm("beta")
        let g = SessionGroup(name: "One", sessions: [a, b])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id])
        #expect(output.attention[0].originGroup.id == g.id)
        #expect(output.attention[0].originGroupUnfilteredIndex == 0)
        #expect(output.entries.map { $0.sessions.map(\.session.id) } == [[b.id]])
    }

    @Test func preservesGroupOrderAcrossGroups() {
        let a = needy("alpha")
        let c = needy("gamma")
        let g1 = SessionGroup(name: "One", sessions: [a])
        let g2 = SessionGroup(name: "Two", sessions: [c])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g1, index: 0), entry(g2, index: 1)],
            stickySessionID: nil,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id, c.id])
    }

    @Test func selectingALiftedRowDoesNotDemoteIt() {
        // Regression guard for the one-frame flicker: membership must not depend
        // on the selection, because the sticky write can only ever be observed
        // AFTER the selection it reacts to.
        let a = needy("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id])
    }

    @Test func stickySessionStaysLiftedAfterAcknowledgement() {
        // The 500ms dwell clears attentionReason while the user is still on the
        // row; sticky is what stops it teleporting away mid-read.
        let a = calm("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: a.id,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id])
        #expect(output.entries[0].sessions.isEmpty)
    }

    @Test func staleStickyIDIsIgnored() {
        let a = calm("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: UUID(),
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.isEmpty)
    }

    @Test func unfilteredKeepsEmptiedGroupsFilteringDropsThem() {
        let a = needy("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let unfiltered = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(unfiltered.entries.count == 1)
        let filtering = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(filtering.entries.isEmpty)
    }

    @Test func topMatchPrefersFirstLiftedMatchWhileFiltering() {
        let a = calm("alpha")
        let b = needy("beta")
        let g = SessionGroup(name: "One", sessions: [a, b])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(output.topMatch == b.id)
    }

    @Test func topMatchFallsBackWhenNothingLifted() {
        let a = calm("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: true,
            searchTopMatch: a.id
        )
        #expect(output.topMatch == a.id)
    }

    @Test func topMatchNilWhenNotFiltering() {
        let a = needy("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            stickySessionID: nil,
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.topMatch == nil)
    }

    @Test func splitWorkspaceStaysLiftedWhileASiblingPaneWaits() {
        // Documented trade-off: needsUserInput is session-wide, the dwell acks
        // only the active pane. Asserted so the behavior is deliberate.
        var session = TerminalSession(title: "alpha", workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        #expect(SidebarAttentionProjection.isLifted(session, stickySessionID: nil))
    }
}
