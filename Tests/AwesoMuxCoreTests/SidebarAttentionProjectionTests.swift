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

    @Test func liftsListedSessionsAndHidesThemFromGroups() {
        let a = needy("alpha")
        let b = calm("beta")
        let g = SessionGroup(name: "One", sessions: [a, b])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id])
        #expect(output.attention[0].originGroup.id == g.id)
        #expect(output.attention[0].originGroupUnfilteredIndex == 0)
        #expect(output.entries.map { $0.sessions.map(\.session.id) } == [[b.id]])
    }

    /// Was `preservesGroupOrderAcrossGroups`. The section is ordered by ARRIVAL
    /// now — first to ask sits at the top — so the projection emits the store's
    /// list order verbatim. Group order here is the reverse of the list, which
    /// is exactly the case a group-ordered walk would get wrong.
    @Test func emitsTheStoresArrivalOrderNotGroupOrder() {
        let a = needy("alpha")
        let c = needy("gamma")
        let g1 = SessionGroup(name: "One", sessions: [a])
        let g2 = SessionGroup(name: "Two", sessions: [c])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g1, index: 0), entry(g2, index: 1)],
            liftedSessionIDs: [c.id, a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [c.id, a.id])
    }

    @Test func stickySessionStaysLiftedAfterAcknowledgement() {
        // The 500ms dwell clears attentionReason while the user is still on the
        // row; the store's sticky is what keeps its ID in `liftedSessionIDs`.
        // The projection must honor that list rather than re-deriving from
        // `needsUserInput`, or the row teleports away mid-read.
        let a = calm("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.map(\.entry.session.id) == [a.id])
        #expect(output.entries[0].sessions.isEmpty)
    }

    @Test func staleIDInTheListIsIgnored() {
        let a = calm("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let output = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            liftedSessionIDs: [UUID()],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.attention.isEmpty)
        #expect(output.entries[0].sessions.map(\.session.id) == [a.id])
    }

    @Test func unfilteredKeepsEmptiedGroupsFilteringDropsThem() {
        let a = needy("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let unfiltered = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(unfiltered.entries.count == 1)
        let filtering = SidebarAttentionProjection.apply(
            entries: [entry(g, index: 0)],
            liftedSessionIDs: [a.id],
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
            liftedSessionIDs: [b.id],
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
            liftedSessionIDs: [],
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
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(output.topMatch == nil)
    }

    @Test func splitWorkspaceStaysLiftedWhileASiblingPaneWaits() {
        // Documented trade-off: needsUserInput is session-wide, the dwell acks
        // only the active pane. A genuine two-pane split with exactly one
        // needy pane exercises the `panes.contains` semantics — a uniformly
        // needy session (single pane or `mappingPanes` over one) can't tell
        // this apart from every other lift test.
        let shell = TerminalPane(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            agentExecutionState: .output,
            executionPlan: .local
        )
        let codex = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(shell),
                    second: .pane(codex)
                )),
            activePaneID: shell.id
        )
        #expect(session.panes.count == 2)
        #expect(session.panes.filter { $0.attentionReason != nil }.count == 1)
        #expect(SidebarAttentionProjection.isLifted(session, stickySessionID: nil))
    }
}
