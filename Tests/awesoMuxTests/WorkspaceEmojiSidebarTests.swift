import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
@Suite("Workspace emoji sidebar")
struct WorkspaceEmojiSidebarTests {
    @Test("changing only the workspace emoji repaints the row")
    func emojiChangeRerenders() {
        let id = UUID()
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let before = TerminalSession(id: id, title: "workspace", workingDirectory: "~", layout: .pane(pane))
        let after = TerminalSession(id: id, title: "workspace", workingDirectory: "~", emoji: "🍎", layout: .pane(pane))
        #expect(tile(session: before) != tile(session: after))
    }

    @Test("workspace emoji is spoken with the live title")
    func emojiIsAccessible() {
        let session = TerminalSession(title: "stored", workingDirectory: "~", emoji: "🍎")
        let label = SidebarSessionTile.workspaceIdentityAccessibilityLabel(
            session: session, rollup: session.agentRollup(), title: "live"
        )
        #expect(label.contains("🍎 live"))
    }

    private func tile(session: TerminalSession) -> SidebarSessionTile {
        let focusState = FocusState<SidebarVisibleRowTarget?>()
        return SidebarSessionTile(
            session: session,
            match: nil,
            tint: ProjectTint(groupName: "Test", color: nil, index: 0),
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
            previousNeighborGroup: nil,
            nextNeighborGroup: nil,
            otherGroups: [],
            verticalPadding: 9,
            tintedHighContrast: false,
            alwaysShowJumpNumbers: false,
            canReorderWithinGroup: true,
            onSelect: {},
            onNewSessionHere: {},
            onAcknowledge: {},
            onMoveWithinGroup: { _ in },
            onMoveToGroup: { _ in },
            onClose: {},
            onClear: {},
            onRename: {},
            onSetEmoji: {},
            onRemoveEmoji: {},
            canMakeWorkspaceManaged: false,
            onMakeWorkspaceManaged: {},
            onToggleNotificationsMute: {},
            isPinned: false,
            onTogglePin: {},
            originGroupPhrase: nil,
            onDragStarted: { UUID() },
            focusedRowTarget: focusState.projectedValue,
            isKeyboardNavigatingValue: false,
            liveTitles: .unavailable,
            isKeyboardNavigating: .constant(false)
        )
    }
}
