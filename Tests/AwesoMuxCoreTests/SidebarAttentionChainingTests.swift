import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

@Suite struct SidebarAttentionChainingTests {
    private func needy(_ title: String) -> TerminalSession {
        var session = TerminalSession(title: title, workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        return session
    }

    private func entry(_ group: SessionGroup, index: Int) -> SidebarGroupEntry {
        SidebarGroupEntry(
            group: group,
            unfilteredIndex: index,
            sessions: group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        )
    }

    @Test func pinnedWinsOverAttention() {
        // The precedence rule is implemented by CHAINING, not a check: the
        // attention projection never sees a pinned session because the pinned
        // projection already removed it. This guards that order.
        let a = needy("alpha")
        let g = SessionGroup(name: "One", sessions: [a])
        let pinned = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        let attention = SidebarAttentionProjection.apply(
            entries: pinned.entries,
            // The store drops a pinned ID from its lifted list, and the chain
            // removes the row before the attention projection ever sees it —
            // both halves of "pinned wins", neither an explicit precedence check.
            liftedSessionIDs: [],
            isFiltering: false,
            searchTopMatch: pinned.topMatch
        )
        #expect(pinned.pinned.map(\.entry.session.id) == [a.id])
        #expect(attention.attention.isEmpty)
    }

    @Test func acknowledgingReturnsTheRowToItsOriginGroupAtItsOldIndex() {
        let a = needy("alpha")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let needyGroup = SessionGroup(name: "One", sessions: [a, b])
        let lifted = SidebarAttentionProjection.apply(
            entries: [entry(needyGroup, index: 0)],
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(lifted.attention.map(\.entry.session.id) == [a.id])
        #expect(lifted.entries[0].sessions.map(\.session.id) == [b.id])

        var acknowledged = a
        acknowledged.layout = acknowledged.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = nil
            return pane
        }
        let calmGroup = SessionGroup(name: "One", sessions: [acknowledged, b])
        let returned = SidebarAttentionProjection.apply(
            entries: [entry(calmGroup, index: 0)],
            liftedSessionIDs: [],
            isFiltering: false,
            searchTopMatch: nil
        )
        #expect(returned.attention.isEmpty)
        #expect(returned.entries[0].sessions.map(\.session.id) == [a.id, b.id])
    }

    @Test func renderOrderMatchesNavigationOrder() {
        // The ⌘-digit LABEL is indexed off `rotorEntries` in SidebarView.body and
        // the ⌘-digit ACTION off WorkspaceNavigationOrder. They must agree or the
        // digits lie. Asserted against `rotorEntries` itself — the expression the
        // view actually reads — so reordering the production concatenation fails
        // here rather than only in a hand-copied duplicate of it.
        let a = needy("alpha")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a, b, c])
        let pinned = SidebarPinnedProjection.apply(
            entries: [entry(g, index: 0)],
            pinnedSessionIDs: [c.id],
            isFiltering: false,
            searchTopMatch: nil
        )
        let attention = SidebarAttentionProjection.apply(
            entries: pinned.entries,
            liftedSessionIDs: [a.id],
            isFiltering: false,
            searchTopMatch: pinned.topMatch
        )
        let rendered = SidebarVisibleRows.rotorEntries(
            attention: attention.attention,
            pinned: pinned.pinned,
            for: attention.entries
        )
        .map(\.id)
        let navigation = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g],
            liftedSessionIDs: [a.id],
            pinnedSessionIDs: [c.id]
        )
        #expect(rendered == navigation)
    }

    /// The case a group-ordered section would have gotten wrong: the workspace
    /// that asked SECOND sits earlier in group order. Both sides now read the
    /// same list, so ⌘1-9 inherits arrival order rather than re-deriving it.
    @Test func renderOrderMatchesNavigationOrderWhenArrivalDiffersFromGroupOrder() {
        let a = needy("alpha")
        let b = needy("beta")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g1 = SessionGroup(name: "One", sessions: [a, c])
        let g2 = SessionGroup(name: "Two", sessions: [b])
        // beta (group Two) asked first; alpha (group One) asked second.
        let arrivalOrder = [b.id, a.id]
        let pinned = SidebarPinnedProjection.apply(
            entries: [entry(g1, index: 0), entry(g2, index: 1)],
            pinnedSessionIDs: [],
            isFiltering: false,
            searchTopMatch: nil
        )
        let attention = SidebarAttentionProjection.apply(
            entries: pinned.entries,
            liftedSessionIDs: arrivalOrder,
            isFiltering: false,
            searchTopMatch: pinned.topMatch
        )
        let rendered = SidebarVisibleRows.rotorEntries(
            attention: attention.attention,
            pinned: pinned.pinned,
            for: attention.entries
        )
        .map(\.id)
        let navigation = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g1, g2],
            liftedSessionIDs: arrivalOrder,
            pinnedSessionIDs: []
        )
        #expect(rendered == [b.id, a.id, c.id])
        #expect(rendered == navigation)
    }
}
