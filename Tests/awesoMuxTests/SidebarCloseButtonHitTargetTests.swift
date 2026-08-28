import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct SidebarCloseButtonHitTargetTests {
    @Test("the rendered workspace close target clears 24x24")
    func renderedCloseTargetClearsMinimum() {
        let controller = NSHostingController(
            rootView: SidebarCloseButton(onClose: {})
        )
        controller.view.layoutSubtreeIfNeeded()
        let targetSize = controller.sizeThatFits(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        #expect(targetSize.width >= 24)
        #expect(targetSize.height >= 24)
    }

    @Test(
        "the rendered workspace tile is tall enough to contain its close target",
        arguments: [false, true]
    )
    func renderedTileContainsCloseTarget(isCompact: Bool) {
        let controller = NSHostingController(
            rootView: SidebarCloseTargetHarness(
                density: SidebarDensity(compact: isCompact)
            )
        )
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.sizeThatFits(
            in: CGSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
        )

        #expect(size.height >= 24)
    }

}

private struct SidebarCloseTargetHarness: View {
    let density: SidebarDensity

    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?
    @State private var isKeyboardNavigating = false

    private let pane = TerminalPane(
        title: "Shell",
        workingDirectory: "~",
        agentKind: .shell,
        executionPlan: .local
    )

    var body: some View {
        let session = TerminalSession(
            title: "Workspace",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        SidebarSessionTile(
            session: session,
            match: nil,
            tint: ProjectTint(groupName: "Group", color: nil, index: 0),
            isActive: false,
            displayMode: .expanded,
            isKeyboardFocused: false,
            showsSearchFocusCue: false,
            jumpIndex: nil,
            hasBackgroundedFloatingWork: false,
            isPromotedInsertion: false,
            isPromotionPulseActive: false,
            isFiltering: false,
            duplicateDisambiguation: nil,
            indexInGroup: 0,
            sessionCountInGroup: 1,
            ownerGroupIndex: 0,
            previousNeighborGroup: nil,
            nextNeighborGroup: nil,
            otherGroups: [],
            verticalPadding: density.sessionTileVerticalPadding,
            tintedHighContrast: false,
            alwaysShowJumpNumbers: false,
            onSelect: {},
            onNewSessionHere: {},
            onAcknowledge: {},
            onMoveWithinGroup: { _ in },
            onMoveToGroup: { _ in },
            onClose: {},
            onClear: {},
            onRename: {},
            canMakeWorkspaceManaged: false,
            onMakeWorkspaceManaged: {},
            onToggleNotificationsMute: {},
            isPinned: false,
            onTogglePin: {},
            onDragStarted: { UUID() },
            focusedRowTarget: $focusedRowTarget,
            isKeyboardNavigatingValue: false,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .topLeading)
        .environment(SidebarPeekModel())
        .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
    }
}
