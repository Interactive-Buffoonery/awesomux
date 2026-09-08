import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct SidebarStatusFooterLayoutTests {
    /// The footer is a single chrome row. With every chip visible and a
    /// two-digit total it must still fit one line at each reachable expanded
    /// sidebar width.
    @Test(arguments: [250, 260, 280, 296])
    func expandedFooterStaysOneRowTall(width: CGFloat) {
        let footer = SidebarStatusFooter(
            counts: [.thinking: 12, .output: 3, .needs: 4],
            total: 19,
            displayMode: .expanded,
            onOpenQuickSettings: {},
            onShowWelcomeTour: {},
            onSelectNextMatchingState: { _ in },
            onToggleActivityPanel: { _ in },
            activityPanelOpen: false
        )
        let hostingView = NSHostingView(rootView: footer.frame(width: width))
        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height <= AwSpacing.footerChrome)
    }
}
