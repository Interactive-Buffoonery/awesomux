import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Sidebar search focus")
struct SidebarSearchFocusTests {
    private let first = TerminalSession.ID()
    private let second = TerminalSession.ID()
    private let third = TerminalSession.ID()

    @Test("arrow navigation starts at the edge matching its direction")
    func navigationStartsAtDirectionalEdge() {
        let ids = [first, second, third]

        #expect(SidebarSearchFocus.target(after: nil, in: ids, offset: 1) == first)
        #expect(SidebarSearchFocus.target(after: nil, in: ids, offset: -1) == third)
    }

    @Test("arrow navigation wraps across result boundaries")
    func navigationWraps() {
        let ids = [first, second, third]

        #expect(SidebarSearchFocus.target(after: third, in: ids, offset: 1) == first)
        #expect(SidebarSearchFocus.target(after: first, in: ids, offset: -1) == third)
    }

    @Test("reordering preserves a surviving focused result")
    func reorderPreservesSurvivor() {
        #expect(
            SidebarSearchFocus.reconcile(
                second,
                from: [first, second, third],
                to: [third, second, first]
            ) == second
        )
    }

    @Test("removed focus moves to the new result at its previous index")
    func removedFocusUsesPreviousIndex() {
        let fourth = TerminalSession.ID()

        #expect(
            SidebarSearchFocus.reconcile(
                second,
                from: [first, second, third],
                to: [third, fourth, first]
            ) == fourth
        )
    }

    @Test("removed trailing focus clamps to the nearest surviving edge")
    func removedTrailingFocusClamps() {
        #expect(
            SidebarSearchFocus.reconcile(
                third,
                from: [first, second, third],
                to: [first]
            ) == first
        )
    }

    @Test("empty results clear focus")
    func emptyResultsClearFocus() {
        #expect(
            SidebarSearchFocus.reconcile(
                first,
                from: [first],
                to: []
            ) == nil
        )
        #expect(SidebarSearchFocus.target(after: first, in: [], offset: 1) == nil)
    }

    @Test("accessibility announcement includes the workspace label and position")
    func accessibilityAnnouncementIncludesPosition() {
        #expect(
            SidebarSearchFocus.accessibilityAnnouncement(
                label: "Linear, Claude, Running",
                position: 2,
                count: 4,
                bundle: .main,
                locale: Locale(identifier: "en_US")
            ) == "Linear, Claude, Running, 2 of 4"
        )
    }
}
