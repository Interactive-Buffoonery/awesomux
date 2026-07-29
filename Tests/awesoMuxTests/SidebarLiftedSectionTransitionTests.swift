import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Sidebar lifted section transition")
struct SidebarLiftedSectionTransitionTests {
    private let a = TerminalSession.ID()
    private let b = TerminalSession.ID()
    private let c = TerminalSession.ID()

    @Test func singleRemovalReportsTheDepartedWorkspace() {
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a, b], to: [b]) == a
        )
    }

    @Test func bulkRemovalReportsNothing() {
        // The guard that matters: Clear All Notifications and toggling the
        // section off both drain the list at once. Two departures must not
        // expand two groups or speak twice — they report nothing at all.
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a, b], to: []) == nil
        )
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a, b, c], to: [c]) == nil
        )
    }

    @Test func additionReportsNothing() {
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a], to: [a, b]) == nil
        )
    }

    @Test func simultaneousAddAndRemoveReportsNothing() {
        // Two net changes, so it fails the same gate — a swap is not a return
        // anyone can be told about coherently.
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a], to: [b]) == nil
        )
    }

    @Test func reorderReportsNothing() {
        #expect(
            SidebarLiftedSectionTransition.singleRemoval(from: [a, b], to: [b, a]) == nil
        )
    }
}
