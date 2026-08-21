import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Sidebar lifted section transition")
struct SidebarLiftedSectionTransitionTests {
    private let a = TerminalSession.ID()
    private let b = TerminalSession.ID()
    private let c = TerminalSession.ID()

    @Test func singleAdditionReportsTheArrivingWorkspace() {
        #expect(
            SidebarLiftedSectionTransition.singleAddition(from: [b], to: [b, a]) == a
        )
    }

    @Test func bulkAdditionReportsNothing() {
        // Agents go idle in batches — a run of turns ending together must not
        // speak once per row. Same single-net-change gate as removal.
        #expect(
            SidebarLiftedSectionTransition.singleAddition(from: [], to: [a, b]) == nil
        )
        #expect(
            SidebarLiftedSectionTransition.singleAddition(from: [c], to: [c, a, b]) == nil
        )
    }

    @Test func aSwapReportsNeitherAdditionNorRemoval() {
        // One in, one out nets to two changes: neither half is a lone event, so
        // both accessors decline rather than announcing a move as an arrival.
        #expect(SidebarLiftedSectionTransition.singleAddition(from: [a], to: [b]) == nil)
        #expect(SidebarLiftedSectionTransition.singleRemoval(from: [a], to: [b]) == nil)
    }

    @Test func anUnansweredTurnArrivalIsAnnounced() throws {
        let session = TerminalSession(title: "alpha", workingDirectory: "~")
        let paneID = session.activePaneID

        #expect(
            SidebarLiftedSectionTransition.announcesArrival(
                of: session,
                unansweredTurnPaneIDs: [paneID]
            ))
    }

    @Test func anArrivalWithNoUnansweredTurnIsSilent() {
        // A sticky-held or otherwise lifted row with nothing waiting on it has
        // nothing to say.
        let session = TerminalSession(title: "alpha", workingDirectory: "~")

        #expect(
            SidebarLiftedSectionTransition.announcesArrival(
                of: session,
                unansweredTurnPaneIDs: []
            ) == false
        )
    }

    @Test func anArrivalCarryingABlockingPromptIsSilent() {
        // WorkspaceAttentionAnnouncementTracker already speaks this one. Two
        // announcements for one event is worse than none.
        var session = TerminalSession(title: "alpha", workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        let paneID = session.activePaneID

        #expect(
            SidebarLiftedSectionTransition.announcesArrival(
                of: session,
                unansweredTurnPaneIDs: [paneID]
            ) == false
        )
    }

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
