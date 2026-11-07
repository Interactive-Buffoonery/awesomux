import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent section navigation")
@MainActor
struct AgentActivityPanelNavigationTests {
    @Test func collapsedSectionsKeepHeadersButExcludeRowsAndClosedPanes() {
        let waiting = UUID(), working = UUID(), closed = UUID()
        let targets = AgentActivityPanel.navigationTargets(
            rows: [(waiting, .needsYou), (working, .working), (closed, .idleWaiting)],
            collapsedSections: [.needsYou], livePaneIDs: [waiting, working], hasUpdates: true)
        #expect(targets == [.section(.needsYou), .updates, .section(.working), .pane(working), .section(.idleWaiting)])
    }

    @Test func allCollapsedAndEmptyPlacementStillExposeUpdateControl() {
        let pane = UUID()
        #expect(
            AgentActivityPanel.navigationTargets(
                rows: [(pane, .idleWaiting)], collapsedSections: [.idleWaiting], livePaneIDs: [pane], hasUpdates: false) == [
                    .section(.idleWaiting)
                ])
        #expect(
            AgentActivityPanel.navigationTargets(
                rows: [], collapsedSections: [], livePaneIDs: [], hasUpdates: true) == [.updates])
    }

    @Test func footerNamesDestinationInEitherModeIncludingZeroAgents() {
        #expect(SidebarStatusFooter.modeSwitchLabel(total: 0, activityPanelOpen: true) == "Workspaces")
        #expect(SidebarStatusFooter.modeSwitchLabel(total: 4, activityPanelOpen: true) == "Workspaces")
        #expect(
            SidebarStatusFooter.modeSwitchLabel(total: 0, activityPanelOpen: false) == LocalizedPluralStrings.footerAgentsTotal(count: 0))
        #expect(
            SidebarStatusFooter.modeSwitchLabel(total: 4, activityPanelOpen: false) == LocalizedPluralStrings.footerAgentsTotal(count: 4))
    }

    @Test func keyboardArrowsUseKeyboardRowWhenAccessibilityRemainsOnHeader() {
        let first = UUID(), second = UUID()
        let targets: [AgentActivityPanel.NavigationTarget] = [.section(.working), .pane(first), .pane(second)]
        #expect(
            AgentActivityPanel.nextNavigationTarget(
                in: targets, keyboardFocus: .pane(first), accessibilityFocus: .section(.working), offset: 1) == .pane(second))
        #expect(
            AgentActivityPanel.nextNavigationTarget(
                in: targets, keyboardFocus: nil, accessibilityFocus: .section(.working), offset: 1) == .pane(first))
    }
}
