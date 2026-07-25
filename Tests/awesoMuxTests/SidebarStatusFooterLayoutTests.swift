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
    /// two-digit total it must still fit one line — a wrapped total pushes the
    /// row past `AwSpacing.footerChrome` and mis-centers the disclosure chevron
    /// against the two-line block.
    @Test("expanded footer stays one row tall when every chip is visible")
    func expandedFooterStaysOneRowTall() {
        let footer = SidebarStatusFooter(
            counts: [.thinking: 12, .output: 3, .needs: 4],
            total: 19,
            displayMode: .expanded,
            onOpenQuickSettings: {},
            onSelectNextMatchingState: { _ in },
            onToggleActivityPanel: { _ in },
            activityPanelOpen: false
        )
        // 280 sits just above `SidebarWidthPolicy.railThreshold` (250) — the
        // narrowest width `.expanded` mode ever actually renders at. Anything
        // below that threshold collapses to the icon rail in production, and
        // testing there conflates this bug with an unrelated chip-squeeze
        // layout issue that only exists at widths the sidebar can't reach.
        let hostingView = NSHostingView(rootView: footer.frame(width: 280))
        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height <= AwSpacing.footerChrome)
    }
}
